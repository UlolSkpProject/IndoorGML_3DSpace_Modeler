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
          LEGACY_VENDOR_ROOT = File.expand_path('../assets/vendor/val3dity2.1.0', __dir__)
          WINDOWS_ONLY_MESSAGE = 'Val3dity validity check is currently supported only on Windows because the bundled runtime is val3dity-windows-x64-v2.2.0.'
          CREATE_NO_WINDOW       = 0x08000000
          STARTF_USESTDHANDLES   = 0x00000100
          HANDLE_FLAG_INHERIT    = 0x00000001
          WAIT_OBJECT_0          = 0
          WAIT_TIMEOUT           = 258
          STDOUT_READ_BUFFER_SIZE = 4096
          ERROR_BROKEN_PIPE      = 109
          TERMINATE_EXIT_CODE    = 1
          TERMINATE_WAIT_MS      = 200

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

          def initialize(gml_path)
            @gml_path = File.expand_path(gml_path)
            @work_dir = GmlExporter.output_root
            @report_json_path = File.join(@work_dir, 'report.json')
            @report_dir = File.join(@work_dir, 'report')
            @report_html_path = File.join(@report_dir, 'report.html')
          end

          def validate(progress: nil)
            raise 'Val3dityRunner#validate is deprecated. Use #start with a completion callback.'
          end

          def start(progress: nil, &callback)
            raise ArgumentError, 'callback is required' unless callback

            ensure_supported_platform!
            ensure_runtime_files!
            FileUtils.rm_f(@report_json_path)

            progress&.running(:val3dity)

            args = [
              exe_path,
              @gml_path,
              '--verbose',
              # '--overlap_tol',
              # '0.5',
              '-r',
              @report_json_path
            ]

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
              next if completed

              drain_val3dity_progress(session, progress)
            end

            UI.start_timer(0.2, true) do
              next if completed
              next unless session.finished?

              result = nil
              begin
                if session.terminated?
                  completed = true
                  next
                end

                session.join_reader
                drain_val3dity_progress(session, progress)

                progress&.complete(:val3dity)

                result = build_result_after_process(session.exit_code, progress)
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

          def drain_val3dity_progress(session, progress)
            return unless progress

            while (payload = session.pop_progress)
              progress.detail(
                :val3dity,
                percent: payload[:percent],
                phase: payload[:phase],
                message: payload[:message],
                current: payload[:current]
              )
            end
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] val3dity progress drain failed: #{e.class}: #{e.message}"
          end

          def build_result_after_process(exit_code, progress = nil)
            raise "val3dity failed: exit code #{exit_code}" unless exit_code == 0
            raise 'val3dity failed to create report.json.' unless File.exist?(@report_json_path)

            normalize_report_encoding

            progress&.running(:report)
            raw_report = JSON.parse(File.read(@report_json_path, encoding: 'UTF-8'))
            progress&.complete(:report)

            progress&.running(:report_view)
            prepare_html_report(raw_report)
            progress&.complete(:report_view)

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
            if Dir.exist?(report_template_dir)
              FileUtils.cp_r(report_template_dir, @report_dir)
              File.write(File.join(@report_dir, 'report.js'), "var report = #{JSON.pretty_generate(to_report_js(raw_report))}\n", encoding: 'UTF-8')
            else
              FileUtils.mkdir_p(@report_dir)
              File.write(@report_html_path, fallback_report_html(raw_report), encoding: 'UTF-8')
            end
          end

          def fallback_report_html(raw_report)
            escaped_report = JSON.pretty_generate(raw_report)
                                 .gsub('&', '&amp;')
                                 .gsub('<', '&lt;')
                                 .gsub('>', '&gt;')
            <<~HTML
              <!doctype html>
              <html>
              <head>
                <meta charset="utf-8">
                <title>val3dity report</title>
              </head>
              <body>
                <h1>val3dity report</h1>
                <pre>#{escaped_report}</pre>
              </body>
              </html>
            HTML
          end

          def to_report_js(raw_report)
            features = Array(raw_report['features']).map do |feature|
              feature.merge(
                'errors_feature' => empty_to_nil(feature['errors']),
                'primitives' => convert_primitives(feature['primitives'])
              )
            end

            {
              'errors_dataset' => empty_to_nil(raw_report['dataset_errors']),
              'features' => features,
              'input_file' => raw_report['input_file'],
              'invalid_features' => invalid_count(raw_report['features_overview']),
              'invalid_primitives' => invalid_count(raw_report['primitives_overview']),
              'overlap_tol' => raw_report.dig('parameters', 'overlap_tol'),
              'overview_errors' => empty_to_nil(raw_report['all_errors']),
              'overview_features' => overview_types(raw_report['features_overview']),
              'overview_primitives' => overview_types(raw_report['primitives_overview']),
              'planarity_d2p_tol' => raw_report.dig('parameters', 'planarity_d2p_tol'),
              'planarity_n_tol' => raw_report.dig('parameters', 'planarity_n_tol'),
              'snap_tol' => raw_report.dig('parameters', 'snap_tol'),
              'time' => raw_report['time'],
              'total_features' => total_count(raw_report['features_overview']),
              'total_primitives' => total_count(raw_report['primitives_overview']),
              'type' => 'val3dity report',
              'val3dity_version' => raw_report['val3dity_version'],
              'valid_features' => valid_count(raw_report['features_overview']),
              'valid_primitives' => valid_count(raw_report['primitives_overview'])
            }
          end

          def convert_primitives(primitives)
            return nil if primitives.nil?

            primitives.map do |primitive|
              primitive.merge('errors' => empty_to_nil(primitive['errors']))
            end
          end

          def overview_types(overview)
            types = Array(overview).map { |item| item['type'] }
            types.empty? ? nil : types
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

          def empty_to_nil(value)
            value.respond_to?(:empty?) && value.empty? ? nil : value
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

          def report_template_dir
            File.join(VENDOR_ROOT, 'report')
          end

          def windows?
            RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/i
          end
        end

      end
    end
  end
end
