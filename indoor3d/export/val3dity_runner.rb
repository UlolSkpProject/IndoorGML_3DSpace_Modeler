# frozen_string_literal: true

require 'fileutils'
require 'fiddle'
require 'json'
require 'rbconfig'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class Val3dityRunner
          VENDOR_ROOT = File.expand_path('../assets/vendor/val3dity-windows-x64-v2.2.0', __dir__)
          WINDOWS_ONLY_MESSAGE = 'Val3dity validity check is currently supported only on Windows because the bundled runtime is val3dity-windows-x64-v2.2.0.'
          CREATE_NO_WINDOW       = 0x08000000
          STARTF_USESTDHANDLES   = 0x00000100
          HANDLE_FLAG_INHERIT    = 0x00000001
          WAIT_OBJECT_0          = 0
          WAIT_TIMEOUT           = 258
          STILL_ACTIVE           = 259
          STDOUT_READ_BUFFER_SIZE = 4096
          TERMINATE_EXIT_CODE    = 1
          TERMINATE_WAIT_MS      = 200
          DEFAULT_OVERLAP_TOL    = 0.5
          STRICT_OVERLAP_TOL     = -1
          OVERLAP_RECHECK_TOLERANCE_MM = 0.5
          OVERLAP_RECHECK_TOLERANCE = OVERLAP_RECHECK_TOLERANCE_MM / 25.4
          OVERLAP_RECHECK_VOLUME_TOLERANCE = OVERLAP_RECHECK_TOLERANCE**3
          OVERLAP_RECHECK_REPORT_KEY = 'indoorgml_modeler_overlap_recheck'

          attr_reader :report_json_path, :report_html_path

          def self.active_sessions
            @active_sessions ||= []
          end

          def self.register_session(session)
            active_sessions << session unless active_sessions.include?(session)
          end

          def self.unregister_session(session)
            active_sessions.delete(session)
          end

          def self.shutting_down?
            @shutting_down == true
          end

          def self.shutting_down!
            @shutting_down = true
          end
          def self.terminate_all(wait_ms: TERMINATE_WAIT_MS)
            active_sessions.dup.each { |session| session.terminate(wait_ms: wait_ms) }
            active_sessions.clear
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] val3dity terminate_all failed: #{e.class}: #{e.message}"
          end

          class Val3dityResult
            attr_reader :valid, :report, :report_json_path, :report_html_path, :error

            def initialize(valid:, report:, report_json_path:, report_html_path:, error: nil)
              @valid = valid
              @report = report
              @report_json_path = report_json_path
              @report_html_path = report_html_path
              @error = error
            end

            def valid?
              @valid == true
            end

            def failed?
              @valid == false && @error.nil?
            end

            def error?
              !@error.nil?
            end
          end

          class Val3dityProcessSession
            attr_reader :exit_code

            def initialize(args:, current_dir:)
              @args = args
              @current_dir = current_dir
              @process_handle = 0
              @thread_handle = 0
              @process_id = nil
              @stdout_read = 0
              @stdout_write = 0
              @reader_thread = nil
              @progress_queue = Queue.new
              @finished = false
              @output_finished = false
              @exit_code = nil
              @terminated = false
              @closed = false
            end

            def start(total_states:, total_transitions:)
              @stdout_read, @stdout_write = create_stdout_pipe

              startup_info = build_startup_info(@stdout_write)
              process_info = [0, 0, 0, 0].pack('Q<Q<L<L<')

              command = wide_string(@args.map { |arg| command_quote(arg) }.join(' '))
              current_dir = wide_string(@current_dir)

              created = create_process_w.call(
                0, command, 0, 0,
                1,
                CREATE_NO_WINDOW,
                0, current_dir,
                startup_info, process_info
              )
              raise "CreateProcessW failed: #{Fiddle.last_error}" if created == 0

              @process_handle, @thread_handle, @process_id = process_info.unpack('Q<Q<L<')

              close_handle.call(@stdout_write)
              @stdout_write = 0

              start_reader_thread(total_states: total_states, total_transitions: total_transitions)
            end

            def finished?
              return true if @finished

              result = wait_for_single_object.call(@process_handle, 0)
              if result == WAIT_TIMEOUT
                return mark_finished_from_output if @output_finished

                return false
              end

              if result == WAIT_OBJECT_0
                @exit_code = get_process_exit_code
                @finished = true
                return true
              end

              return mark_finished_from_output if @output_finished

              IndoorCore::Logger.puts "[IndoorGML] WaitForSingleObject returned #{result}; waiting for val3dity stdout EOF"
              false
            end

            def pop_progress
              @progress_queue.pop(true)
            rescue ThreadError
              nil
            end

            def join_reader
              @reader_thread&.join(1.0)
            end

            def terminated?
              @terminated == true
            end

            def close
              return if @closed

              close_handle.call(@stdout_write) if @stdout_write.to_i.positive?
              close_handle.call(@stdout_read) if @stdout_read.to_i.positive?
              close_handle.call(@thread_handle) if @thread_handle.to_i.positive?
              close_handle.call(@process_handle) if @process_handle.to_i.positive?

              @stdout_write = @stdout_read = @thread_handle = @process_handle = 0
              @closed = true
            end

            def terminate(wait_ms: TERMINATE_WAIT_MS)
              return if @closed
              return close if @process_handle.to_i <= 0

              unless finished?
                ok = terminate_process.call(@process_handle, TERMINATE_EXIT_CODE)
                IndoorCore::Logger.puts "[IndoorGML] TerminateProcess failed: #{Fiddle.last_error}" if ok == 0
                wait_result = wait_ms.to_i.positive? ? wait_for_single_object.call(@process_handle, wait_ms.to_i) : WAIT_TIMEOUT
                kill_process_tree if wait_ms.to_i.positive? && wait_result == WAIT_TIMEOUT
              end

              @terminated = true
              @finished = true
              @exit_code = TERMINATE_EXIT_CODE
              join_reader if wait_ms.to_i.positive?
            rescue StandardError => e
              @progress_queue << {
                percent: nil,
                phase: 'val3dity process',
                message: "terminate failed: #{e.class}: #{e.message}",
                current: nil
              }
            ensure
              close
            end

            private

            def create_stdout_pipe
              sa = [24, 0, 1].pack('L<x4Q<L<')
              read_ptr = [0].pack('Q<')
              write_ptr = [0].pack('Q<')

              ok = create_pipe.call(read_ptr, write_ptr, sa, 0)
              raise "CreatePipe failed: #{Fiddle.last_error}" if ok == 0

              read_handle = read_ptr.unpack1('Q<')
              write_handle = write_ptr.unpack1('Q<')

              ok = set_handle_information.call(read_handle, HANDLE_FLAG_INHERIT, 0)
              raise "SetHandleInformation failed: #{Fiddle.last_error}" if ok == 0

              [read_handle, write_handle]
            end

            def build_startup_info(stdout_write)
              [
                104,
                0,
                0,
                0,
                0, 0, 0, 0,
                0, 0,
                0,
                STARTF_USESTDHANDLES,
                0,
                0,
                0,
                0,
                stdout_write,
                stdout_write
              ].pack('L<x4Q<Q<Q<L<L<L<L<L<L<L<L<S<Sx4Q<Q<Q<Q<')
            end

            def start_reader_thread(total_states:, total_transitions:)
              parser = Val3dityOutputProgress.new(
                @progress_queue,
                total_states: total_states,
                total_transitions: total_transitions
              )

              @reader_thread = Thread.new do
                begin
                  read_process_output { |chunk| parser.feed(chunk) }
                  parser.finish
                rescue StandardError => e
                  @progress_queue << {
                    percent: nil,
                    phase: 'val3dity output',
                    message: "stdout read failed: #{e.class}: #{e.message}",
                    current: nil
                  }
                ensure
                  @output_finished = true
                end
              end
            end

            def mark_finished_from_output
              @exit_code ||= begin
                code = get_process_exit_code
                code == STILL_ACTIVE ? 0 : code
              rescue StandardError
                0
              end
              @finished = true
              true
            end

            def read_process_output
              buffer = "\0" * STDOUT_READ_BUFFER_SIZE
              bytes_read_ptr = [0].pack('L<')

              loop do
                bytes_read_ptr[0, 4] = [0].pack('L<')

                ok = read_file.call(@stdout_read, buffer, STDOUT_READ_BUFFER_SIZE, bytes_read_ptr, 0)
                bytes_read = bytes_read_ptr.unpack1('L<')
                break if ok == 0 || bytes_read == 0

                chunk = buffer.byteslice(0, bytes_read)
                yield chunk if chunk && !chunk.empty?
              end
            end

            def get_process_exit_code
              ptr = [0].pack('L<')
              ok = get_exit_code_process.call(@process_handle, ptr)
              raise "GetExitCodeProcess failed: #{Fiddle.last_error}" if ok == 0

              ptr.unpack1('L<')
            end

            def kernel32
              @kernel32 ||= Fiddle.dlopen('kernel32')
            end

            def create_pipe
              @create_pipe ||= Fiddle::Function.new(
                kernel32['CreatePipe'],
                [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG],
                Fiddle::TYPE_INT
              )
            end

            def set_handle_information
              @set_handle_information ||= Fiddle::Function.new(
                kernel32['SetHandleInformation'],
                [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG, Fiddle::TYPE_LONG],
                Fiddle::TYPE_INT
              )
            end

            def create_process_w
              @create_process_w ||= Fiddle::Function.new(
                kernel32['CreateProcessW'],
                [
                  Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                  Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                  Fiddle::TYPE_INT, Fiddle::TYPE_LONG,
                  Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
                  Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP
                ],
                Fiddle::TYPE_INT
              )
            end

            def read_file
              @read_file ||= Fiddle::Function.new(
                kernel32['ReadFile'],
                [
                  Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG,
                  Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP
                ],
                Fiddle::TYPE_INT
              )
            end

            def wait_for_single_object
              @wait_for_single_object ||= Fiddle::Function.new(
                kernel32['WaitForSingleObject'],
                [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG],
                Fiddle::TYPE_LONG
              )
            end

            def get_exit_code_process
              @get_exit_code_process ||= Fiddle::Function.new(
                kernel32['GetExitCodeProcess'],
                [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
                Fiddle::TYPE_INT
              )
            end

            def close_handle
              @close_handle ||= Fiddle::Function.new(
                kernel32['CloseHandle'],
                [Fiddle::TYPE_VOIDP],
                Fiddle::TYPE_INT
              )
            end

            def terminate_process
              @terminate_process ||= Fiddle::Function.new(
                kernel32['TerminateProcess'],
                [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
                Fiddle::TYPE_INT
              )
            end

            def kill_process_tree
              return unless @process_id.to_i.positive?

              system('taskkill', '/PID', @process_id.to_s, '/T', '/F')
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] taskkill fallback failed: #{e.class}: #{e.message}"
            end

            def command_quote(value)
              %("#{value.to_s.gsub('"', '\"')}")
            end

            def wide_string(value)
              "#{value}\x00".encode('UTF-16LE')
            end
          end

          class Val3dityOutputProgress
            PHASE_WEIGHTS = {
              xsd:          [0.00, 0.02],
              primitive:    [0.02, 0.07],
              xlinks:       [0.07, 0.10],
              overlap:      [0.10, 0.44],
              dual_vertex:  [0.44, 0.49],
              primal_dual:  [0.49, 1.00]
            }.freeze

            def initialize(queue, total_states:, total_transitions:)
              @queue = queue
              @total_states = total_states
              @total_transitions = total_transitions
              @buffer = +''
              @phase = :xsd
              @primitive_done = 0
              @dual_done = 0
              @link_done = 0
              @xlinks_emitted = false
              @last_emit_at = Time.at(0)
            end

            def feed(chunk)
              text = decode_chunk(chunk)
              @buffer << text

              while (index = @buffer.index("\n"))
                line = @buffer.slice!(0..index).strip
                parse_line(line) unless line.empty?
              end
            end

            def finish
              parse_line(@buffer.strip) unless @buffer.strip.empty?
              @phase = :finished
              emit(force: true, ratio_override: 1.0, message: 'val3dity finished')
            end

            private

            def parse_line(line)
              case line
              when /XSD|schema/i
                @phase = :xsd
                emit(force: true, message: 'Validating IndoorGML schema')
              when /======== Validating Primitive ========/
                @phase = :primitive
                emit(force: true, message: 'Validating CellSpace solids')
              when /^id:\s+solid_(cell_[^\s]+)/
                emit(current: Regexp.last_match(1), message: "Geometry #{Regexp.last_match(1)}")
              when /^========= VALID =========/
                if @phase == :primitive
                  @primitive_done += 1
                  emit(message: "Geometry validated #{@primitive_done}")
                end
              when /XLink/i
                @phase = :xlinks
                @xlinks_emitted = true
                emit(force: true, message: 'Checking XLink references')
              when /^--- Overlapping tests between Cells ---/
                emit_xlinks_checkpoint
                @phase = :overlap
                emit(force: true, ratio_override: phase_start(:overlap), message: 'Checking CellSpace overlaps')
              when /^--- Constructing Nef Polyhedra ---/
                emit(force: true, ratio_override: phase_ratio(:overlap, 0.30), message: 'Constructing Nef polyhedra')
              when /^--- Constructing AABB tree ---/
                emit(force: true, ratio_override: phase_ratio(:overlap, 0.60), message: 'Constructing AABB tree')
              when /^--- Testing intersections between Nefs ---/
                emit(force: true, ratio_override: phase_ratio(:overlap, 0.90), message: 'Testing cell intersections')
              when /^======== Validating Dual Vertex/
                @phase = :dual_vertex
                emit(force: true, ratio_override: phase_start(:dual_vertex), message: 'Checking State points inside CellSpaces')
              when /^Cell \(.*\) id=(cell_[^\s]+)\s+--> ok/
                @dual_done += 1
                emit(current: Regexp.last_match(1), message: "Dual vertex #{@dual_done}")
              when /^======== Validating Primal-Dual links/
                @phase = :primal_dual
                emit(force: true, ratio_override: phase_start(:primal_dual), message: 'Checking primal/dual adjacencies')
              when /^Cells id=(cell_[^\s]+) id=(cell_[^\s]+)/
                @link_done += 1
                emit(
                  current: "#{Regexp.last_match(1)} -> #{Regexp.last_match(2)}",
                  message: "Primal-dual link #{@link_done}"
                )
              when /ERROR\s+(\d+):\s+([A-Z0-9_]+)/
                emit(
                  force: true,
                  message: "ERROR #{Regexp.last_match(1)}: #{Regexp.last_match(2)}"
                )
              end
            end

            def emit(force: false, ratio_override: nil, current: nil, message: nil)
              return unless force || Time.now - @last_emit_at >= 0.10

              ratio = ratio_override || current_ratio
              @last_emit_at = Time.now

              @queue << {
                percent: (ratio * 100.0).round,
                phase: phase_label,
                message: message,
                current: current
              }
            end

            def current_ratio
              case @phase
              when :xsd
                phase_ratio(:xsd, 0.50)
              when :primitive
                start, finish = PHASE_WEIGHTS[:primitive]
                bounded_ratio(start + @primitive_done * 0.01, start, finish)
              when :xlinks
                phase_ratio(:xlinks, 0.50)
              when :overlap
                phase_ratio(:overlap, 0.50)
              when :dual_vertex
                start, finish = PHASE_WEIGHTS[:dual_vertex]
                if @total_states > 0
                  bounded_ratio(start + (@dual_done.to_f / @total_states) * (finish - start), start, finish)
                else
                  bounded_ratio(start + @dual_done * 0.001, start, finish)
                end
              when :primal_dual
                start, finish = PHASE_WEIGHTS[:primal_dual]
                if @total_transitions > 0
                  bounded_ratio(start + (@link_done.to_f / @total_transitions) * (finish - start), start, finish)
                else
                  bounded_ratio(start + @link_done * 0.002, start, finish)
                end
              else
                0.0
              end
            end

            def bounded_ratio(value, min, max)
              [[value, min].max, max].min
            end

            def phase_start(phase)
              PHASE_WEIGHTS.fetch(phase).first
            end

            def phase_ratio(phase, local_ratio)
              start, finish = PHASE_WEIGHTS.fetch(phase)
              bounded_ratio(start + (finish - start) * local_ratio, start, finish)
            end

            def phase_label
              case @phase
              when :xsd then '1. XSD Validation'
              when :primitive then '2. Geometry Primal Cells'
              when :xlinks then '3. XLinks Errors'
              when :overlap then '4. Overlap Primal Cells'
              when :dual_vertex then '5. Dual Vertex Inside Cells'
              when :primal_dual then "6. Adjacency in Primal / Dual (#{@link_done} / #{@total_transitions})"
              when :finished then 'Finished'
              else 'Starting val3dity'
              end
            end

            def emit_xlinks_checkpoint
              return if @xlinks_emitted

              @phase = :xlinks
              @xlinks_emitted = true
              emit(force: true, ratio_override: phase_ratio(:xlinks, 0.95), message: 'Checking XLink references')
            end

            def decode_chunk(chunk)
              text = chunk.dup.force_encoding('UTF-8')
              return text if text.valid_encoding?

              chunk.force_encoding('CP949').encode('UTF-8', invalid: :replace, undef: :replace)
            rescue EncodingError
              chunk.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
            end
          end

          def initialize(gml_path, overlap_tol: DEFAULT_OVERLAP_TOL, report_name: 'report')
            @gml_path = File.expand_path(gml_path)
            @work_dir = GmlExporter.output_root
            @report_name = sanitize_report_name(report_name)
            @report_json_path = File.join(@work_dir, "#{@report_name}.json")
            @report_dir = File.join(@work_dir, @report_name)
            @report_html_path = File.join(@report_dir, 'report.html')
            @overlap_tol = normalize_overlap_tol(overlap_tol)
          end

          def validate(progress: nil)
            raise 'Val3dityRunner#validate is deprecated. Use #start with a completion callback.'
          end

          def start(progress: nil, progress_step: :val3dity, report_step: :report, report_view_step: :report_view, &callback)
            raise ArgumentError, 'callback is required' unless callback

            ensure_supported_platform!
            ensure_runtime_files!
            FileUtils.rm_f(@report_json_path)

            progress&.running(progress_step)
            progress&.detail(
              progress_step,
              percent: 0,
              phase: '1. XSD Validation',
              message: 'Starting val3dity schema validation',
              current: File.basename(@gml_path)
            )

            args = [
              exe_path,
              @gml_path,
              '--verbose'
            ]
            args.concat(['--overlap_tol', format_tolerance(@overlap_tol)]) unless @overlap_tol.nil?
            args.concat(['-r', @report_json_path])

            session = Val3dityProcessSession.new(
              args: args,
              current_dir: VENDOR_ROOT
            )
            indoor_model = IndoorModel.current
            totals = validation_progress_totals(indoor_model)
            session.start(
              total_states: totals[:states],
              total_transitions: totals[:transitions]
            )
            self.class.register_session(session)

            completed = false

            UI.start_timer(0.1, true) do
              next false if completed

              drain_val3dity_progress(session, progress, progress_step)
              true
            end

            UI.start_timer(0.2, true) do
              next false if completed
              next true unless session.finished?

              result = nil
              exit_code = nil
              build_report_later = false
              begin
                if session.terminated?
                  result = Val3dityResult.new(
                    valid: false,
                    report: nil,
                    report_json_path: @report_json_path,
                    report_html_path: @report_html_path,
                    error: RuntimeError.new('val3dity validation was canceled.')
                  )
                else
                  session.join_reader
                  drain_val3dity_progress(session, progress, progress_step)

                  progress&.complete(progress_step)
                  progress&.running(report_step) if report_step
                  exit_code = session.exit_code
                  build_report_later = true
                end
              rescue StandardError => e
                result = Val3dityResult.new(
                  valid: false,
                  report: nil,
                  report_json_path: @report_json_path,
                  report_html_path: @report_html_path,
                  error: e
                )
              ensure
                session.close
                self.class.unregister_session(session)
                completed = true
              end

              if build_report_later
                UI.start_timer(0.05, false) do
                  begin
                    result = build_result_after_process(
                      exit_code,
                      progress,
                      report_step: report_step,
                      report_view_step: report_view_step
                    )
                  rescue StandardError => e
                    result = Val3dityResult.new(
                      valid: false,
                      report: nil,
                      report_json_path: @report_json_path,
                      report_html_path: @report_html_path,
                      error: e
                    )
                  end

                  callback.call(result)
                  false
                end
              else
                callback.call(result) if result
              end
              false
            end

            session
          rescue StandardError => e
            self.class.unregister_session(session) if session
            session&.close
            raise unless callback

            callback.call(
              Val3dityResult.new(
                valid: false,
                report: nil,
                report_json_path: @report_json_path,
                report_html_path: @report_html_path,
                error: e
              )
            )
          end

          private

          def normalize_overlap_tol(value)
            return nil if value.nil?

            tolerance = Float(value)
            return STRICT_OVERLAP_TOL if tolerance == STRICT_OVERLAP_TOL
            return nil if tolerance.negative?

            tolerance
          rescue ArgumentError, TypeError
            raise ArgumentError, "Invalid overlap_tol: #{value.inspect}"
          end

          def format_tolerance(value)
            format('%.15g', value.to_f)
          end

          def sanitize_report_name(value)
            name = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
            name.empty? ? 'report' : name
          end

          def validation_progress_totals(indoor_model)
            exportable_cell_spaces = indoor_model.cell_spaces.select do |cell_space|
              cell_space&.valid_sketchup_group && cell_space.duality_state&.valid?
            end
            exportable_transitions = indoor_model.transitions.select do |transition|
              transition&.valid? &&
                transition.state1&.valid? &&
                transition.state2&.valid? &&
                exportable_cell_spaces.include?(transition.state1.duality_cell) &&
                exportable_cell_spaces.include?(transition.state2.duality_cell)
            end

            {
              states: exportable_cell_spaces.length,
              transitions: exportable_transitions.length
            }
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] val3dity progress totals failed: #{e.class}: #{e.message}"
            {
              states: indoor_model.states.count(&:valid?),
              transitions: indoor_model.transitions.count(&:valid?)
            }
          end

          def ensure_supported_platform!
            raise WINDOWS_ONLY_MESSAGE unless windows?
          end

          def ensure_runtime_files!
            raise "val3dity.exe was not found:\n#{exe_path}" unless File.exist?(exe_path)
            raise "GML file was not found:\n#{@gml_path}" unless File.exist?(@gml_path)

            FileUtils.mkdir_p(@work_dir)
          end

          def drain_val3dity_progress(session, progress, progress_step)
            return unless progress

            while (payload = session.pop_progress)
              progress.detail(
                progress_step,
                percent: payload[:percent],
                phase: payload[:phase],
                message: payload[:message],
                current: payload[:current]
              )
            end
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] val3dity progress drain failed: #{e.class}: #{e.message}"
          end

          def build_result_after_process(exit_code, progress = nil, report_step: :report, report_view_step: :report_view)
            raise "val3dity failed: exit code #{exit_code}" unless exit_code == 0
            raise 'val3dity failed to create report.json.' unless File.exist?(@report_json_path)

            normalize_report_encoding

            progress&.running(report_step) if report_step
            raw_report = JSON.parse(File.read(@report_json_path, encoding: 'UTF-8'))
            recheck_overlap_errors!(raw_report)
            File.write(@report_json_path, JSON.pretty_generate(raw_report), encoding: 'UTF-8')
            progress&.complete(report_step) if report_step

            progress&.running(report_view_step) if report_view_step
            prepare_html_report(raw_report)
            progress&.complete(report_view_step) if report_view_step

            Val3dityResult.new(
              valid: raw_report['validity'] == true,
              report: raw_report,
              report_json_path: @report_json_path,
              report_html_path: @report_html_path,
              error: nil
            )
          end

          def normalize_report_encoding
            content = File.binread(@report_json_path)
            content = decode_report_content(content)
            File.write(@report_json_path, content, encoding: 'UTF-8')
          end

          def prepare_html_report(raw_report)
            FileUtils.rm_rf(@report_dir)
            FileUtils.mkdir_p(@report_dir)
            File.write(@report_html_path, fallback_report_html(raw_report), encoding: 'UTF-8')
          end

          def fallback_report_html(raw_report)
            <<~HTML
              <!doctype html>
              <html>
              <head>
                <meta charset="utf-8">
                <title>val3dity report</title>
                <style>
                  :root { color-scheme: light; font-family: Arial, sans-serif; color: #172033; background: #f5f7fb; }
                  body { margin: 0; padding: 28px; }
                  main { max-width: 980px; margin: 0 auto; }
                  h1 { margin: 0 0 6px; font-size: 28px; }
                  h2 { margin: 0 0 14px; font-size: 18px; }
                  .subtitle { margin: 0 0 22px; color: #667085; }
                  .card { background: #fff; border: 1px solid #e4e7ec; border-radius: 8px; padding: 18px; margin-bottom: 16px; }
                  .meta { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 10px; }
                  .metric { background: #f8fafc; border-radius: 6px; padding: 10px 12px; }
                  .metric .label { color: #667085; font-size: 12px; }
                  .metric .value { margin-top: 4px; font-weight: 700; overflow-wrap: anywhere; }
                  .valid { color: #067647; }
                  .invalid { color: #b42318; }
                  .suppressed { color: #067647; font-weight: 700; }
                  .kept { color: #b42318; font-weight: 700; }
                  table { width: 100%; border-collapse: collapse; }
                  th, td { border-bottom: 1px solid #eaecf0; padding: 9px 8px; text-align: left; vertical-align: top; }
                  th { color: #475467; font-size: 12px; text-transform: uppercase; letter-spacing: .04em; }
                  code { background: #f2f4f7; border-radius: 4px; padding: 2px 5px; }
                  .empty { color: #667085; margin: 0; }
                  .summary-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 12px; }
                  .error-group { border-top: 1px solid #eaecf0; padding-top: 14px; margin-top: 14px; }
                  .error-group:first-child { border-top: 0; padding-top: 0; margin-top: 0; }
                  .error-title { margin: 0 0 8px; font-weight: 700; }
                  .error-items { margin: 0; padding-left: 22px; }
                  .error-items li { margin: 5px 0; overflow-wrap: anywhere; }
                </style>
              </head>
              <body>
                <main>
                  <h1>val3dity report</h1>
                  <p class="subtitle">IndoorGML validation result</p>
                  #{report_version_section(raw_report)}
                  #{report_overlap_recheck_section(raw_report)}
                  #{report_error_kinds_section(raw_report)}
                  #{report_error_items_section(raw_report)}
                  #{report_summary_section(raw_report)}
                </main>
              </body>
              </html>
            HTML
          end

          def report_version_section(raw_report)
            validity = raw_report['validity'] == true
            <<~HTML
              <section class="card">
                <h2>val3dity version</h2>
                <div class="meta">
                  #{metric_html('Version', raw_report['val3dity_version'] || 'unknown')}
                  #{metric_html('Result', validity ? 'VALID' : 'INVALID', validity ? 'valid' : 'invalid')}
                  #{metric_html('Input type', raw_report['input_file_type'] || '-')}
                  #{metric_html('Checked at', report_checked_at(raw_report['time']))}
                </div>
              </section>
            HTML
          end

          def report_error_kinds_section(raw_report)
            rows = error_kind_rows(raw_report)
            body = if rows.empty?
                     '<p class="empty">No errors.</p>'
                   else
                     <<~HTML
                       <table>
                         <thead><tr><th>Code</th><th>Error</th><th>Count</th></tr></thead>
                         <tbody>
                           #{rows.map { |row| "<tr><td><code>#{html_escape(row[:code])}</code></td><td>#{html_escape(row[:description])}</td><td>#{row[:count]}</td></tr>" }.join}
                         </tbody>
                       </table>
                     HTML
                   end
            <<~HTML
              <section class="card">
                <h2>Error 종류</h2>
                #{body}
              </section>
            HTML
          end

          def report_error_items_section(raw_report)
            rows = error_item_rows(raw_report)
            body = if rows.empty?
                     '<p class="empty">No error items.</p>'
                   else
                     error_item_groups_html(rows)
                   end
            <<~HTML
              <section class="card">
                <h2>Error에 걸린 항목</h2>
                #{body}
              </section>
            HTML
          end

          def report_summary_section(raw_report)
            <<~HTML
              <section class="card">
                <h2>요약</h2>
                <div class="summary-grid">
                  #{metric_html('Features', "#{valid_count(raw_report['features_overview'])} / #{total_count(raw_report['features_overview'])} valid")}
                  #{metric_html('Primitives', "#{valid_count(raw_report['primitives_overview'])} / #{total_count(raw_report['primitives_overview'])} valid")}
                  #{metric_html('snap_tol', raw_report.dig('parameters', 'snap_tol') || '-')}
                  #{metric_html('overlap_tol', raw_report.dig('parameters', 'overlap_tol') || '-')}
                  #{metric_html('planarity_d2p_tol', raw_report.dig('parameters', 'planarity_d2p_tol') || '-')}
                  #{metric_html('planarity_n_tol', raw_report.dig('parameters', 'planarity_n_tol') || '-')}
                </div>
              </section>
            HTML
          end

          def metric_html(label, value, class_name = nil)
            value_class = ['value', class_name].compact.join(' ')
            <<~HTML
              <div class="metric">
                <div class="label">#{html_escape(label)}</div>
                <div class="#{value_class}">#{html_escape(value)}</div>
              </div>
            HTML
          end

          def report_checked_at(value)
            text = value.to_s.strip
            return '-' if text.empty?

            text.gsub('대한민국 표준시', 'KST')
          end

          def report_overlap_recheck_section(raw_report)
            rows = Array(raw_report[OVERLAP_RECHECK_REPORT_KEY])
            return '' if rows.empty?

            <<~HTML
              <section class="card">
                <h2>Overlap Recheck</h2>
                <table>
                  <thead>
                    <tr><th>Code</th><th>Cells</th><th>Actual Volume</th><th>Effective Penetration</th><th>Plane Distance</th><th>Planar Gap</th><th>Face Overlap</th><th>Status</th><th>Reason</th></tr>
                  </thead>
                  <tbody>
                    #{rows.map { |row| overlap_recheck_row_html(row) }.join}
                  </tbody>
                </table>
              </section>
            HTML
          end

          def overlap_recheck_row_html(row)
            cells = Array(row['cells']).join(' and ')
            distance = row['distance_mm'].nil? ? '-' : "#{format('%.6g', row['distance_mm'])} mm"
            gap = row['gap_mm'].nil? ? '-' : "#{format('%.6g', row['gap_mm'])} mm"
            overlap = row['overlap_area_mm2'].nil? ? '-' : "#{format('%.6g', row['overlap_area_mm2'])} mm2"
            volume = row['actual_overlap_volume_mm3'].nil? ? '-' : "#{format('%.6g', row['actual_overlap_volume_mm3'])} mm3"
            effective_penetration = row['effective_penetration_mm'].nil? ? '-' : "#{format('%.6g', row['effective_penetration_mm'])} mm"
            status = row['tolerated'] ? 'SUPPRESSED' : 'KEPT'
            status_class = row['tolerated'] ? 'suppressed' : 'kept'
            <<~HTML
              <tr>
                <td><code>#{html_escape(row['code'])}</code></td>
                <td>#{html_escape(cells.empty? ? '-' : cells)}</td>
                <td>#{html_escape(volume)}</td>
                <td>#{html_escape(effective_penetration)}</td>
                <td>#{html_escape(distance)}</td>
                <td>#{html_escape(gap)}</td>
                <td>#{html_escape(overlap)}</td>
                <td class="#{status_class}">#{html_escape(status)}</td>
                <td>#{html_escape(row['reason'])}</td>
              </tr>
            HTML
          end

          def recheck_overlap_errors!(raw_report)
            results = []
            remove_rechecked_errors!(Array(raw_report['dataset_errors']), results, raw_report['input_file'])

            Array(raw_report['features']).each do |feature|
              remove_rechecked_errors!(Array(feature['errors']), results, feature['id'])
              Array(feature['primitives']).each do |primitive|
                remove_rechecked_errors!(
                  Array(primitive['errors']),
                  results,
                  feature['id'],
                  primitive['id']
                )
              end
            end

            raw_report[OVERLAP_RECHECK_REPORT_KEY] = results unless results.empty?
            raw_report['validity'] = true if !results.empty? && error_item_rows(raw_report).empty?
          end

          def remove_rechecked_errors!(errors, results, *context)
            errors.delete_if do |error|
              result = overlap_error_recheck_result(error, *context)
              next false unless result

              results << result
              result['tolerated'] == true
            end
          end

          def overlap_error_recheck_result(error, *context)
            code = error_code_number(error['code'])
            return nil unless [701, 704].include?(code)

            text = ([error] + context).map { |value| value.is_a?(Hash) ? value.to_json : value.to_s }.join(' ')
            cell_ids = overlap_recheck_cell_map.keys.select { |cell_id| text.include?(cell_id) }.uniq
            return overlap_recheck_result(code, [], false, 'cell pair not found in val3dity error') if cell_ids.length < 2

            recheck_cell_pair(code, cell_ids[0], cell_ids[1])
          end

          def recheck_cell_pair(code, cell_id1, cell_id2)
            cell1 = overlap_recheck_cell_map[cell_id1]
            cell2 = overlap_recheck_cell_map[cell_id2]
            unless cell1&.valid_sketchup_group && cell2&.valid_sketchup_group
              return overlap_recheck_result(code, [cell_id1, cell_id2], false, 'cell not found in current SketchUp model')
            end

            faces1 = Utils::Geometry.world_faces(cell1.valid_sketchup_group)
            faces2 = Utils::Geometry.world_faces(cell2.valid_sketchup_group)
            if faces1.empty? || faces2.empty?
              return overlap_recheck_result(code, [cell_id1, cell_id2], false, 'cell has no usable faces')
            end

            best = best_overlap_recheck_face_pair(code, faces1, faces2)
            return overlap_recheck_result(code, [cell_id1, cell_id2], false, overlap_recheck_missing_pair_reason(code)) unless best

            decision = overlap_recheck_decision(
              code,
              best,
              faces1,
              faces2,
              cell1.valid_sketchup_group,
              cell2.valid_sketchup_group
            )

            overlap_recheck_result(
              code,
              [cell_id1, cell_id2],
              decision[:tolerated],
              decision[:reason],
              distance: decision[:candidate][:distance],
              gap: decision[:candidate][:gap],
              overlap_area: decision[:candidate][:overlap_area],
              actual_overlap_volume: decision[:actual_overlap_volume],
              effective_penetration: decision[:effective_penetration]
            )
          end

          def best_overlap_recheck_face_pair(code, faces1, faces2)
            best = nil
            faces1.each do |face1|
              faces2.each do |face2|
                next unless overlap_recheck_face_direction_valid?(code, face1, face2)

                distance = face_pair_plane_distance(face1, face2)
                overlap_area = if distance <= OVERLAP_RECHECK_TOLERANCE
                                 Utils::Geometry.coplanar_overlap_metrics(face1, face2, OVERLAP_RECHECK_TOLERANCE)&.dig(:area).to_f
                               else
                                 0.0
                               end
                gap = if distance <= OVERLAP_RECHECK_TOLERANCE && overlap_area <= Utils::Geometry.area_tolerance(OVERLAP_RECHECK_TOLERANCE)
                        projected_face_gap_distance(face1, face2)
                      else
                        0.0
                      end
                candidate = { distance: distance, gap: gap, overlap_area: overlap_area }
                best = better_overlap_recheck_candidate(code, best, candidate)
              end
            end
            best
          end

          def overlap_recheck_face_direction_valid?(code, face1, face2)
            if code == 704
              Utils::Geometry.normals_opposite?(face1[:normal], face2[:normal])
            else
              Utils::Geometry.normals_parallel?(face1[:normal], face2[:normal])
            end
          end

          def better_overlap_recheck_candidate(code, current, candidate)
            return candidate unless current

            if code == 701
              return candidate if candidate[:overlap_area] > current[:overlap_area]
              return candidate if candidate[:overlap_area] == current[:overlap_area] && candidate[:distance] < current[:distance]

              return current
            end

            candidate_tolerable = overlap_recheck_candidate_tolerable?(candidate, code)
            current_tolerable = overlap_recheck_candidate_tolerable?(current, code)
            return candidate if candidate_tolerable && !current_tolerable
            return current if current_tolerable && !candidate_tolerable
            return candidate if candidate_tolerable && candidate[:overlap_area] > current[:overlap_area]

            return candidate if candidate[:distance] < current[:distance]
            return candidate if candidate[:distance] == current[:distance] && candidate[:gap].to_f < current[:gap].to_f
            return candidate if candidate[:distance] == current[:distance] &&
                                candidate[:gap].to_f == current[:gap].to_f &&
                                candidate[:overlap_area] > current[:overlap_area]

            current
          end

          def overlap_recheck_decision(code, candidate, faces1, faces2, group1, group2)
            return overlap_recheck_701_decision(candidate, faces1, faces2, group1, group2) if code == 701

            tolerated = overlap_recheck_candidate_tolerable?(candidate, code)
            reason = if tolerated
                       overlap_recheck_tolerated_reason(code, candidate)
                     elsif candidate[:distance] > OVERLAP_RECHECK_TOLERANCE
                       "nearest #{overlap_recheck_face_pair_label(code)} face distance exceeds #{OVERLAP_RECHECK_TOLERANCE_MM} mm"
                     else
                       "#{overlap_recheck_face_pair_label(code)} and near-coplanar, but overlap area was not detected"
                     end
            { tolerated: tolerated, reason: reason, candidate: candidate, actual_overlap_volume: nil, effective_penetration: nil }
          end

          def overlap_recheck_701_decision(candidate, faces1, faces2, group1, group2)
            actual_volume = actual_solid_intersection_volume(group1, group2)
            unless actual_volume
              return {
                tolerated: false,
                reason: 'actual solid intersection volume could not be computed',
                candidate: candidate,
                actual_overlap_volume: nil,
                effective_penetration: nil
              }
            end

            if actual_volume <= OVERLAP_RECHECK_VOLUME_TOLERANCE
              return {
                tolerated: true,
                reason: 'actual solid intersection volume is below tolerance',
                candidate: candidate,
                actual_overlap_volume: actual_volume,
                effective_penetration: nil
              }
            end

            opposite_candidate = best_overlap_recheck_face_pair(704, faces1, faces2)
            if opposite_candidate && overlap_recheck_candidate_tolerable?(opposite_candidate, 704)
              effective_penetration = actual_volume / opposite_candidate[:overlap_area].to_f
              tolerated = effective_penetration <= OVERLAP_RECHECK_TOLERANCE
              return {
                tolerated: tolerated,
                reason: tolerated ? "actual intersection effective penetration is within #{OVERLAP_RECHECK_TOLERANCE_MM} mm" : "actual intersection effective penetration exceeds #{OVERLAP_RECHECK_TOLERANCE_MM} mm",
                candidate: opposite_candidate,
                actual_overlap_volume: actual_volume,
                effective_penetration: effective_penetration
              }
            end

            {
              tolerated: false,
              reason: 'actual solid intersection volume detected without opposite-normal shared face',
              candidate: candidate,
              actual_overlap_volume: actual_volume,
              effective_penetration: nil
            }
          end

          def overlap_recheck_candidate_tolerable?(candidate, code)
            return false unless candidate[:distance] <= OVERLAP_RECHECK_TOLERANCE
            if code == 701
              return candidate[:overlap_area] <= Utils::Geometry.area_tolerance(OVERLAP_RECHECK_TOLERANCE)
            end

            candidate[:overlap_area] > Utils::Geometry.area_tolerance(OVERLAP_RECHECK_TOLERANCE)
          end

          def overlap_recheck_tolerated_reason(code, candidate)
            if code == 701 && candidate[:overlap_area] <= Utils::Geometry.area_tolerance(OVERLAP_RECHECK_TOLERANCE)
              'no overlap detected by SketchUp recheck'
            else
              "#{overlap_recheck_face_pair_label(code)} and same plane within #{OVERLAP_RECHECK_TOLERANCE_MM} mm"
            end
          end

          def actual_solid_intersection_volume(group1, group2)
            return nil unless group1&.valid? && group2&.valid?
            return nil unless group1.respond_to?(:copy)

            model = Sketchup.active_model
            return nil unless model

            started = false
            copy1 = nil
            copy2 = nil
            result = nil
            volume = nil

            model.start_operation('IndoorGML overlap recheck', true)
            started = true

            copy1 = group1.copy
            copy2 = group2.copy
            return nil unless copy1.respond_to?(:intersect)

            result = copy1.intersect(copy2)
            volume = if result&.valid? && result.respond_to?(:volume)
                       result.volume.to_f.abs
                     else
                       0.0
                     end
            volume
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Actual overlap volume failed: #{e.class}: #{e.message}"
            nil
          ensure
            model.abort_operation if started
            [result, copy1, copy2].compact.each do |entity|
              entity.erase! if entity.respond_to?(:valid?) && entity.valid?
            rescue StandardError
              nil
            end
          end

          def overlap_recheck_missing_pair_reason(code)
            "#{overlap_recheck_face_pair_label(code)} face pair not found"
          end

          def overlap_recheck_face_pair_label(code)
            code == 704 ? 'opposite-normal' : 'parallel'
          end

          def face_pair_plane_distance(face1, face2)
            distances = face2[:points].map { |point| point_plane_distance(point, face1[:normal], face1[:points].first) }
            distances.concat(face1[:points].map { |point| point_plane_distance(point, face2[:normal], face2[:points].first) })
            distances.max || Float::INFINITY
          end

          def point_plane_distance(point, normal, plane_point)
            vector = plane_point.vector_to(point)
            Utils::Geometry.dot_product(vector, normal).abs.to_f
          end

          def projected_face_gap_distance(face1, face2)
            axis = Utils::Geometry.dominant_axis(face1[:normal])
            polygon1 = Utils::Geometry.project_points_for_axis(face1[:points], axis)
            polygon2 = Utils::Geometry.project_points_for_axis(face2[:points], axis)
            polygon_gap_distance_2d(polygon1, polygon2)
          end

          def polygon_gap_distance_2d(polygon1, polygon2)
            return 0.0 if polygon_points_intersect?(polygon1, polygon2)
            return 0.0 if polygon_edges_intersect?(polygon1, polygon2)

            edges1 = polygon_edges(polygon1)
            edges2 = polygon_edges(polygon2)
            distances = []
            polygon1.each { |point| edges2.each { |edge| distances << point_segment_distance_2d(point, edge[0], edge[1]) } }
            polygon2.each { |point| edges1.each { |edge| distances << point_segment_distance_2d(point, edge[0], edge[1]) } }
            distances.min || Float::INFINITY
          end

          def polygon_points_intersect?(polygon1, polygon2)
            polygon1.any? { |point| point_in_polygon_2d?(point, polygon2) } ||
              polygon2.any? { |point| point_in_polygon_2d?(point, polygon1) }
          end

          def polygon_edges(polygon)
            polygon.each_index.map { |index| [polygon[index], polygon[(index + 1) % polygon.length]] }
          end

          def polygon_edges_intersect?(polygon1, polygon2)
            edges1 = polygon_edges(polygon1)
            edges2 = polygon_edges(polygon2)
            edges1.any? do |edge1|
              edges2.any? { |edge2| segments_intersect_2d?(edge1[0], edge1[1], edge2[0], edge2[1]) }
            end
          end

          def segments_intersect_2d?(a, b, c, d)
            orientation1 = orientation_2d(a, b, c)
            orientation2 = orientation_2d(a, b, d)
            orientation3 = orientation_2d(c, d, a)
            orientation4 = orientation_2d(c, d, b)
            return true if orientation1 * orientation2 < 0.0 && orientation3 * orientation4 < 0.0
            return true if orientation1.abs <= 1.0e-9 && point_on_segment_2d?(c, a, b)
            return true if orientation2.abs <= 1.0e-9 && point_on_segment_2d?(d, a, b)
            return true if orientation3.abs <= 1.0e-9 && point_on_segment_2d?(a, c, d)
            return true if orientation4.abs <= 1.0e-9 && point_on_segment_2d?(b, c, d)

            false
          end

          def orientation_2d(a, b, c)
            ((b[0] - a[0]) * (c[1] - a[1])) - ((b[1] - a[1]) * (c[0] - a[0]))
          end

          def point_on_segment_2d?(point, segment_start, segment_end)
            point[0] >= [segment_start[0], segment_end[0]].min - 1.0e-9 &&
              point[0] <= [segment_start[0], segment_end[0]].max + 1.0e-9 &&
              point[1] >= [segment_start[1], segment_end[1]].min - 1.0e-9 &&
              point[1] <= [segment_start[1], segment_end[1]].max + 1.0e-9
          end

          def point_in_polygon_2d?(point, polygon)
            inside = false
            j = polygon.length - 1
            polygon.each_with_index do |vertex, i|
              previous = polygon[j]
              if ((vertex[1] > point[1]) != (previous[1] > point[1])) &&
                 (point[0] < (previous[0] - vertex[0]) * (point[1] - vertex[1]) / (previous[1] - vertex[1]) + vertex[0])
                inside = !inside
              end
              j = i
            end
            inside
          end

          def point_segment_distance_2d(point, segment_start, segment_end)
            dx = segment_end[0] - segment_start[0]
            dy = segment_end[1] - segment_start[1]
            length_squared = (dx * dx) + (dy * dy)
            return Math.sqrt(((point[0] - segment_start[0])**2) + ((point[1] - segment_start[1])**2)) if length_squared <= 0.0

            t = (((point[0] - segment_start[0]) * dx) + ((point[1] - segment_start[1]) * dy)) / length_squared
            t = [[t, 0.0].max, 1.0].min
            closest = [segment_start[0] + (t * dx), segment_start[1] + (t * dy)]
            Math.sqrt(((point[0] - closest[0])**2) + ((point[1] - closest[1])**2))
          end

          def overlap_recheck_result(code, cell_ids, tolerated, reason, distance: nil, gap: nil, overlap_area: nil, actual_overlap_volume: nil, effective_penetration: nil)
            {
              'code' => code,
              'cells' => cell_ids,
              'tolerated' => tolerated,
              'reason' => reason,
              'distance_mm' => distance.nil? ? nil : distance.to_f * 25.4,
              'gap_mm' => gap.nil? ? nil : gap.to_f * 25.4,
              'overlap_area_mm2' => overlap_area.nil? ? nil : overlap_area.to_f * 25.4 * 25.4,
              'actual_overlap_volume_mm3' => actual_overlap_volume.nil? ? nil : actual_overlap_volume.to_f * 25.4 * 25.4 * 25.4,
              'effective_penetration_mm' => effective_penetration.nil? ? nil : effective_penetration.to_f * 25.4
            }
          end

          def error_code_number(code)
            code.to_s[/\d+/].to_i
          end

          def overlap_recheck_cell_map
            @overlap_recheck_cell_map ||= IndoorModel.current.cell_spaces.each_with_object({}) do |cell_space, map|
              map["cell_#{safe_gml_id(cell_space.id)}"] = cell_space
            end
          end

          def safe_gml_id(value)
            value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
          end

          def error_kind_rows(raw_report)
            counts = Hash.new { |hash, key| hash[key] = { code: key, description: 'UNKNOWN', count: 0 } }
            error_item_rows(raw_report).each do |row|
              item = counts[row[:code]]
              item[:description] = row[:description]
              item[:count] += 1
            end
            counts.values.sort_by { |row| row[:code].to_s }
          end

          def error_item_rows(raw_report)
            rows = []
            Array(raw_report['dataset_errors']).each do |error|
              rows << error_row('Dataset', raw_report['input_file'], error)
            end
            Array(raw_report['features']).each do |feature|
              Array(feature['errors']).each do |error|
                rows << error_row('Feature', error['id'].to_s.empty? ? feature['id'] : error['id'], error)
              end
              Array(feature['primitives']).each do |primitive|
                Array(primitive['errors']).each do |error|
                  rows << error_row('Primitive', primitive['id'], error)
                end
              end
            end
            rows
          end

          def error_row(scope, item, error)
            {
              scope: scope,
              item: item,
              code: error['code'],
              description: error['description'] || error['type'] || 'UNKNOWN'
            }
          end

          def error_item_groups_html(rows)
            grouped = rows.group_by { |row| [row[:code], row[:description]] }
            grouped.sort_by { |(code, description), _items| [code.to_s, description.to_s] }.map do |(code, description), items|
              <<~HTML
                <div class="error-group">
                  <p class="error-title"><code>#{html_escape(code)}</code> : #{html_escape(description)}</p>
                  <ul class="error-items">
                    #{items.map { |row| "<li>#{html_escape(error_item_label(row))}</li>" }.join}
                  </ul>
                </div>
              HTML
            end.join
          end

          def error_item_label(row)
            item = row[:item].to_s
            cells = item.scan(/cell_[A-Za-z0-9_.-]+/)
            return cells.uniq.join(' and ') if cells.length >= 2

            row[:scope].to_s == 'Dataset' ? item : "#{row[:scope]} #{item}"
          end

          def html_escape(value)
            value.to_s
                 .gsub('&', '&amp;')
                 .gsub('<', '&lt;')
                 .gsub('>', '&gt;')
                 .gsub('"', '&quot;')
                 .gsub("'", '&#39;')
          end

          def total_count(overview)
            Array(overview).sum { |item| item['total'].to_i }
          end

          def valid_count(overview)
            Array(overview).sum { |item| item['valid'].to_i }
          end

          def invalid_count(overview)
            total_count(overview) - valid_count(overview)
          end

          def decode_report_content(content)
            utf8 = content.dup.force_encoding('UTF-8')
            return utf8 if utf8.valid_encoding?

            content.force_encoding(report_source_encoding).encode('UTF-8')
          rescue EncodingError
            content.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
          end

          def report_source_encoding
            @report_source_encoding ||= %w[CP949 Windows-949 EUC-KR].filter_map do |name|
              Encoding.find(name)
            rescue ArgumentError
              nil
            end.first || Encoding.default_external
          end

          def exe_path
            File.join(VENDOR_ROOT, 'val3dity.exe')
          end

          def windows?
            RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/i
          end
        end

      end
    end
  end
end
