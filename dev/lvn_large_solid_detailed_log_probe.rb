# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'
require 'time'

# Load the existing whole-solid fallback helpers without triggering their
# default selected-source execution.
dependency_model = Sketchup.active_model
dependency_selection = dependency_model.selection.to_a
dependency_stdout = $stdout
dependency_stderr = $stderr
begin
  dependency_model.selection.clear
  $stdout = StringIO.new
  $stderr = StringIO.new
  require_relative 'lvn_polygon_whole_solid_fallback_probe'
ensure
  $stdout = dependency_stdout
  $stderr = dependency_stderr
  dependency_model.selection.clear
  dependency_selection.each do |entity|
    dependency_model.selection.add(entity) if entity.respond_to?(:valid?) && entity.valid?
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Development-only diagnostic runner for very large solids.
      #
      # - Only selected top-level manifold solids with Face count > 1,000 run.
      # - Inventory is written before any LVN call.
      # - Each source is copied to a fresh unique candidate.
      # - Production LocalVertexNormalizer runs unchanged on that copy.
      # - Every outer operation is aborted, preserving the source/model.
      # - Log writes are synchronous so a forced SketchUp termination retains
      #   the latest completed stage and heartbeat.
      module LvnLargeSolidDetailedLogProbe
        FACE_LIMIT_EXCLUSIVE = 1_000
        HEARTBEAT_SECONDS = 30.0
        STACK_DEPTH = 14
        RUN_ORDER = :largest_first

        INSTRUMENTED_METHODS = %i[
          normalize_entity
          ensure_unique_definition
          geometry_counts
          geometry_vertices
          normalized_vertex_metrics
          short_edge_sliver_collapse_plan
          triangle_snapshot
          normalized_triangle_snapshot
          conforming_triangle_snapshot
          collapse_source_altitude_sliver_triangles
          discard_collapsed_triangle_records
          normalize_triangle_records_allowing_collisions
          validate_normalized_triangle_shapes!
          triangle_mesh_inventory
          collapse_short_edge_sliver_triangles
          validate_sliver_topology_when_comparable!
          validate_normalized_triangle_mesh!
          validate_normalized_triangle_topology!
          validate_triangle_intersections!
          collect_triangle_intersection_failures
          erase_source_geometry
          rebuild_triangles
          verify_triangle_rebuild!
          orient_and_merge_rebuilt_surface
          repair_rebuilt_entity_before_rollback
          validate_rebuilt_entity!
          max_grid_residual_mm
          final_normalized_mesh_state
          post_cleanup_snapshot_reuse_decision
          verify_normalized_surface_equivalence!
          build_normalization_report
          augment_v2_normalization_report!
        ].freeze

        class DiagnosticLog
          attr_reader :path

          def initialize(path, worker_thread: Thread.current)
            @path = path
            @worker_thread = worker_thread
            @started_at = monotonic_time
            @mutex = Mutex.new
            @stage_stack = []
            @current_solid = nil
            @solid_started_at = nil
            @stop_heartbeat = false
            @io = File.open(path, 'wb')
            @io.set_encoding(Encoding::UTF_8)
            @io.sync = true
          end

          def log(event, data = nil, level: 'INFO', **fields)
            data = {} if data.nil?
            data = { value: data } unless data.is_a?(Hash)
            payload = normalize_payload(data.merge(fields))
            line = format(
              '[%s] +%0.3fs %-5s %-34s %s\n',
              Time.now.strftime('%Y-%m-%d %H:%M:%S.%L %z'),
              monotonic_time - @started_at,
              level,
              event.to_s,
              JSON.generate(payload)
            )
            @mutex.synchronize do
              @io.write(line)
              @io.flush
            end
            true
          rescue StandardError => error
            warn "[LVN LARGE LOG] write failed: #{error.class}: #{error.message}"
            false
          end

          def with_stage(name, metadata = {})
            stage = {
              name: name.to_s,
              started_at: monotonic_time,
              metadata: metadata
            }
            @mutex.synchronize { @stage_stack << stage }
            log('STAGE_BEGIN', stage_payload(stage).merge(metadata: metadata))
            result = yield
            log(
              'STAGE_END',
              stage_payload(stage).merge(
                duration_s: monotonic_time - stage[:started_at],
                result: LvnLargeSolidDetailedLogProbe.summarize_value(result)
              )
            )
            result
          rescue Exception => error # rubocop:disable Lint/RescueException
            log(
              'STAGE_ERROR',
              stage_payload(stage).merge(
                duration_s: monotonic_time - stage[:started_at],
                error_class: error.class.name,
                error_message: error.message,
                backtrace: Array(error.backtrace).first(STACK_DEPTH)
              ),
              level: 'ERROR'
            )
            raise
          ensure
            @mutex.synchronize do
              index = @stage_stack.rindex(stage)
              @stage_stack.delete_at(index) if index
            end
          end

          def set_current_solid(metadata)
            @mutex.synchronize do
              @current_solid = metadata.dup
              @solid_started_at = monotonic_time
            end
            log('SOLID_CONTEXT_SET', metadata)
          end

          def clear_current_solid
            solid, started_at = @mutex.synchronize do
              value = @current_solid
              start = @solid_started_at
              @current_solid = nil
              @solid_started_at = nil
              [value, start]
            end
            log(
              'SOLID_CONTEXT_CLEAR',
              solid: solid,
              elapsed_s: started_at ? monotonic_time - started_at : nil
            )
          end

          def start_heartbeat
            return if @heartbeat_thread&.alive?

            @stop_heartbeat = false
            @heartbeat_thread = Thread.new do
              Thread.current.name = 'lvn-large-solid-heartbeat' if
                Thread.current.respond_to?(:name=)
              loop do
                sleep HEARTBEAT_SECONDS
                break if @stop_heartbeat

                write_heartbeat
              end
            rescue StandardError => error
              log(
                'HEARTBEAT_THREAD_ERROR',
                error_class: error.class.name,
                error_message: error.message,
                backtrace: Array(error.backtrace).first(STACK_DEPTH),
                level: 'ERROR'
              )
            end
          end

          def stop_heartbeat
            @stop_heartbeat = true
            thread = @heartbeat_thread
            return unless thread

            thread.wakeup if thread.alive?
            thread.join(2.0)
          rescue ThreadError
            thread.join(2.0) if thread
          ensure
            @heartbeat_thread = nil
          end

          def close
            stop_heartbeat
            log('LOG_CLOSE') if @io && !@io.closed?
            @mutex.synchronize do
              @io.flush unless @io.closed?
              @io.close unless @io.closed?
            end
          rescue StandardError => error
            warn "[LVN LARGE LOG] close failed: #{error.class}: #{error.message}"
          end

          private

          def write_heartbeat
            now = monotonic_time
            stage_stack, solid, solid_started_at = @mutex.synchronize do
              [@stage_stack.map(&:dup), @current_solid&.dup, @solid_started_at]
            end
            deepest = stage_stack.last
            locations = @worker_thread&.backtrace_locations
            stack = Array(locations).first(STACK_DEPTH).map do |location|
              path = location.absolute_path || location.path
              "#{File.basename(path.to_s)}:#{location.lineno}:in `#{location.label}'"
            end
            gc = GC.stat
            log(
              'HEARTBEAT',
              solid: solid,
              solid_elapsed_s: solid_started_at ? now - solid_started_at : nil,
              stage_depth: stage_stack.length,
              stage_stack: stage_stack.map { |entry| entry[:name] },
              current_stage: deepest && deepest[:name],
              current_stage_elapsed_s:
                deepest ? now - deepest[:started_at] : nil,
              worker_status: @worker_thread&.status,
              worker_stack: stack,
              gc: {
                heap_live_slots: gc[:heap_live_slots],
                heap_available_slots: gc[:heap_available_slots],
                total_allocated_objects: gc[:total_allocated_objects],
                total_freed_objects: gc[:total_freed_objects],
                minor_gc_count: gc[:minor_gc_count],
                major_gc_count: gc[:major_gc_count]
              }
            )
          rescue StandardError => error
            log(
              'HEARTBEAT_ERROR',
              error_class: error.class.name,
              error_message: error.message,
              level: 'ERROR'
            )
          end

          def stage_payload(stage)
            {
              stage: stage[:name],
              depth: @mutex.synchronize { @stage_stack.length },
              solid: @mutex.synchronize { @current_solid&.dup }
            }
          end

          def normalize_payload(value)
            case value
            when Hash
              value.each_with_object({}) do |(key, item), result|
                result[key.to_s] = normalize_payload(item)
              end
            when Array
              value.map { |item| normalize_payload(item) }
            when Symbol
              value.to_s
            when String, Numeric, TrueClass, FalseClass, NilClass
              value
            else
              value.to_s
            end
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end

        module DetailedInstrumentation
          LvnLargeSolidDetailedLogProbe::INSTRUMENTED_METHODS.each do |method_name|
            define_method(method_name) do |*args, **kwargs, &block|
              context = LvnLargeSolidDetailedLogProbe.active_context
              unless context
                return kwargs.empty? ?
                  super(*args, &block) :
                  super(*args, **kwargs, &block)
              end

              context.with_stage(
                "LocalVertexNormalizer##{method_name}",
                arguments: LvnLargeSolidDetailedLogProbe.summarize_arguments(
                  args,
                  kwargs
                )
              ) do
                kwargs.empty? ?
                  super(*args, &block) :
                  super(*args, **kwargs, &block)
              end
            end
          end

          private(*LvnLargeSolidDetailedLogProbe::INSTRUMENTED_METHODS)
        end

        module_function

        def run
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          base = LvnPolygonCandidateReconstructionProbe
          fallback = LvnPolygonWholeSolidFallbackProbe
          original_selection = model.selection.to_a

          log_path = build_log_path(model)
          FileUtils.mkdir_p(File.dirname(log_path))
          diagnostic = DiagnosticLog.new(log_path, worker_thread: Thread.current)
          self.active_context = diagnostic
          install_instrumentation
          diagnostic.start_heartbeat

          puts '=' * 108
          puts ' LVN Large-Solid Production Fallback — Detailed File Diagnostic'
          puts '=' * 108
          puts format('log file              : %s', log_path)
          puts format('Face condition        : F > %d', FACE_LIMIT_EXCLUSIVE)
          puts 'run order             : largest Face count first'
          puts 'source mutation       : none; every outer operation is aborted'
          puts 'Phase 1 attempted     : false'
          puts 'polygon attempted     : false'
          puts '-' * 108

          diagnostic.log(
            'RUN_BEGIN',
            probe: name,
            face_condition: "F > #{FACE_LIMIT_EXCLUSIVE}",
            run_order: RUN_ORDER,
            selected_entities: original_selection.length,
            model_path: model.respond_to?(:path) ? model.path.to_s : nil,
            ruby_version: RUBY_VERSION,
            sketchup_version:
              defined?(Sketchup) && Sketchup.respond_to?(:version) ?
                Sketchup.version.to_s : nil,
            tolerance_mm: phase1::DEFAULT_TOLERANCE_MM,
            production_lvn_class: LocalVertexNormalizer.name
          )

          targets, skipped = inventory_targets(model, original_selection, phase1, base)
          diagnostic.log(
            'INVENTORY_COMPLETE',
            selected_entities: original_selection.length,
            qualifying_solids: targets.length,
            skipped: skipped,
            targets: targets.map { |target| inventory_log_entry(target) }
          )

          puts format('qualifying F>1000     : %d', targets.length)
          targets.each_with_index do |target, index|
            puts format(
              '  [%02d/%02d] F=%d E=%d V=%d PID=%s %s',
              index + 1,
              targets.length,
              target[:counts][:faces],
              target[:counts][:edges],
              target[:counts][:vertices],
              target[:pid],
              target[:label]
            )
          end
          puts '-' * 108

          if targets.empty?
            diagnostic.log('RUN_END', result: 'FAIL', reason: 'no_F_gt_1000_target')
            puts 'result                : FAIL (no F > 1000 selected solid)'
            puts '=' * 108
            return false
          end

          run_root_before = fallback.model_root_signature(model)
          results = []
          stop_reason = nil

          targets.each_with_index do |target, index|
            result = run_target(
              model,
              target,
              index,
              targets.length,
              phase1,
              base,
              fallback,
              diagnostic
            )
            results << result
            unless result[:source_restored] && result[:root_restored]
              stop_reason = :restoration_failure
              diagnostic.log(
                'RUN_STOP',
                reason: stop_reason,
                failed_target: inventory_log_entry(target),
                result: result,
                level: 'ERROR'
              )
              break
            end
          end

          selection_restored = fallback.restore_selection(model, original_selection)
          run_root_restored = fallback.model_root_signature(model) == run_root_before
          success =
            stop_reason.nil? &&
            results.length == targets.length &&
            results.all? { |result| result[:passed] } &&
            selection_restored &&
            run_root_restored

          diagnostic.log(
            'RUN_END',
            result: success ? 'PASS' : 'FAIL',
            qualifying_solids: targets.length,
            tested_solids: results.length,
            passed_solids: results.count { |result| result[:passed] },
            failed_solids: results.count { |result| !result[:passed] },
            stop_reason: stop_reason,
            model_root_restored: run_root_restored,
            selection_restored: selection_restored,
            results: results
          )

          puts '-' * 108
          puts format('tested solids         : %d/%d', results.length, targets.length)
          puts format('model root restored   : %s', run_root_restored)
          puts format('selection restored    : %s', selection_restored)
          puts format('result                : %s', success ? 'PASS' : 'FAIL')
          puts format('log file              : %s', log_path)
          puts '=' * 108
          success
        rescue Exception => error # rubocop:disable Lint/RescueException
          diagnostic&.log(
            'RUN_FATAL',
            error_class: error.class.name,
            error_message: error.message,
            backtrace: Array(error.backtrace).first(30),
            level: 'ERROR'
          )
          warn "[LVN LARGE DETAILED LOG] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(20).join("\n")
          false
        ensure
          begin
            fallback.restore_selection(model, original_selection) if
              defined?(fallback) && fallback && defined?(model) && model &&
              defined?(original_selection) && original_selection
          rescue StandardError => restore_error
            diagnostic&.log(
              'FINAL_SELECTION_RESTORE_ERROR',
              error_class: restore_error.class.name,
              error_message: restore_error.message,
              level: 'ERROR'
            )
          end
          self.active_context = nil
          diagnostic&.close
        end

        def run_target(
          model,
          target,
          index,
          total,
          phase1,
          base,
          fallback,
          diagnostic
        )
          source = target[:entity]
          source_signature = base.brep_signature(source)
          iteration_root_before = fallback.model_root_signature(model)
          metadata = inventory_log_entry(target).merge(
            index: index + 1,
            total: total
          )
          diagnostic.set_current_solid(metadata)
          diagnostic.log('SOLID_BEGIN', metadata)
          puts format(
            '[%02d/%02d] START F=%d PID=%s %s',
            index + 1,
            total,
            target[:counts][:faces],
            target[:pid],
            target[:label]
          )

          operation_started = false
          candidate = nil
          report = nil
          error = nil
          started_at = monotonic_time
          candidate_fresh = false
          definition_isolated = false
          candidate_manifold = false
          candidate_normalized = false
          report_complete = false

          begin
            diagnostic.with_stage('outer_operation_start') do
              operation_started = model.start_operation(
                "LVN large detailed diagnostic #{index + 1}/#{total}",
                true
              )
              raise 'SketchUp start_operation returned false' if operation_started == false

              operation_started
            end

            candidate = diagnostic.with_stage('fresh_copy_create') do
              fallback.copy_source_instance(
                source,
                model,
                phase1,
                format('LVN_LARGE_LOG_TEMP_%02d', index + 1)
              )
            end
            candidate_fresh = base.brep_signature(candidate) == source_signature
            definition_isolated = candidate.definition != source.definition
            diagnostic.log(
              'FRESH_COPY_READY',
              candidate_fresh: candidate_fresh,
              definition_isolated: definition_isolated,
              candidate_pid:
                candidate.respond_to?(:persistent_id) ? candidate.persistent_id : nil,
              candidate_counts: base.geometry_counts(candidate)
            )
            raise 'Fresh fallback candidate B-rep differs from source' unless candidate_fresh
            raise 'Fallback candidate definition is not isolated' unless definition_isolated

            report = diagnostic.with_stage('production_LocalVertexNormalizer.normalize') do
              LocalVertexNormalizer.normalize(
                candidate,
                phase1::DEFAULT_TOLERANCE_MM,
                manage_operation: false
              )
            end

            diagnostic.with_stage('post_normalization_validation') do
              candidate_manifold =
                candidate.valid? &&
                candidate.respond_to?(:manifold?) &&
                candidate.manifold? == true
              candidate_normalized = LocalVertexNormalizer.normalized?(
                candidate,
                phase1::DEFAULT_TOLERANCE_MM
              )
              report_complete =
                report.is_a?(Hash) &&
                report[:normalization_complete] == true &&
                report[:manifold] == true
              {
                candidate_manifold: candidate_manifold,
                candidate_normalized: candidate_normalized,
                report_complete: report_complete,
                strategy: report.is_a?(Hash) ? report[:normalization_strategy] : nil,
                grid_residual_mm:
                  report.is_a?(Hash) ? report[:max_grid_residual_mm] : nil
              }
            end
          rescue Exception => caught # rubocop:disable Lint/RescueException
            error = caught
            diagnostic.log(
              'SOLID_EXECUTION_ERROR',
              error_class: caught.class.name,
              error_message: caught.message,
              backtrace: Array(caught.backtrace).first(30),
              level: 'ERROR'
            )
          ensure
            if operation_started
              begin
                diagnostic.with_stage('outer_operation_abort') do
                  aborted = model.abort_operation
                  raise 'SketchUp abort_operation returned false' if aborted == false

                  aborted
                end
              rescue Exception => abort_error # rubocop:disable Lint/RescueException
                error ||= abort_error
                diagnostic.log(
                  'OUTER_ABORT_ERROR',
                  error_class: abort_error.class.name,
                  error_message: abort_error.message,
                  backtrace: Array(abort_error.backtrace).first(20),
                  level: 'ERROR'
                )
              end
            end
          end

          source_restored = base.brep_signature(source) == source_signature
          root_restored = fallback.model_root_signature(model) == iteration_root_before
          elapsed_s = monotonic_time - started_at
          passed =
            error.nil? &&
            candidate_fresh &&
            definition_isolated &&
            report_complete &&
            candidate_manifold &&
            candidate_normalized &&
            source_restored &&
            root_restored
          result = {
            index: index + 1,
            total: total,
            label: target[:label],
            pid: target[:pid],
            faces: target[:counts][:faces],
            elapsed_s: elapsed_s,
            passed: passed,
            candidate_fresh: candidate_fresh,
            definition_isolated: definition_isolated,
            report_complete: report_complete,
            candidate_manifold: candidate_manifold,
            candidate_normalized: candidate_normalized,
            normalization_strategy:
              report.is_a?(Hash) ? report[:normalization_strategy] : nil,
            max_grid_residual_mm:
              report.is_a?(Hash) ? report[:max_grid_residual_mm] : nil,
            source_restored: source_restored,
            root_restored: root_restored,
            error_class: error&.class&.name,
            error_message: error&.message
          }
          diagnostic.log('SOLID_END', result, level: passed ? 'INFO' : 'ERROR')
          puts format(
            '[%02d/%02d] %s elapsed=%0.3fs source_restored=%s root_restored=%s',
            index + 1,
            total,
            passed ? 'PASS' : 'FAIL',
            elapsed_s,
            source_restored,
            root_restored
          )
          result
        ensure
          diagnostic.clear_current_solid
        end

        def inventory_targets(model, selection, phase1, base)
          skipped = Hash.new(0)
          targets = []
          selected = phase1.selected_entities(model)
          selection_ids = selection.each_with_object({}) do |entity, ids|
            ids[entity.object_id] = true
          end

          selected.each do |entity|
            unless selection_ids[entity.object_id]
              skipped[:not_in_original_selection] += 1
              next
            end
            unless entity.respond_to?(:valid?) && entity.valid?
              skipped[:invalid_entity] += 1
              next
            end
            unless entity.parent == model
              skipped[:not_top_level] += 1
              next
            end
            unless entity.respond_to?(:definition) && entity.definition&.valid?
              skipped[:invalid_definition] += 1
              next
            end
            unless entity.respond_to?(:manifold?) && entity.manifold? == true
              skipped[:not_manifold] += 1
              next
            end

            counts = base.geometry_counts(entity)
            unless counts[:faces].to_i > FACE_LIMIT_EXCLUSIVE
              skipped[:face_count_not_over_limit] += 1
              next
            end

            targets << {
              entity: entity,
              label: safe_label(phase1, entity),
              pid: entity_identity(entity),
              counts: counts
            }
          rescue StandardError => error
            skipped[:inventory_error] += 1
            skipped[:inventory_error_samples] ||= []
            skipped[:inventory_error_samples] << {
              entity: entity.to_s,
              error: "#{error.class}: #{error.message}"
            }
          end

          targets.sort_by! do |target|
            [-target[:counts][:faces].to_i, target[:pid].to_i]
          end
          [targets, skipped]
        end

        def install_instrumentation
          return if LocalVertexNormalizer.ancestors.include?(DetailedInstrumentation)

          LocalVertexNormalizer.prepend(DetailedInstrumentation)
        end

        def active_context
          @active_context
        end

        def active_context=(value)
          @active_context = value
        end

        def summarize_arguments(args, kwargs)
          {
            positional: Array(args).map { |value| summarize_value(value) },
            keywords: Hash(kwargs).transform_values { |value| summarize_value(value) }
          }
        end

        def summarize_value(value)
          case value
          when Array
            {
              type: value.class.name,
              length: value.length,
              sample: value.first(2).map { |item| summarize_shallow(item) }
            }
          when Hash
            {
              type: value.class.name,
              size: value.size,
              keys: value.keys.first(20).map(&:to_s)
            }
          else
            summarize_shallow(value)
          end
        rescue StandardError => error
          {
            type: value.class.name,
            summary_error: "#{error.class}: #{error.message}"
          }
        end

        def summarize_shallow(value)
          if value.respond_to?(:persistent_id)
            {
              type: value.class.name,
              persistent_id: value.persistent_id,
              name: value.respond_to?(:name) ? value.name.to_s : nil,
              valid: value.respond_to?(:valid?) ? value.valid? : nil
            }
          elsif value.is_a?(Hash)
            {
              type: value.class.name,
              keys: value.keys.first(12).map(&:to_s)
            }
          elsif value.is_a?(Array)
            {
              type: value.class.name,
              length: value.length
            }
          elsif value.is_a?(String)
            value.length > 240 ? "#{value[0, 240]}..." : value
          elsif value.is_a?(Numeric) || value.is_a?(Symbol) ||
                value == true || value == false || value.nil?
            value
          else
            {
              type: value.class.name,
              inspect: value.inspect[0, 240]
            }
          end
        rescue StandardError
          { type: value.class.name }
        end

        def inventory_log_entry(target)
          {
            label: target[:label],
            pid: target[:pid],
            faces: target[:counts][:faces],
            edges: target[:counts][:edges],
            vertices: target[:counts][:vertices],
            manifold: target[:counts][:manifold]
          }
        end

        def build_log_path(model)
          model_path = model.respond_to?(:path) ? model.path.to_s : ''
          base_dir = if !model_path.empty? && File.directory?(File.dirname(model_path))
                       File.dirname(model_path)
                     else
                       Dir.tmpdir
                     end
          directory = File.join(base_dir, 'LVN_Diagnostic_Logs')
          filename = format(
            'lvn_large_solids_%s_pid%d.log',
            Time.now.strftime('%Y%m%d_%H%M%S'),
            Process.pid
          )
          File.join(directory, filename)
        end

        def safe_label(phase1, entity)
          phase1.entity_label(entity)
        rescue StandardError
          entity.to_s
        end

        def entity_identity(entity)
          if entity.respond_to?(:persistent_id)
            entity.persistent_id.to_i
          else
            entity.object_id
          end
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::
  LvnLargeSolidDetailedLogProbe.run
