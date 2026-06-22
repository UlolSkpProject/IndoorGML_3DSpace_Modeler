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
          STDOUT_READ_BUFFER_SIZE = 4096
          TERMINATE_EXIT_CODE    = 1
          TERMINATE_WAIT_MS      = 200
          DEFAULT_OVERLAP_TOL    = 0.5

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
              return false if result == WAIT_TIMEOUT

              if result == WAIT_OBJECT_0
                @exit_code = get_process_exit_code
                @finished = true
                return true
              end

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
                end
              end
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
              primitive:    [0.00, 0.10],
              overlap:      [0.10, 0.40],
              dual_vertex:  [0.40, 0.42],
              primal_dual:  [0.42, 1.00]
            }.freeze

            def initialize(queue, total_states:, total_transitions:)
              @queue = queue
              @total_states = total_states
              @total_transitions = total_transitions
              @buffer = +''
              @phase = :startup
              @primitive_done = 0
              @dual_done = 0
              @link_done = 0
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
              when /======== Validating Primitive ========/
                @phase = :primitive
                emit(message: 'Validating geometry')
              when /^id:\s+solid_(cell_[^\s]+)/
                emit(current: Regexp.last_match(1), message: "Geometry #{Regexp.last_match(1)}")
              when /^========= VALID =========/
                if @phase == :primitive
                  @primitive_done += 1
                  emit(message: "Geometry validated #{@primitive_done}")
                end
              when /^--- Overlapping tests between Cells ---/
                @phase = :overlap
                emit(force: true, ratio_override: phase_start(:overlap), message: 'Checking cell overlaps')
              when /^--- Constructing Nef Polyhedra ---/
                emit(force: true, ratio_override: phase_ratio(:overlap, 0.30), message: 'Constructing Nef polyhedra')
              when /^--- Constructing AABB tree ---/
                emit(force: true, ratio_override: phase_ratio(:overlap, 0.60), message: 'Constructing AABB tree')
              when /^--- Testing intersections between Nefs ---/
                emit(force: true, ratio_override: phase_ratio(:overlap, 0.90), message: 'Testing cell intersections')
              when /^======== Validating Dual Vertex/
                @phase = :dual_vertex
                emit(force: true, ratio_override: phase_start(:dual_vertex), message: 'Checking State inside CellSpace')
              when /^Cell \(.*\) id=(cell_[^\s]+)\s+--> ok/
                @dual_done += 1
                emit(current: Regexp.last_match(1), message: "Dual vertex #{@dual_done}")
              when /^======== Validating Primal-Dual links/
                @phase = :primal_dual
                emit(force: true, ratio_override: phase_start(:primal_dual), message: 'Checking primal-dual links')
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
              when :primitive
                start, finish = PHASE_WEIGHTS[:primitive]
                bounded_ratio(start + @primitive_done * 0.01, start, finish)
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
              when :primitive then 'Geometry validation'
              when :overlap then 'Overlap test'
              when :dual_vertex then 'Dual vertex check'
              when :primal_dual then "Primal-dual link check (#{@link_done} / #{@total_transitions})"
              when :finished then 'Finished'
              else 'Starting val3dity'
              end
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
              begin
                if session.terminated?
                  completed = true
                  next
                end

                session.join_reader
                drain_val3dity_progress(session, progress, progress_step)

                progress&.complete(progress_step)

                result = build_result_after_process(
                  session.exit_code,
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
              ensure
                session.close
                self.class.unregister_session(session)
                completed = true
              end

              callback.call(result)
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
