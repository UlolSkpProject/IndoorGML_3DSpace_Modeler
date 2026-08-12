# frozen_string_literal: true

require 'fileutils'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        class CrashIsolationPlan
          ROOM_CATEGORY = 'Room'
          STAIR_FIRST_CATEGORY = 'Stair 1/2'
          STAIR_SECOND_CATEGORY = 'Stair 2/2'
          COMBINED_CATEGORY = 'Door / Elevator / Window / Anchor'
          CATEGORY_ORDER = [
            ROOM_CATEGORY,
            STAIR_FIRST_CATEGORY,
            STAIR_SECOND_CATEGORY,
            COMBINED_CATEGORY
          ].freeze

          def category_order
            CATEGORY_ORDER
          end

          def initial_jobs(cell_spaces)
            grouped = Array(cell_spaces).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |cell_space, result|
              category = category_for(cell_space)
              result[category] << cell_space if category
            end
            stairs = grouped['Stair']
            stair_midpoint = (stairs.length / 2.0).ceil
            bucket_cells = {
              ROOM_CATEGORY => grouped[ROOM_CATEGORY],
              STAIR_FIRST_CATEGORY => stairs.first(stair_midpoint),
              STAIR_SECOND_CATEGORY => stairs.drop(stair_midpoint),
              COMBINED_CATEGORY => grouped[COMBINED_CATEGORY]
            }

            CATEGORY_ORDER.filter_map do |category|
              cells = bucket_cells[category]
              next if cells.empty?

              { category: category, cell_spaces: cells.freeze, depth: 0 }
            end
          end

          def split(job)
            cells = Array(job[:cell_spaces])
            return [] if cells.length <= 1

            chunk_size = (cells.length / 4.0).ceil
            cells.each_slice(chunk_size).map do |chunk|
              {
                category: job[:category],
                cell_spaces: chunk.freeze,
                depth: job[:depth].to_i + 1
              }
            end
          end

          def category_for(cell_space)
            code = cell_space.respond_to?(:category_code) ? cell_space.category_code.to_s : ''
            return code if %w[Room Stair].include?(code)
            return COMBINED_CATEGORY if %w[Door Elevator Window Anchor Gate ExteriorDoor].include?(code)

            type = cell_space.respond_to?(:cell_type) ? cell_space.cell_type : nil
            return COMBINED_CATEGORY if defined?(CellSpaceType::CONNECTION) && type == CellSpaceType::CONNECTION
            return COMBINED_CATEGORY if defined?(CellSpaceType::ANCHOR) && type == CellSpaceType::ANCHOR
            return COMBINED_CATEGORY if defined?(CellSpaceType::GEOMETRY_ONLY) && type == CellSpaceType::GEOMETRY_ONLY
            return 'Room' if defined?(CellSpaceType::GENERAL) && type == CellSpaceType::GENERAL

            nil
          end
        end

        class CrashIsolationCoordinator
          AABB_PASS_MESSAGE = 'Constructing AABB tree'
          EARLY_STOP_WAIT_MS = 200

          Result = Struct.new(:crash_cell_spaces, :records, :progress, :error, keyword_init: true) do
            def error?
              !error.nil?
            end
          end

          MAX_PROCESSES = 4
          POLL_INTERVAL_SECONDS = 0.1

          attr_reader :exit_code

          def initialize(indoor_model:, work_dir:, overlap_tol_mm:, plan: CrashIsolationPlan.new,
                         cell_spaces: nil, cached_checked_cell_spaces: [], cached_crash_cell_spaces: [],
                         max_processes: MAX_PROCESSES, exporter: nil, process_factory: nil,
                         timer_api: nil, logger: nil)
            @indoor_model = indoor_model
            @model = indoor_model&.model
            @cell_spaces = cell_spaces.nil? ? Array(indoor_model&.cell_spaces) : Array(cell_spaces)
            @cached_checked_cell_spaces = Array(cached_checked_cell_spaces)
            @cached_crash_cell_spaces = Array(cached_crash_cell_spaces)
            @work_dir = File.expand_path(work_dir)
            @overlap_tol_mm = overlap_tol_mm.to_f
            @plan = plan
            @max_processes = [max_processes.to_i, 1].max
            @exporter = exporter || method(:export_geometry_subset)
            @process_factory = process_factory || method(:build_process)
            @timer_api = timer_api || (defined?(UI) ? UI : nil)
            @logger = logger || (defined?(IndoorCore::Logger) && IndoorCore::Logger)
            @pending = []
            @active_processes = []
            @split_groups = {}
            @crash_cell_spaces = @cached_crash_cell_spaces.dup
            @records = []
            @initial_jobs = []
            @split_counts = Hash.new(0)
            @launched_count = 0
            @completed_count = 0
            @finished = false
            @terminated = false
            @exit_code = nil
          end

          def start(active: nil, on_progress: nil, &callback)
            raise ArgumentError, 'callback is required' unless callback
            raise 'Timer API is unavailable for precision crash isolation' unless @timer_api&.respond_to?(:start_timer)

            @active_guard = active || proc { true }
            @on_progress = on_progress
            @callback = callback
            FileUtils.mkdir_p(@work_dir)
            @initial_jobs = @plan.initial_jobs(@cell_spaces)
            @pending.concat(@initial_jobs)
            if @pending.empty?
              finish_success
              return self
            end

            pump
            @timer_id = @timer_api.start_timer(POLL_INTERVAL_SECONDS, true) { tick }
            self
          rescue StandardError => error
            finish_error(error)
            self
          end

          def finished?
            finalize_terminated_processes if @terminated && !@finished
            @finished == true
          rescue StandardError
            false
          end

          def terminated?
            @terminated == true
          end

          def terminate(wait_ms: 200)
            @terminated = true
            @pending.clear
            remaining = []
            @active_processes.each do |entry|
              process = entry[:process]
              if process.terminate(wait_ms: wait_ms)
                process.close
                IndoorGmlConverter::Val3dityRunner.unregister_session(process) if
                  defined?(IndoorGmlConverter::Val3dityRunner)
              else
                remaining << entry
              end
            rescue StandardError => error
              remaining << entry
              log("precision crash probe terminate failed: #{error.class}: #{error.message}")
            end
            stop_timer
            @active_processes = remaining
            @finished = remaining.empty?
            @finished
          end

          def join_reader(_timeout = 1.0)
            true
          end

          def close
            terminate(wait_ms: 0) unless finished?
            true
          end

          private

          def tick
            unless active?
              terminate(wait_ms: 0)
              return false
            end

            collect_finished_processes
            pump
            if @pending.empty? && @active_processes.empty?
              finish_success
              return false
            end
            true
          rescue StandardError => error
            finish_error(error)
            false
          end

          def pump
            while @active_processes.length < @max_processes && (job = @pending.shift)
              launch(job)
            end
            emit_progress
          end

          def launch(job)
            @launched_count += 1
            token = format('%04d-%s-d%d', @launched_count, safe_name(job[:category]), job[:depth].to_i)
            gml_path = File.join(@work_dir, "probe-#{token}.gml")
            report_path = File.join(@work_dir, "probe-#{token}.json")
            @exporter.call(job[:cell_spaces], gml_path)
            process = @process_factory.call(gml_path, report_path)
            process.start(total_states: 0, total_transitions: 0)
            IndoorGmlConverter::Val3dityRunner.register_session(
              process,
              owner_key: IndoorGmlConverter::Val3dityRunner.owner_key_for_model(@model)
            ) if defined?(IndoorGmlConverter::Val3dityRunner)
            @active_processes << { process: process, job: job, gml_path: gml_path }
          rescue StandardError
            process&.close
            raise
          end

          def collect_finished_processes
            @active_processes.dup.each do |entry|
              process = entry[:process]
              entry[:aabb_reached] = true if drain_output(process)
              request_aabb_early_stop(entry) if entry[:aabb_reached]
              next unless process.finished?

              process.join_reader
              entry[:aabb_reached] = true if drain_output(process)
              crashed = !entry[:aabb_reached] && process.exit_code.to_i != 0
              outcome = if entry[:aabb_reached]
                          :aabb_reached
                        elsif crashed
                          :crashed
                        else
                          :completed
                        end
              record_completion(
                entry[:job],
                process.exit_code,
                crashed,
                outcome: outcome,
                early_stopped: entry[:early_stop_succeeded] == true
              )
              handle_job_result(entry[:job], crashed)
              process.close
              IndoorGmlConverter::Val3dityRunner.unregister_session(process) if
                defined?(IndoorGmlConverter::Val3dityRunner)
              @active_processes.delete(entry)
              @completed_count += 1
            end
          end

          def handle_job_result(job, crashed)
            update_parent_split(job, crashed)
            return unless crashed

            cells = Array(job[:cell_spaces])
            if cells.length == 1
              add_crash_cells(cells)
              return
            end

            children = @plan.split(job)
            if children.empty?
              add_crash_cells(cells)
              return
            end

            split_id = "split-#{@launched_count}-#{@completed_count}-#{job.object_id}"
            @split_groups[split_id] = {
              remaining: children.length,
              crash_seen: false,
              parent_cells: cells
            }
            @split_counts[job[:category]] += 1
            children.each { |child| @pending << child.merge(parent_split_id: split_id) }
          end

          def update_parent_split(job, crashed)
            split_id = job[:parent_split_id]
            return unless split_id

            split = @split_groups[split_id]
            return unless split

            split[:remaining] -= 1
            split[:crash_seen] = true if crashed
            return unless split[:remaining] <= 0

            add_crash_cells(split[:parent_cells]) unless split[:crash_seen]
            @split_groups.delete(split_id)
          end

          def add_crash_cells(cells)
            Array(cells).each do |cell_space|
              @crash_cell_spaces << cell_space unless @crash_cell_spaces.include?(cell_space)
            end
          end

          def record_completion(job, exit_code, crashed, outcome:, early_stopped: false)
            @records << {
              category: job[:category],
              depth: job[:depth].to_i,
              cell_space_ids: Array(job[:cell_spaces]).map { |cell| cell.respond_to?(:id) ? cell.id : nil },
              cell_space_count: Array(job[:cell_spaces]).length,
              exit_code: exit_code,
              crashed: crashed,
              outcome: outcome,
              aabb_reached: outcome == :aabb_reached,
              early_stopped: early_stopped == true
            }
          end

          def export_geometry_subset(cell_spaces, output_path)
            IndoorGmlConverter::GmlExporter.new(
              @indoor_model,
              refresh_runtime_data: false,
              cell_spaces: cell_spaces,
              transitions: [],
              include_dual_graph: false
            ).export(output_path: output_path)
          end

          def build_process(gml_path, report_path)
            tolerance = IndoorGmlConverter::GmlExporter.millimeters_to_coordinate_units(
              @overlap_tol_mm,
              model: @model
            )
            args = [
              File.join(IndoorGmlConverter::Val3dityRunner::VENDOR_ROOT, 'val3dity.exe'),
              gml_path,
              '--verbose',
              '--overlap_tol',
              format('%.15g', tolerance),
              '-r',
              report_path
            ]
            IndoorGmlConverter::Val3dityProcessAdapter.new(
              args: args,
              current_dir: IndoorGmlConverter::Val3dityRunner::VENDOR_ROOT
            )
          end

          def drain_output(process)
            aabb_reached = false
            loop do
              payload = process.pop_progress
              break unless payload

              aabb_reached = true if payload[:message].to_s == AABB_PASS_MESSAGE
            end
            aabb_reached
          rescue StandardError
            false
          end

          def request_aabb_early_stop(entry)
            return if entry[:early_stop_requested]

            entry[:early_stop_requested] = true
            entry[:early_stop_succeeded] = entry[:process].terminate(
              wait_ms: EARLY_STOP_WAIT_MS
            ) == true
            unless entry[:early_stop_succeeded]
              log(
                "AABB pass reached but probe early stop did not finish: " \
                "category=#{entry[:job][:category]} depth=#{entry[:job][:depth]}"
              )
            end
          rescue StandardError => error
            entry[:early_stop_succeeded] = false
            log("AABB probe early stop failed: #{error.class}: #{error.message}")
          end

          def emit_progress
            return unless @on_progress

            @on_progress.call(progress_snapshot)
          rescue StandardError => error
            log("precision crash probe progress failed: #{error.class}: #{error.message}")
          end

          def progress_snapshot
            categories = if @plan.respond_to?(:category_order)
                           @plan.category_order
                         else
                           @initial_jobs.map { |job| job[:category] }
                         end
            bucket_rows = Array(categories).map do |category|
              initial_job = @initial_jobs.find { |job| job[:category] == category }
              records = @records.select { |record| record[:category] == category }
              active_jobs = @active_processes.select { |entry| entry[:job][:category] == category }
              pending_jobs = @pending.select { |job| job[:category] == category }
              all_jobs = records + active_jobs.map { |entry| entry[:job] } + pending_jobs
              root_record = records.find { |record| record[:depth].to_i.zero? }
              split_total = all_jobs.count { |job| job[:depth].to_i.positive? }
              split_completed = records.count { |record| record[:depth].to_i.positive? }
              aabb_passed_cell_space_count = records.sum do |record|
                record[:aabb_reached] == true ? record[:cell_space_count].to_i : 0
              end
              max_depth = all_jobs.map { |job| job[:depth].to_i }.max || 0
              bucket_cells = Array(initial_job && initial_job[:cell_spaces])
              cached_job = @plan.initial_jobs(@cached_checked_cell_spaces).find do |job|
                job[:category] == category
              end
              cached_cells = Array(cached_job && cached_job[:cell_spaces])
              cached_crash_count = cached_cells.count do |cell_space|
                @cached_crash_cell_spaces.include?(cell_space)
              end
              cached_passed_count = cached_cells.length - cached_crash_count

              {
                category: category,
                status: bucket_status(
                  initial_job: initial_job,
                  root_record: root_record,
                  active_jobs: active_jobs,
                  pending_jobs: pending_jobs,
                  cached_passed_count: cached_passed_count,
                  cached_crash_count: cached_crash_count
                ),
                cell_space_count: bucket_cells.length + cached_cells.length,
                probe_cell_space_count: bucket_cells.length,
                cached_checked_count: cached_cells.length,
                cached_passed_count: cached_passed_count,
                cached_crash_count: cached_crash_count,
                initial_crashed: root_record ? root_record[:crashed] == true : nil,
                completed_jobs: records.length,
                total_jobs: all_jobs.length,
                active_jobs: active_jobs.length,
                pending_jobs: pending_jobs.length,
                split_count: @split_counts[category].to_i,
                split_completed_jobs: split_completed,
                split_total_jobs: split_total,
                aabb_passed_cell_space_count: aabb_passed_cell_space_count,
                max_depth: max_depth,
                crash_cell_count: bucket_cells.count { |cell| @crash_cell_spaces.include?(cell) }
              }
            end

            total_jobs = @records.length + @active_processes.length + @pending.length
            {
              completed: @completed_count,
              launched: @launched_count,
              total_jobs: total_jobs,
              active: @active_processes.length,
              pending: @pending.length,
              crash_cell_count: @crash_cell_spaces.length,
              categories: bucket_rows
            }
          end

          def bucket_status(initial_job:, root_record:, active_jobs:, pending_jobs:,
                            cached_passed_count:, cached_crash_count:)
            unless initial_job
              return :cached_crashed if cached_crash_count.positive?
              return :cached_passed if cached_passed_count.positive?

              return :empty
            end
            return :passed if root_record && !root_record[:crashed]
            if root_record && root_record[:crashed]
              return :splitting unless active_jobs.empty? && pending_jobs.empty?

              return :crashed
            end
            return :checking unless active_jobs.empty?

            :waiting
          end

          def finish_success
            return if @finished

            @finished = true
            @exit_code = 0
            stop_timer
            @callback&.call(Result.new(
              crash_cell_spaces: @crash_cell_spaces.freeze,
              records: @records.freeze,
              progress: progress_snapshot,
              error: nil
            ))
          end

          def finish_error(error)
            return if @finished

            @active_processes.each do |entry|
              entry[:process].terminate(wait_ms: 0)
              entry[:process].close
              IndoorGmlConverter::Val3dityRunner.unregister_session(entry[:process]) if
                defined?(IndoorGmlConverter::Val3dityRunner)
            rescue StandardError
              nil
            end
            @active_processes.clear
            @pending.clear
            @finished = true
            @exit_code = 1
            stop_timer
            @callback&.call(Result.new(
              crash_cell_spaces: @crash_cell_spaces.freeze,
              records: @records.freeze,
              progress: progress_snapshot,
              error: error
            ))
          end

          def active?
            @active_guard.call == true
          rescue StandardError
            false
          end

          def stop_timer
            timer_id = @timer_id
            @timer_id = nil
            @timer_api.stop_timer(timer_id) if timer_id && @timer_api&.respond_to?(:stop_timer)
          rescue StandardError
            nil
          end

          def finalize_terminated_processes
            @active_processes.dup.each do |entry|
              process = entry[:process]
              next unless process.finished?

              process.join_reader
              process.close
              IndoorGmlConverter::Val3dityRunner.unregister_session(process) if
                defined?(IndoorGmlConverter::Val3dityRunner)
              @active_processes.delete(entry)
            rescue StandardError => error
              log("terminated precision probe cleanup failed: #{error.class}: #{error.message}")
            end
            @finished = true if @active_processes.empty?
          end

          def safe_name(value)
            value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
          end

          def log(message)
            @logger.puts("[IndoorGML] #{message}") if @logger&.respond_to?(:puts)
          end
        end
      end
    end
  end
end
