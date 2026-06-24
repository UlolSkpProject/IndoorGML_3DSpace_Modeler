# frozen_string_literal: true

require 'fileutils'
require 'fiddle'
require 'json'
require 'rbconfig'
require 'rexml/document'

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
          OVERLAP_RECHECK_TOLERANCE = Utils::Geometry::DEFAULT_TOLERANCE
          OVERLAP_RECHECK_TOLERANCE_MM = OVERLAP_RECHECK_TOLERANCE * 25.4
          OVERLAP_RECHECK_VOLUME_TOLERANCE = OVERLAP_RECHECK_TOLERANCE**3
          OVERLAP_RECHECK_REPORT_KEY = 'indoorgml_modeler_overlap_recheck'
          STRICT_VALIDITY_KEY = 'strict_val3dity_validity'
          EXTENSION_VALIDITY_KEY = 'extension_policy_validity'
          VALIDATION_STATUS_KEY = 'indoorgml_modeler_validation_status'
          STRICT_ERRORS_REPORT_KEY = 'indoorgml_modeler_strict_errors'
          OVERLAP_RECHECK_NUMERIC_EPSILON = OVERLAP_RECHECK_TOLERANCE * 0.01

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

          def start(progress: nil, progress_step: :val3dity, recheck_step: :extension_recheck, report_step: :report, report_view_step: nil, &callback)
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
                      recheck_step: recheck_step,
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

          def build_result_after_process(exit_code, progress = nil, recheck_step: :extension_recheck, report_step: :report, report_view_step: nil)
            raise "val3dity failed: exit code #{exit_code}" unless exit_code == 0
            raise 'val3dity failed to create report.json.' unless File.exist?(@report_json_path)

            normalize_report_encoding

            raw_report = JSON.parse(File.read(@report_json_path, encoding: 'UTF-8'))
            preserve_strict_validation!(raw_report)
            if recheck_step
              progress&.running(recheck_step)
              progress&.detail(
                recheck_step,
                percent: 0,
                phase: 'Collect 701/704 errors',
                message: 'Rechecking val3dity 701/704 errors against exported GML geometry',
                current: File.basename(@gml_path)
              )
            end
            begin
              recheck_overlap_errors!(raw_report, progress: progress, progress_step: recheck_step)
            rescue StandardError
              progress&.fail(recheck_step) if recheck_step && progress&.respond_to?(:fail)
              raise
            end
            if recheck_step
              progress&.detail(
                recheck_step,
                percent: 100,
                phase: 'Apply extension policy',
                message: 'Extension overlap recheck finished',
                current: File.basename(@gml_path)
              )
              progress&.complete(recheck_step)
            end

            if report_step
              progress&.running(report_step)
              progress&.detail(
                report_step,
                percent: 0,
                phase: 'Report generation',
                message: 'Writing final report JSON',
                current: File.basename(@report_json_path)
              )
            end
            File.write(@report_json_path, JSON.pretty_generate(raw_report), encoding: 'UTF-8')
            if report_step
              progress&.detail(
                report_step,
                percent: 50,
                phase: 'Report generation',
                message: 'Generating report view',
                current: File.basename(@report_html_path)
              )
            end
            prepare_html_report(raw_report)
            if report_step
              progress&.detail(
                report_step,
                percent: 100,
                phase: 'Report generation',
                message: 'Report generated',
                current: File.basename(@report_html_path)
              )
              progress&.complete(report_step)
            end

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
                  :root {
                    color-scheme: dark;
                    font-family: Arial, sans-serif;
                    color: #d8d6d0;
                    background: #1c1c1b;
                  }
                  * { box-sizing: border-box; }
                  body { margin: 0; padding: 10px; background: #1c1c1b; }
                  main { max-width: 430px; margin: 0 auto; }
                  .hero { padding: 10px 0 16px; border-bottom: 1px solid #373633; }
                  .hero-top { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; }
                  .top-meta { margin-bottom: 12px; color: #85827b; font-size: 11px; line-height: 1.55; }
                  .eyebrow { margin-bottom: 6px; color: #85827b; font-size: 11px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; }
                  h1 { margin: 0; color: #e8e6e0; font-size: 22px; line-height: 1.15; }
                  .result-message { margin: 8px 0 0; color: #b9b6ae; font-size: 12px; line-height: 1.5; }
                  .result-badge { display: inline-flex; align-items: center; padding: 5px 13px; border-radius: 999px; font-size: 12px; font-weight: 700; white-space: nowrap; }
                  .result-badge.valid { color: #3ebc71; background: #12261a; border: 1px solid #327a4f; }
                  .result-badge.invalid { color: #f97066; background: #351918; border: 1px solid #7a2e2a; }
                  .result-metrics { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; margin-top: 16px; }
                  .result-metric { min-height: 64px; padding: 11px 14px; background: #242422; border-radius: 8px; }
                  .metric-value { display: block; color: #3ebc71; font-size: 20px; font-weight: 700; font-variant-numeric: tabular-nums; overflow-wrap: anywhere; }
                  .metric-value.info { color: #8ab4f8; }
                  .metric-label { display: block; margin-top: 5px; color: #85827b; font-size: 11px; }
                  .section { padding-top: 18px; margin-top: 0; }
                  .section + .section { border-top: 1px solid #373633; margin-top: 18px; }
                  .section-head { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 10px; }
                  h2 { margin: 0; color: #a8a49d; font-size: 12px; font-weight: 700; letter-spacing: .06em; text-transform: uppercase; }
                  .section-count { color: #85827b; font-size: 12px; white-space: nowrap; }
                  .params-grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; }
                  .param { min-width: 0; padding: 10px 12px; background: #242422; border-radius: 8px; }
                  .param-label { color: #85827b; font-family: Consolas, Monaco, monospace; font-size: 10px; letter-spacing: .03em; }
                  .param-value { margin-top: 3px; color: #e8e6e0; font-family: Consolas, Monaco, monospace; font-size: 13px; overflow-wrap: anywhere; }
                  .filter-row { display: flex; gap: 7px; margin-bottom: 10px; overflow-x: auto; padding-bottom: 2px; }
                  .filter-btn { flex: 0 0 auto; padding: 8px 13px; border: 1px solid #4a4945; border-radius: 8px; background: transparent; color: #b9b6ae; font-size: 12px; font-weight: 700; }
                  .filter-btn.active { border-color: #327a4f; background: #12261a; color: #d8d6d0; }
                  .recheck-list { display: grid; gap: 8px; }
                  .recheck-row { background: #242422; border: 1px solid #2f2e2b; border-radius: 8px; }
                  .recheck-row summary { display: grid; grid-template-columns: auto 1fr auto; align-items: center; gap: 8px; padding: 8px 9px; cursor: pointer; list-style: none; }
                  .recheck-row summary::-webkit-details-marker { display: none; }
                  .recheck-row[open] summary { border-bottom: 1px solid #33322f; }
                  .recheck-summary-main { display: flex; align-items: center; gap: 7px; min-width: 0; }
                  .summary-distance { color: #e8e6e0; font-family: Consolas, Monaco, monospace; font-size: 11px; text-align: right; white-space: nowrap; }
                  .recheck-detail { display: grid; gap: 6px; padding: 8px 9px 9px; }
                  .code-badge { display: inline-flex; align-items: center; padding: 3px 7px; border-radius: 5px; background: #1d355d; color: #8ab4f8; font-family: Consolas, Monaco, monospace; font-size: 11px; font-weight: 700; }
                  .code-badge.c704 { background: #443815; color: #e5c567; }
                  .status-badge { color: #3ebc71; font-size: 11px; font-weight: 700; text-transform: uppercase; }
                  .status-badge.kept, .status-badge.inconclusive { color: #f9b84e; }
                  .cell-pair { display: grid; gap: 3px; min-width: 0; color: #d8d6d0; font-family: Consolas, Monaco, monospace; font-size: 11px; line-height: 1.35; }
                  .cell-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
                  .reason { color: #a8a49d; font-size: 11px; line-height: 1.45; overflow-wrap: anywhere; }
                  .empty { color: #85827b; margin: 0; font-size: 12px; }
                  .error-group { border-top: 1px solid #373633; padding-top: 12px; margin-top: 12px; }
                  .error-group:first-child { border-top: 0; padding-top: 0; margin-top: 0; }
                  .error-title { margin: 0 0 8px; color: #d8d6d0; font-size: 12px; font-weight: 700; }
                  .error-items { margin: 0; padding-left: 18px; color: #b9b6ae; font-size: 12px; }
                  .error-items li { margin: 5px 0; overflow-wrap: anywhere; }
                  code { background: #242422; border-radius: 4px; padding: 1px 4px; color: #d8d6d0; }
                  @media (min-width: 700px) {
                    body { padding: 20px; }
                    main { max-width: 520px; }
                  }
                </style>
              </head>
              <body>
                <main>
                  #{report_top_meta_section(raw_report)}
                  #{report_result_hero_section(raw_report)}
                  #{report_summary_section(raw_report)}
                  #{report_overlap_recheck_section(raw_report)}
                  #{report_error_items_section(raw_report)}
                </main>
              </body>
              </html>
            HTML
          end

          def report_result_hero_section(raw_report)
            final_errors = final_error_count(raw_report)
            validity = final_errors.zero?
            suppressed = overlap_recheck_suppressed_count(raw_report)
            kept = overlap_recheck_kept_count(raw_report)
            inconclusive = overlap_recheck_inconclusive_count(raw_report)
            primitive_value = "#{valid_count(raw_report['primitives_overview'])} / #{total_count(raw_report['primitives_overview'])}"
            badge_class = validity ? 'result-badge valid' : 'result-badge invalid'
            heading = validation_status_label(raw_report)
            message = result_hero_message(raw_report, final_errors, suppressed, kept, inconclusive)
            <<~HTML
              <section class="hero">
                <div class="hero-top">
                  <div>
                    <div class="eyebrow">IndoorGML · val3dity #{html_escape(raw_report['val3dity_version'] || 'unknown')}</div>
                    <h1>#{html_escape(heading)}</h1>
                    <p class="result-message">#{html_escape(message)}</p>
                  </div>
                  <span class="#{badge_class}">#{validity ? 'VALID' : 'INVALID'}</span>
                </div>
                <div class="result-metrics">
                  <div class="result-metric">
                    <span class="metric-value">#{final_errors}</span>
                    <span class="metric-label">최종 오류</span>
                  </div>
                  <div class="result-metric">
                    <span class="metric-value">#{suppressed}</span>
                    <span class="metric-label">억제됨</span>
                  </div>
                  <div class="result-metric">
                    <span class="metric-value">#{kept}</span>
                    <span class="metric-label">유지됨</span>
                  </div>
                  <div class="result-metric">
                    <span class="metric-value info">#{html_escape(primitive_value)}</span>
                    <span class="metric-label">유효 Primitive</span>
                  </div>
                </div>
              </section>
            HTML
          end

          def report_top_meta_section(raw_report)
            <<~HTML
              <div class="top-meta">
                <div>#{html_escape(report_checked_at(raw_report['time']))}</div>
                <div>strict: #{html_escape(raw_report[STRICT_VALIDITY_KEY] == true ? 'valid' : 'invalid')} · extension policy: #{html_escape(raw_report[EXTENSION_VALIDITY_KEY] == true ? 'valid' : 'invalid')} · features #{valid_count(raw_report['features_overview'])}/#{total_count(raw_report['features_overview'])}</div>
              </div>
            HTML
          end

          def report_metadata_line(raw_report)
            parts = [
              "val3dity #{raw_report['val3dity_version'] || 'unknown'}",
              raw_report['input_file_type'] || 'IndoorGML',
              report_checked_at(raw_report['time'])
            ].reject { |part| part.to_s.strip.empty? || part == '-' }
            <<~HTML
              <p class="report-meta-line">#{html_escape(parts.join(' · '))}</p>
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
            return '' if rows.empty?

            <<~HTML
              <section class="section">
                <h2>Error에 걸린 항목</h2>
                #{error_item_groups_html(rows)}
              </section>
            HTML
          end

          def report_summary_section(raw_report)
            <<~HTML
              <section class="section">
                <div class="section-head">
                  <h2>파라미터</h2>
                </div>
                <div class="params-grid">
                  #{parameter_html('snap_tol', raw_report.dig('parameters', 'snap_tol') || '-')}
                  #{parameter_html('overlap_tol', raw_report.dig('parameters', 'overlap_tol') || '-')}
                  #{parameter_html('planarity_d2p', raw_report.dig('parameters', 'planarity_d2p_tol') || '-')}
                  #{parameter_html('planarity_n', raw_report.dig('parameters', 'planarity_n_tol') || '-')}
                </div>
              </section>
            HTML
          end

          def parameter_html(label, value)
            <<~HTML
              <div class="param">
                <div class="param-label">#{html_escape(label)}</div>
                <div class="param-value">#{html_escape(value)}</div>
              </div>
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

          def result_hero_message(raw_report, final_errors, suppressed, kept, inconclusive)
            total_rechecks = suppressed + kept + inconclusive
            return 'strict val3dity 오류가 없습니다.' if raw_report[VALIDATION_STATUS_KEY] == 'exact_valid'
            return "strict val3dity 오류는 있었지만 최종 오류가 없습니다. Overlap 재검사 후보 #{suppressed}건이 허용오차 이내로 억제되었습니다." if raw_report[VALIDATION_STATUS_KEY] == 'tolerance_valid'
            return "실제 수정이 필요한 오류가 #{final_errors}건 남아 있습니다." if total_rechecks.zero?

            "실제 수정이 필요한 오류가 #{final_errors}건 남아 있습니다. Overlap 재검사 후보 #{total_rechecks}건 중 #{suppressed}건은 억제, #{kept}건은 유지, #{inconclusive}건은 불명확입니다."
          end

          def validation_status_label(raw_report)
            case raw_report[VALIDATION_STATUS_KEY]
            when 'exact_valid'
              'Exact Valid'
            when 'tolerance_valid'
              'Tolerance Valid'
            else
              'Invalid'
            end
          end

          def final_error_count(raw_report)
            error_item_rows(raw_report).length
          end

          def overlap_recheck_suppressed_count(raw_report)
            overlap_recheck_rows(raw_report).count { |row| row['tolerated'] == true }
          end

          def overlap_recheck_kept_count(raw_report)
            overlap_recheck_rows(raw_report).count { |row| row['status'] == 'kept' || (row['status'].nil? && row['tolerated'] != true) }
          end

          def overlap_recheck_inconclusive_count(raw_report)
            overlap_recheck_rows(raw_report).count { |row| row['status'] == 'inconclusive' }
          end

          def overlap_recheck_rows(raw_report)
            Array(raw_report[OVERLAP_RECHECK_REPORT_KEY])
          end

          def report_checked_at(value)
            text = value.to_s.strip
            return '-' if text.empty?

            text.gsub('대한민국 표준시', 'KST')
          end

          def report_overlap_recheck_section(raw_report)
            rows = Array(raw_report[OVERLAP_RECHECK_REPORT_KEY])
            return '' if rows.empty?

            code_701_count = overlap_recheck_code_count(rows, 701)
            code_704_count = overlap_recheck_code_count(rows, 704)
            <<~HTML
              <section class="section">
                <div class="section-head">
                  <h2>Overlap 재검사</h2>
                  <span class="section-count">#{rows.length}건</span>
                </div>
                <div class="filter-row">
                  <button class="filter-btn active" type="button" data-filter="all">전체 #{rows.length}</button>
                  <button class="filter-btn" type="button" data-filter="701">701 (#{code_701_count})</button>
                  <button class="filter-btn" type="button" data-filter="704">704 (#{code_704_count})</button>
                </div>
                <div class="recheck-list">
                  #{rows.map { |row| overlap_recheck_row_html(row) }.join}
                </div>
              </section>
              #{overlap_recheck_filter_script}
            HTML
          end

          def overlap_recheck_row_html(row)
            cells = Array(row['cells'])
            code = row['code'].to_s
            distance = row['distance_mm'].nil? ? '-' : "#{format('%.6g', row['distance_mm'])} mm"
            status = row['status'] || (row['tolerated'] ? 'suppressed' : 'kept')
            status_class = status == 'suppressed' ? 'suppressed' : status
            status_label = status == 'suppressed' ? '억제' : status
            <<~HTML
              <details class="recheck-row" data-code="#{html_escape(code)}">
                <summary>
                  <span class="code-badge #{code == '704' ? 'c704' : ''}">#{html_escape(code)}</span>
                  <span class="recheck-summary-main">
                    <span class="status-badge #{html_escape(status_class)}">#{html_escape(status_label)}</span>
                    <span class="cell-name" title="#{html_escape(cells.join(' / '))}">#{html_escape(compact_cell_pair(cells))}</span>
                  </span>
                  <span class="summary-distance">#{html_escape(distance)}</span>
                </summary>
                <div class="recheck-detail">
                  <div class="cell-pair">
                    <span class="cell-name" title="#{html_escape(cells[0] || '-')}">#{html_escape(cells[0] || '-')}</span>
                    <span class="cell-name" title="#{html_escape(cells[1] || '-')}">#{html_escape(cells[1] || '-')}</span>
                  </div>
                  <div class="reason">#{html_escape(compact_overlap_reason(row['reason']))}</div>
                </div>
              </details>
            HTML
          end

          def compact_cell_pair(cells)
            first = cells[0].to_s
            second = cells[1].to_s
            return '-' if first.empty? && second.empty?

            "#{first} / #{second}"
          end

          def overlap_recheck_code_count(rows, code)
            rows.count { |row| row['code'].to_s == code.to_s }
          end

          def compact_overlap_reason(reason)
            text = reason.to_s
            return 'GML 기하 스냅샷에서 실제 교차 없음' if text.include?('actual intersection is empty')
            return '공유면 인접 거리 허용 오차 이내' if text.include?('near-coplanar shared-face')

            text
          end

          def overlap_recheck_filter_script
            <<~HTML
              <script>
                document.querySelectorAll('.filter-btn').forEach(function(button) {
                  button.addEventListener('click', function() {
                    var filter = button.getAttribute('data-filter');
                    document.querySelectorAll('.filter-btn').forEach(function(item) {
                      item.classList.remove('active');
                    });
                    button.classList.add('active');
                    document.querySelectorAll('.recheck-row').forEach(function(row) {
                      row.style.display = filter === 'all' || row.getAttribute('data-code') === filter ? '' : 'none';
                    });
                  });
                });
              </script>
            HTML
          end

          def recheck_overlap_errors!(raw_report, progress: nil, progress_step: nil)
            @overlap_recheck_pair_analysis = {}
            @overlap_recheck_701_decisions = {}
            raw_report.delete(OVERLAP_RECHECK_REPORT_KEY)
            results = []
            tracker = {
              total: count_recheckable_overlap_errors(raw_report),
              processed: 0,
              progress: progress,
              progress_step: progress_step
            }
            emit_overlap_recheck_progress(
              tracker,
              message: 'Collecting val3dity 701/704 errors',
              phase: 'Collect 701/704 errors'
            )

            remove_rechecked_errors!(
              Array(raw_report['dataset_errors']),
              results,
              raw_report['input_file'],
              tracker: tracker
            )

            Array(raw_report['features']).each do |feature|
              remove_rechecked_errors!(Array(feature['errors']), results, feature['id'], tracker: tracker)
              Array(feature['primitives']).each do |primitive|
                remove_rechecked_errors!(
                  Array(primitive['errors']),
                  results,
                  feature['id'],
                  primitive['id'],
                  tracker: tracker
                )
              end
            end
            emit_overlap_recheck_progress(
              tracker,
              message: 'Applying extension validation policy',
              phase: 'Apply extension policy'
            )

            raw_report[OVERLAP_RECHECK_REPORT_KEY] = results unless results.empty?
            refresh_rechecked_validity!(raw_report)
          end

          def preserve_strict_validation!(raw_report)
            raw_report[STRICT_VALIDITY_KEY] = raw_report['validity'] == true
            raw_report[STRICT_ERRORS_REPORT_KEY] = error_item_rows(raw_report).map do |row|
              {
                'scope' => row[:scope],
                'item' => row[:item],
                'code' => row[:code],
                'description' => row[:description]
              }
            end
          end

          def count_recheckable_overlap_errors(raw_report)
            count = Array(raw_report['dataset_errors']).count { |error| recheckable_overlap_error?(error) }
            Array(raw_report['features']).each do |feature|
              count += Array(feature['errors']).count { |error| recheckable_overlap_error?(error) }
              Array(feature['primitives']).each do |primitive|
                count += Array(primitive['errors']).count { |error| recheckable_overlap_error?(error) }
              end
            end
            count
          end

          def recheckable_overlap_error?(error)
            [701, 704].include?(error_code_number(error && error['code']))
          end

          def emit_overlap_recheck_progress(tracker, result = nil, message: nil, phase: nil)
            return unless tracker && tracker[:progress] && tracker[:progress_step]

            total = tracker[:total].to_i
            processed = tracker[:processed].to_i
            percent = total.zero? ? 100 : ((processed.to_f / total) * 100).round
            cells = result ? Array(result['cells']).join(' and ') : nil
            status = result && result['status']
            default_message = if total.zero?
                                'No 701/704 errors to recheck'
                              elsif result
                                "Rechecked #{processed} / #{total} overlap errors (#{status || 'checked'})"
                              else
                                "Rechecked #{processed} / #{total} overlap errors"
                              end

            tracker[:progress].detail(
              tracker[:progress_step],
              percent: percent,
              phase: phase || 'Recheck reported cell pairs',
              message: message || default_message,
              current: cells || File.basename(@gml_path)
            )
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] overlap recheck progress failed: #{e.class}: #{e.message}"
          end

          def remove_rechecked_errors!(errors, results, *context, tracker: nil)
            errors.delete_if do |error|
              result = overlap_error_recheck_result(error, *context)
              next false unless result

              results << result
              if tracker
                tracker[:processed] = tracker[:processed].to_i + 1
                emit_overlap_recheck_progress(tracker, result)
              end
              result['tolerated'] == true
            end
          end

          def refresh_rechecked_validity!(raw_report)
            Array(raw_report['features']).each do |feature|
              Array(feature['primitives']).each do |primitive|
                primitive['validity'] = Array(primitive['errors']).empty?
              end

              feature['validity'] = Array(feature['errors']).empty? &&
                                    Array(feature['primitives']).all? { |primitive| primitive['validity'] == true }
            end

            raw_report['validity'] = error_item_rows(raw_report).empty?
            raw_report[EXTENSION_VALIDITY_KEY] = raw_report['validity'] == true
            raw_report[VALIDATION_STATUS_KEY] = if raw_report[STRICT_VALIDITY_KEY] == true
                                                  'exact_valid'
                                                elsif raw_report[EXTENSION_VALIDITY_KEY] == true
                                                  'tolerance_valid'
                                                else
                                                  'invalid'
                                                end
            refresh_overview_counts!(raw_report, 'features_overview', Array(raw_report['features']))
            refresh_overview_counts!(
              raw_report,
              'primitives_overview',
              Array(raw_report['features']).flat_map { |feature| Array(feature['primitives']) }
            )
            raw_report['all_errors'] = error_item_rows(raw_report).map { |row| row[:code] }.uniq
          end

          def refresh_overview_counts!(raw_report, key, items)
            overview = Array(raw_report[key])
            return if overview.empty?

            overview.each do |row|
              type = row['type']
              matching = items.select { |item| type.to_s.empty? || item['type'] == type }
              row['total'] = matching.length
              row['valid'] = matching.count { |item| item['validity'] == true }
            end
          end

          def overlap_error_recheck_result(error, *context)
            code = error_code_number(error['code'])
            return nil unless [701, 704].include?(code)

            text = ([error] + context).map { |value| value.is_a?(Hash) ? value.to_json : value.to_s }.join(' ')
            cell_ids = text.scan(/cell_[A-Za-z0-9_.-]+/).uniq
            return overlap_recheck_result(code, [], false, 'cell pair not found in val3dity error') if cell_ids.length < 2

            recheck_cell_pair(code, cell_ids[0], cell_ids[1])
          end

          def recheck_cell_pair(code, cell_id1, cell_id2)
            analysis = overlap_recheck_pair_analysis(cell_id1, cell_id2)
            if analysis[:status] == :inconclusive
              return overlap_recheck_result(
                code,
                [cell_id1, cell_id2],
                false,
                analysis[:reason],
                status: 'inconclusive'
              )
            end

            decision = code == 701 ? overlap_recheck_701_decision(analysis) : overlap_recheck_704_decision(analysis)
            candidate = decision[:candidate] || {}

            overlap_recheck_result(
              code,
              [cell_id1, cell_id2],
              decision[:tolerated],
              decision[:reason],
              status: decision[:status],
              distance: candidate[:distance],
              overlap_area: candidate[:overlap_area],
              normal_thickness: decision[:normal_thickness],
              actual_overlap_volume: decision[:actual_overlap_volume],
              intersection_component_count: decision[:intersection_component_count]
            )
          end

          def overlap_recheck_pair_analysis(cell_id1, cell_id2)
            key = overlap_recheck_pair_key(cell_id1, cell_id2)
            @overlap_recheck_pair_analysis ||= {}
            @overlap_recheck_pair_analysis[key] ||= begin
              snapshot = export_geometry_snapshot
              cell1 = snapshot[cell_id1]
              cell2 = snapshot[cell_id2]
              if !(cell1 && cell2)
                {
                  status: :inconclusive,
                  cells: [cell_id1, cell_id2],
                  reason: 'cell pair not found in exported GML geometry snapshot'
                }
              elsif cell1[:unsupported] || cell2[:unsupported]
                {
                  status: :inconclusive,
                  cells: [cell_id1, cell_id2],
                  reason: 'GML geometry snapshot is not usable for overlap recheck'
                }
              else
                adjacency_candidates = shared_face_candidates(cell1[:faces], cell2[:faces], mode: :adjacency)
                overlap_candidates = shared_face_candidates(cell1[:faces], cell2[:faces], mode: :overlap)
                intersection = exported_solid_intersection(cell1, cell2)
                {
                  status: :ok,
                  cells: [cell_id1, cell_id2],
                  cell1: cell1,
                  cell2: cell2,
                  adjacency_candidates: adjacency_candidates,
                  overlap_candidates: overlap_candidates,
                  intersection: intersection
                }
              end
            rescue StandardError => e
              {
                status: :inconclusive,
                cells: [cell_id1, cell_id2],
                reason: "GML geometry recheck failed: #{e.class}: #{e.message}"
              }
            end
          end

          def overlap_recheck_pair_key(cell_id1, cell_id2)
            [cell_id1, cell_id2].sort.join('|')
          end

          def overlap_recheck_704_decision(analysis)
            candidate = best_overlap_recheck_candidate(analysis[:adjacency_candidates], 704)
            unless candidate
              return {
                tolerated: false,
                status: 'kept',
                reason: overlap_recheck_missing_pair_reason(704),
                candidate: nil,
                actual_overlap_volume: analysis.dig(:intersection, :volume),
                intersection_component_count: analysis.dig(:intersection, :components)&.length
              }
            end

            overlap_decision = cached_701_decision(analysis)
            if overlap_decision[:status] == 'inconclusive'
              return overlap_decision.merge(
                tolerated: false,
                status: 'inconclusive',
                reason: "gross-overlap check inconclusive; #{overlap_decision[:reason]}",
                candidate: candidate
              )
            end
            if overlap_decision[:gross_overlap]
              return {
                tolerated: false,
                status: 'kept',
                reason: 'shared-face candidate exists, but gross overlap remains for this CellSpace pair',
                candidate: candidate,
                actual_overlap_volume: overlap_decision[:actual_overlap_volume],
                intersection_component_count: overlap_decision[:intersection_component_count]
              }
            end

            {
              tolerated: true,
              status: 'suppressed',
              reason: overlap_recheck_tolerated_reason(704, candidate),
              candidate: candidate,
              actual_overlap_volume: overlap_decision[:actual_overlap_volume],
              intersection_component_count: overlap_decision[:intersection_component_count]
            }
          end

          def cached_701_decision(analysis)
            key = overlap_recheck_pair_key(*analysis[:cells])
            @overlap_recheck_701_decisions ||= {}
            @overlap_recheck_701_decisions[key] ||= overlap_recheck_701_decision(analysis)
          end

          def overlap_recheck_701_decision(analysis)
            intersection = analysis[:intersection]
            if intersection[:status] == :inconclusive
              return {
                tolerated: false,
                status: 'inconclusive',
                reason: intersection[:reason],
                candidate: best_overlap_recheck_candidate(analysis[:overlap_candidates], 701),
                actual_overlap_volume: nil,
                intersection_component_count: nil,
                gross_overlap: nil
              }
            end

            if intersection[:empty]
              return {
                tolerated: true,
                status: 'suppressed',
                reason: 'actual intersection is empty in exported GML geometry snapshot',
                candidate: best_overlap_recheck_candidate(analysis[:adjacency_candidates], 701),
                actual_overlap_volume: 0.0,
                intersection_component_count: 0,
                gross_overlap: false
              }
            end

            candidates = analysis[:overlap_candidates]
            if candidates.empty?
              return {
                tolerated: false,
                status: 'kept',
                reason: 'actual intersection exists without a penetration-direction shared-face candidate',
                candidate: best_overlap_recheck_candidate(analysis[:adjacency_candidates], 701),
                actual_overlap_volume: intersection[:volume],
                intersection_component_count: intersection[:components].length,
                gross_overlap: true
              }
            end

            matches = match_intersection_components_to_slabs(intersection[:components], candidates)
            best_match = matches.compact.max_by { |match| match[:candidate][:overlap_area].to_f }
            all_explained = matches.all?

            {
              tolerated: all_explained,
              status: all_explained ? 'suppressed' : 'kept',
              reason: all_explained ? 'all intersection components are contained in shared-face tolerance slabs' : 'at least one intersection component is not explained by any shared-face tolerance slab',
              candidate: best_match&.dig(:candidate) || best_overlap_recheck_candidate(candidates, 701),
              normal_thickness: best_match&.dig(:normal_thickness),
              actual_overlap_volume: intersection[:volume],
              intersection_component_count: intersection[:components].length,
              gross_overlap: !all_explained
            }
          end

          def shared_face_candidates(faces1, faces2, mode:)
            candidates = []
            faces1.each_with_index do |face1, index1|
              faces2.each_with_index do |face2, index2|
                next if !face1[:interiors].to_a.empty? || !face2[:interiors].to_a.empty?
                next unless Utils::Geometry.normals_opposite?(face1[:normal], face2[:normal])

                distance = face_pair_signed_distance(face1, face2)
                next unless distance.abs <= OVERLAP_RECHECK_TOLERANCE
                next if mode == :overlap && !distance.negative?

                overlap = coplanar_overlap_polygons(face1, face2, OVERLAP_RECHECK_TOLERANCE)
                next unless overlap[:area] > Utils::Geometry.area_tolerance(OVERLAP_RECHECK_TOLERANCE)

                candidates << {
                  face1_index: index1,
                  face2_index: index2,
                  face1: face1,
                  face2: face2,
                  distance: distance,
                  penetration_depth: [-distance, 0.0].max,
                  overlap_area: overlap[:area],
                  overlap_polygons: overlap[:polygons],
                  axis: Utils::Geometry.dominant_axis(face1[:normal]),
                  normal: face1[:normal],
                  plane1: plane_constant(face1[:normal], face1[:points].first),
                  plane2: plane_constant(face1[:normal], face2[:points].first)
                }
              end
            end
            candidates
          end

          def overlap_recheck_tolerated_reason(code, candidate)
            direction = code == 701 ? 'thin shared-face overlap' : 'near-coplanar shared-face adjacency'
            "#{overlap_recheck_face_pair_label(code)} face pair has signed #{direction} distance within #{OVERLAP_RECHECK_TOLERANCE_MM} mm"
          end

          def best_overlap_recheck_candidate(candidates, code)
            Array(candidates).max_by do |candidate|
              signed_score = code == 701 && candidate[:distance].to_f.negative? ? 1 : 0
              [signed_score, candidate[:overlap_area].to_f, -candidate[:distance].to_f.abs]
            end
          end

          def match_intersection_components_to_slabs(components, candidates)
            components.map do |component|
              candidates.filter_map { |candidate| component_slab_match(component, candidate) }
                        .max_by { |match| [match[:candidate][:overlap_area].to_f, -match[:normal_thickness].to_f] }
            end
          end

          def component_slab_match(component, candidate)
            samples = component[:samples]
            return nil if samples.empty?

            normal = candidate[:normal]
            normal_values = samples.map { |point| plane_constant(normal, point) }
            thickness = normal_values.max - normal_values.min
            return nil if thickness > OVERLAP_RECHECK_TOLERANCE + OVERLAP_RECHECK_NUMERIC_EPSILON

            min_plane, max_plane = [candidate[:plane1], candidate[:plane2]].minmax
            return nil unless normal_values.all? do |value|
              value >= min_plane - OVERLAP_RECHECK_NUMERIC_EPSILON &&
                value <= max_plane + OVERLAP_RECHECK_NUMERIC_EPSILON
            end

            return nil unless samples.all? do |point|
              point_inside_candidate_projection?(point, candidate)
            end

            volume_limit = (candidate[:overlap_area].to_f + Utils::Geometry.area_tolerance(OVERLAP_RECHECK_TOLERANCE)) *
                           (candidate[:penetration_depth].to_f + OVERLAP_RECHECK_NUMERIC_EPSILON)
            return nil if component[:volume].to_f > volume_limit

            { candidate: candidate, normal_thickness: thickness }
          end

          def point_inside_candidate_projection?(point, candidate)
            projected = project_point_for_axis(point, candidate[:axis])
            candidate[:overlap_polygons].any? do |polygon|
              Utils::Geometry.send(:point_in_polygon?, projected, polygon, OVERLAP_RECHECK_TOLERANCE)
            end
          end

          def coplanar_overlap_polygons(face1, face2, tolerance)
            return { area: 0.0, polygons: [] } if face1[:triangles].empty? || face2[:triangles].empty?

            axis = Utils::Geometry.dominant_axis(face1[:normal])
            polygons = []
            total_area = 0.0
            face1[:triangles].each do |triangle1|
              polygon1 = Utils::Geometry.project_points_for_axis(triangle1, axis)
              face2[:triangles].each do |triangle2|
                polygon2 = Utils::Geometry.project_points_for_axis(triangle2, axis)
                overlap = Utils::Geometry.send(:clip_polygon, polygon1, polygon2)
                next if overlap.length < 3

                area = Utils::Geometry.send(:polygon_area_2d, overlap).abs
                next if area <= Utils::Geometry.area_tolerance(tolerance)

                polygons << overlap
                total_area += area
              end
            end
            { area: total_area, polygons: polygons }
          end

          def exported_solid_intersection(cell1, cell2)
            model = Sketchup.active_model
            return { status: :inconclusive, reason: 'SketchUp model is not available for intersection recheck' } unless model

            started = false
            group1 = nil
            group2 = nil
            result = nil

            model.start_operation('IndoorGML overlap recheck', true)
            started = true

            group1 = build_temp_solid_group(cell1)
            group2 = build_temp_solid_group(cell2)
            return { status: :inconclusive, reason: 'temporary GML snapshot solid reconstruction failed' } unless group1 && group2
            return { status: :inconclusive, reason: 'SketchUp group intersection is not available' } unless group1.respond_to?(:intersect)

            result = group1.intersect(group2)
            return { status: :ok, empty: true, volume: 0.0, components: [] } if result.nil?
            return { status: :inconclusive, reason: 'SketchUp intersection result is invalid' } unless result.valid?

            faces = result.definition.entities.grep(Sketchup::Face).select(&:valid?)
            volume = result.respond_to?(:volume) ? result.volume.to_f.abs : 0.0
            return { status: :ok, empty: true, volume: volume, components: [] } if faces.empty?

            components = intersection_components(faces)
            {
              status: :ok,
              empty: false,
              volume: volume,
              components: components
            }
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Exported solid intersection failed: #{e.class}: #{e.message}"
            { status: :inconclusive, reason: "actual intersection could not be computed: #{e.class}: #{e.message}" }
          ensure
            model.abort_operation if started
            [result, group1, group2].compact.each do |entity|
              entity.erase! if entity.respond_to?(:valid?) && entity.valid?
            rescue StandardError
              nil
            end
          end

          def build_temp_solid_group(cell)
            group = Sketchup.active_model.entities.add_group
            cell[:faces].each do |face|
              created = group.entities.add_face(face[:points])
              unless created&.valid?
                group.erase! if group.valid?
                return nil
              end
              face[:interiors].to_a.each do |ring|
                inner = group.entities.add_face(ring)
                inner.erase! if inner&.valid?
              end
            end
            group
          end

          def intersection_components(faces)
            face_components(faces).map do |component_faces|
              samples = intersection_component_samples(component_faces)
              {
                faces: component_faces,
                samples: samples,
                volume: component_signed_volume(component_faces).abs
              }
            end
          end

          def face_components(faces)
            remaining = faces.each_with_object({}) { |face, memo| memo[face] = true }
            components = []
            until remaining.empty?
              seed = remaining.keys.first
              stack = [seed]
              component = []
              remaining.delete(seed)
              until stack.empty?
                face = stack.pop
                component << face
                face.edges.flat_map(&:faces).uniq.each do |neighbor|
                  next unless remaining[neighbor]

                  remaining.delete(neighbor)
                  stack << neighbor
                end
              end
              components << component
            end
            components
          end

          def intersection_component_samples(faces)
            points = []
            faces.each do |face|
              face.vertices.each { |vertex| points << vertex.position }
              face.edges.each do |edge|
                vertices = edge.vertices
                next unless vertices.length == 2

                points << Geom::Point3d.new(
                  (vertices[0].position.x + vertices[1].position.x) / 2.0,
                  (vertices[0].position.y + vertices[1].position.y) / 2.0,
                  (vertices[0].position.z + vertices[1].position.z) / 2.0
                )
              end
              face_mesh_triangles_from_face(face).each do |triangle|
                points << Geom::Point3d.new(
                  triangle.map(&:x).sum / 3.0,
                  triangle.map(&:y).sum / 3.0,
                  triangle.map(&:z).sum / 3.0
                )
              end
            end
            unique_points(points)
          end

          def face_mesh_triangles_from_face(face)
            mesh = face.mesh
            points = (1..mesh.count_points).map { |index| mesh.point_at(index) }
            (1..mesh.count_polygons).flat_map do |index|
              polygon = mesh.polygon_at(index).map { |point_index| points[point_index.abs - 1] }.compact
              next [] if polygon.length < 3

              polygon.length == 3 ? [polygon] : triangulate_points(polygon)
            end
          end

          def unique_points(points)
            seen = {}
            points.each_with_object([]) do |point, unique|
              key = [point.x, point.y, point.z].map { |value| (value / OVERLAP_RECHECK_NUMERIC_EPSILON).round }.join(',')
              next if seen[key]

              seen[key] = true
              unique << point
            end
          end

          def component_signed_volume(faces)
            faces.sum do |face|
              points = face.outer_loop.vertices.map(&:position)
              next 0.0 if points.length < 3

              origin = points.first
              (1...(points.length - 1)).sum do |index|
                signed_tetrahedron_volume(origin, points[index], points[index + 1])
              end
            end
          end

          def signed_tetrahedron_volume(point1, point2, point3)
            (
              (point1.x * ((point2.y * point3.z) - (point2.z * point3.y))) -
              (point1.y * ((point2.x * point3.z) - (point2.z * point3.x))) +
              (point1.z * ((point2.x * point3.y) - (point2.y * point3.x)))
            ) / 6.0
          end

          def overlap_recheck_missing_pair_reason(code)
            "#{overlap_recheck_face_pair_label(code)} face pair not found"
          end

          def overlap_recheck_face_pair_label(_code)
            'opposite-normal'
          end

          def face_pair_signed_distance(face1, face2)
            centroid1 = face_centroid(face1)
            centroid2 = face_centroid(face2)
            return Float::INFINITY unless centroid1 && centroid2

            vector = centroid1.vector_to(centroid2)
            Utils::Geometry.dot_product(vector, face1[:normal]).to_f
          end

          def plane_constant(normal, point)
            Utils::Geometry.dot_product(
              Geom::Vector3d.new(point.x.to_f, point.y.to_f, point.z.to_f),
              normal
            ).to_f
          end

          def project_point_for_axis(point, axis)
            case axis
            when :x
              [point.y.to_f, point.z.to_f]
            when :y
              [point.x.to_f, point.z.to_f]
            else
              [point.x.to_f, point.y.to_f]
            end
          end

          def face_centroid(face)
            points = Array(face[:points])
            return nil if points.empty?

            Geom::Point3d.new(
              points.sum(&:x) / points.length.to_f,
              points.sum(&:y) / points.length.to_f,
              points.sum(&:z) / points.length.to_f
            )
          end

          def overlap_recheck_result(code, cell_ids, tolerated, reason, status: nil, distance: nil, overlap_area: nil, normal_thickness: nil, actual_overlap_volume: nil, intersection_component_count: nil)
            {
              'code' => code,
              'cells' => cell_ids,
              'tolerated' => tolerated,
              'status' => status || (tolerated ? 'suppressed' : 'kept'),
              'reason' => reason,
              'tolerance_mm' => OVERLAP_RECHECK_TOLERANCE_MM,
              'distance_mm' => distance.nil? ? nil : distance.to_f * 25.4,
              'normal_thickness_mm' => normal_thickness.nil? ? nil : normal_thickness.to_f * 25.4,
              'overlap_area_mm2' => overlap_area.nil? ? nil : overlap_area.to_f * 25.4 * 25.4,
              'actual_overlap_volume_mm3' => actual_overlap_volume.nil? ? nil : actual_overlap_volume.to_f * 25.4 * 25.4 * 25.4,
              'intersection_component_count' => intersection_component_count
            }
          end

          def error_code_number(code)
            code.to_s[/\d+/].to_i
          end

          def export_geometry_snapshot
            @export_geometry_snapshot ||= begin
              content = File.read(@gml_path, encoding: 'UTF-8')
              document = REXML::Document.new(content)
              snapshot = {}
              each_xml_element(document.root) do |element|
                next unless cell_space_element?(element)

                cell_id = xml_attribute(element, 'id')
                next if cell_id.to_s.empty?

                solid = first_descendant(element, 'Solid')
                next unless solid

                snapshot[cell_id] = parse_gml_solid_snapshot(solid, cell_id)
              end
              snapshot
            end
          end

          def cell_space_element?(element)
            %w[CellSpace GeneralSpace TransitionSpace ConnectionSpace AnchorSpace].include?(xml_local_name(element))
          end

          def parse_gml_solid_snapshot(solid, cell_id)
            faces = []
            unsupported = false
            each_xml_element(solid) do |element|
              next unless xml_local_name(element) == 'Polygon'

              face = parse_gml_polygon_face(element)
              if face[:unsupported]
                unsupported = true
              elsif face[:face]
                faces << face[:face]
              end
            end
            { id: cell_id, faces: faces, unsupported: unsupported || faces.empty? }
          end

          def parse_gml_polygon_face(polygon)
            exterior = first_child(polygon, 'exterior')
            ring = first_descendant(exterior, 'LinearRing')
            return { unsupported: true } unless ring

            points = parse_gml_ring_points(ring, polygon)
            points = remove_closing_duplicate(points)
            return { unsupported: true } if points.length < 3
            interiors = children_by_name(polygon, 'interior').filter_map do |interior|
              interior_ring = first_descendant(interior, 'LinearRing')
              next unless interior_ring

              interior_points = remove_closing_duplicate(parse_gml_ring_points(interior_ring, polygon))
              interior_points.length >= 3 ? interior_points : nil
            end

            normal = polygon_normal(points)
            return { unsupported: true } unless normal

            {
              face: {
                points: points,
                interiors: interiors,
                normal: normal,
                triangles: triangulate_points(points)
              },
              unsupported: false
            }
          end

          def parse_gml_ring_points(ring, unit_context)
            positions = []
            each_xml_element(ring) do |element|
              next unless xml_local_name(element) == 'pos'

              values = element.text.to_s.split.map(&:to_f)
              next unless values.length >= 3

              positions << gml_point_to_inches(values[0], values[1], values[2], unit_context)
            end
            positions
          end

          def gml_point_to_inches(x, y, z, element)
            factor = gml_export_unit_factor(element)
            Geom::Point3d.new(x.to_f / factor, y.to_f / factor, z.to_f / factor)
          end

          def gml_export_unit_factor(element)
            unit = nil
            current = element
            while current
              labels = xml_attribute(current, 'uomLabels')
              unit = labels.to_s.split.first unless labels.to_s.empty?
              break if unit

              srs = xml_attribute(current, 'srsName')
              unit = srs.to_s[/local-([A-Za-z]+)/, 1] unless srs.to_s.empty?
              break if unit

              current = current.respond_to?(:parent) ? current.parent : nil
            end
            case unit
            when 'ft' then 1.0 / 12.0
            when 'mm' then 25.4
            when 'cm' then 2.54
            when 'm' then 0.0254
            else 1.0
            end
          end

          def polygon_normal(points)
            x = 0.0
            y = 0.0
            z = 0.0
            points.each_with_index do |point, index|
              next_point = points[(index + 1) % points.length]
              x += (point.y - next_point.y) * (point.z + next_point.z)
              y += (point.z - next_point.z) * (point.x + next_point.x)
              z += (point.x - next_point.x) * (point.y + next_point.y)
            end
            normal = Geom::Vector3d.new(x, y, z)
            return nil if normal.length <= OVERLAP_RECHECK_NUMERIC_EPSILON

            normal.normalize!
            normal
          end

          def triangulate_points(points)
            (1...(points.length - 1)).map { |index| [points.first, points[index], points[index + 1]] }
          end

          def remove_closing_duplicate(points)
            return points if points.length < 2

            first = points.first
            last = points.last
            first.distance(last) <= OVERLAP_RECHECK_NUMERIC_EPSILON ? points[0...-1] : points
          end

          def each_xml_element(element, &block)
            return unless element

            yield element
            element.elements.each { |child| each_xml_element(child, &block) }
          end

          def first_descendant(element, local_name)
            return nil unless element

            element.elements.each do |child|
              return child if xml_local_name(child) == local_name

              found = first_descendant(child, local_name)
              return found if found
            end
            nil
          end

          def first_child(element, local_name)
            return nil unless element

            element.elements.each do |child|
              return child if xml_local_name(child) == local_name
            end
            nil
          end

          def children_by_name(element, local_name)
            return [] unless element

            children = []
            element.elements.each do |child|
              children << child if xml_local_name(child) == local_name
            end
            children
          end

          def xml_local_name(element)
            element&.name.to_s.split(':').last
          end

          def xml_attribute(element, local_name)
            return nil unless element&.respond_to?(:attributes)

            element.attributes.each_attribute do |attribute|
              name = attribute.name.to_s
              expanded_name = attribute.respond_to?(:expanded_name) ? attribute.expanded_name.to_s : name
              return attribute.value if name == local_name || name.split(':').last == local_name ||
                                        expanded_name == local_name || expanded_name.split(':').last == local_name
            end
            nil
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
