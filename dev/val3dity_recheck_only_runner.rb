# frozen_string_literal: true

require 'json'
require 'time'
require 'tmpdir'
require 'fileutils'

require_relative '../indoor3d/validity/val3dity_runner'
require_relative 'val3dity_recheck_benchmark'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Development-only harness that replays exact 701/704 requests against
        # the currently opened SketchUp model. GML export and val3dity execution
        # are intentionally skipped. Production validation decisions are not
        # modified.
        module Val3dityRecheckOnlyRunner
          REQUEST_SCHEMA_VERSION = 1
          RESULT_SCHEMA_VERSION = 1
          RECHECKABLE_CODES = [701, 704].freeze

          class << self
            attr_reader :last_requests,
                        :last_request_path,
                        :last_result_path,
                        :last_snapshot

            def run_last(**options)
              requests = @last_requests
              source_path = @last_request_path

              if Array(requests).empty?
                report_path = latest_validation_report_path
                raise 'No captured recheck request list or latest validation report was found.' unless report_path

                requests = requests_from_report(report_path)
                source_path = report_path
              end

              run(requests: requests, source_path: source_path, **options)
            end

            def run_from_report(path, **options)
              expanded = File.expand_path(path.to_s)
              run(
                requests: requests_from_report(expanded),
                source_path: expanded,
                **options
              )
            end

            def run_from_requests(path, **options)
              expanded = File.expand_path(path.to_s)
              run(
                requests: requests_from_file(expanded),
                source_path: expanded,
                **options
              )
            end

            def run(
              requests:,
              source_path: nil,
              repetitions: 1,
              unique_requests: false,
              report_name: nil,
              work_dir: nil,
              indoor_model: nil
            )
              normalized = normalize_requests(requests)
              normalized = deduplicate_requests(normalized) if unique_requests
              raise 'Recheck request list is empty.' if normalized.empty?

              model_context = indoor_model || IndoorCore::IndoorModel.current
              unless model_context&.model == Sketchup.active_model
                raise 'IndoorModel.current is not bound to the active SketchUp model.'
              end

              repeat_count = [repetitions.to_i, 1].max
              timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
              base_name = sanitize_name(report_name || "recheck_only_#{timestamp}")
              output_dir = File.expand_path(
                work_dir || File.join(
                  Dir.tmpdir,
                  'ulol',
                  'indoorgml',
                  'recheck-only',
                  timestamp
                )
              )
              FileUtils.mkdir_p(output_dir)

              @last_requests = deep_copy(normalized)
              @last_request_path = write_request_file(
                normalized,
                File.join(output_dir, "#{base_name}_requests.json"),
                source_path: source_path
              )

              runs = []
              replaying do
                repeat_count.times do |index|
                  run_name = repeat_count == 1 ?
                    base_name : "#{base_name}_r#{index + 1}"
                  runs << run_once(
                    requests: normalized,
                    source_path: source_path,
                    report_name: run_name,
                    work_dir: output_dir,
                    indoor_model: model_context,
                    repetition: index + 1,
                    repetition_count: repeat_count
                  )
                end
              end

              snapshot = {
                'schema_version' => RESULT_SCHEMA_VERSION,
                'generated_at' => Time.now.iso8601(6),
                'mode' => 'recheck_only',
                'gml_export_skipped' => true,
                'val3dity_skipped' => true,
                'source_path' => source_path,
                'request_path' => @last_request_path,
                'request_count' => normalized.length,
                'unique_request_count' => unique_request_count(normalized),
                'unique_pair_count' => unique_pair_count(normalized),
                'repetitions' => repeat_count,
                'runs' => runs
              }
              result_path = File.join(
                output_dir,
                "#{base_name}_recheck_only.json"
              )
              File.write(
                result_path,
                JSON.pretty_generate(snapshot),
                encoding: 'UTF-8'
              )
              @last_snapshot = snapshot
              @last_result_path = result_path

              log(
                "finished: requests=#{normalized.length}, " \
                "repetitions=#{repeat_count}, result=#{result_path}"
              )
              snapshot
            end

            def requests_from_file(path)
              payload = JSON.parse(File.read(path, encoding: 'UTF-8'))
              rows = payload.is_a?(Hash) ? payload['requests'] : payload
              normalized = normalize_requests(rows)
              raise "No valid 701/704 requests found in #{path}" if normalized.empty?

              @last_requests = deep_copy(normalized)
              @last_request_path = File.expand_path(path)
              normalized
            end

            def requests_from_report(path)
              raw_report = JSON.parse(File.read(path, encoding: 'UTF-8'))
              rows = requests_from_recheck_results(raw_report)
              rows = requests_from_raw_errors(raw_report) if rows.empty?
              normalized = normalize_requests(rows)
              if normalized.empty?
                raise "No valid 701/704 requests found in validation report: #{path}"
              end

              @last_requests = deep_copy(normalized)
              @last_request_path = File.expand_path(path)
              normalized
            end

            def latest_validation_report_path
              candidates = []
              benchmark = benchmark_probe
              if benchmark&.last_snapshot
                metadata = benchmark.last_snapshot['metadata'] || {}
                work_dir = metadata['work_dir']
                report_name = metadata['report_name'] || 'report'
                candidates << File.join(
                  work_dir,
                  "#{report_name}.json"
                ) if work_dir
              end
              candidates.find { |path| File.file?(path) }
            rescue StandardError => e
              log("latest report lookup failed: #{e.class}: #{e.message}")
              nil
            end

            def capture_request(code, cell_id1, cell_id2)
              return if replaying?
              return unless @capture_session

              request = normalize_request(
                'code' => code,
                'cells' => [cell_id1, cell_id2]
              )
              @capture_session[:requests] << request if request
            end

            def begin_capture(runner)
              return if replaying?

              @capture_session = {
                started_at: Time.now,
                requests: [],
                runner: runner
              }
            end

            def finish_capture(runner)
              return if replaying?

              session = @capture_session
              @capture_session = nil
              return unless session

              requests = normalize_requests(session[:requests])
              @last_requests = deep_copy(requests)
              work_dir = runner.instance_variable_get(:@work_dir)
              report_name =
                runner.instance_variable_get(:@report_name) || 'report'
              FileUtils.mkdir_p(work_dir)
              @last_request_path = write_request_file(
                requests,
                File.join(
                  work_dir,
                  "#{report_name}_recheck_requests.json"
                ),
                source_path: runner.instance_variable_get(:@report_json_path),
                started_at: session[:started_at]
              )
              log("captured requests=#{requests.length}: #{@last_request_path}")
            rescue StandardError => e
              log("request capture write failed: #{e.class}: #{e.message}")
            end

            def log(message)
              text = "[IndoorGML][RecheckOnly] #{message}"
              if defined?(IndoorCore::Logger) &&
                 IndoorCore::Logger.respond_to?(:puts)
                IndoorCore::Logger.puts(text)
              else
                puts(text)
              end
            rescue StandardError
              nil
            end

            private

            def run_once(
              requests:,
              source_path:,
              report_name:,
              work_dir:,
              indoor_model:,
              repetition:,
              repetition_count:
            )
              runner = Val3dityRunner.new(
                File.join(work_dir, '__recheck_only_input__.gml'),
                report_name: report_name,
                work_dir: work_dir,
                indoor_model: indoor_model
              )

              recorder = build_benchmark_recorder(
                source_path: source_path,
                report_name: report_name,
                work_dir: work_dir,
                request_count: requests.length,
                repetition: repetition,
                repetition_count: repetition_count
              )
              benchmark_probe.current = recorder if recorder

              started = monotonic_now
              rows = requests.each_with_index.map do |request, index|
                request_started = monotonic_now
                result = runner.send(
                  :recheck_cell_pair,
                  request['code'],
                  request['cells'][0],
                  request['cells'][1]
                )
                {
                  'index' => index,
                  'code' => request['code'],
                  'cells' => request['cells'],
                  'elapsed_ms' => elapsed_ms(request_started),
                  'result' => stringify_keys(result)
                }
              rescue StandardError => e
                {
                  'index' => index,
                  'code' => request['code'],
                  'cells' => request['cells'],
                  'elapsed_ms' => elapsed_ms(request_started),
                  'error' => "#{e.class}: #{e.message}"
                }
              end

              elapsed = elapsed_ms(started)
              benchmark_path = if recorder
                                 benchmark_probe.write_report(runner, recorder)
                               end

              {
                'repetition' => repetition,
                'elapsed_ms' => elapsed,
                'request_count' => requests.length,
                'error_count' => rows.count { |row| row.key?('error') },
                'status_counts' => status_counts(rows),
                'benchmark_report_path' => benchmark_path,
                'results' => rows
              }
            ensure
              benchmark_probe.current = nil if benchmark_probe
            end

            def build_benchmark_recorder(**metadata)
              probe = benchmark_probe
              return nil unless probe && probe.const_defined?(:Recorder, false)

              probe::Recorder.new(metadata.merge('mode' => 'recheck_only'))
            end

            def benchmark_probe
              return nil unless defined?(Val3dityRecheckBenchmarkProbe)

              Val3dityRecheckBenchmarkProbe
            end

            def requests_from_recheck_results(raw_report)
              key = if defined?(
                Val3dityReportSchema::OVERLAP_RECHECK_REPORT_KEY
              )
                      Val3dityReportSchema::OVERLAP_RECHECK_REPORT_KEY
                    end
              rows = key ? Array(raw_report[key]) : []
              rows.filter_map do |row|
                next unless row.is_a?(Hash)

                normalize_request(row)
              end
            end

            def requests_from_raw_errors(raw_report)
              requests = []
              append_error_requests(
                requests,
                Array(raw_report['dataset_errors']),
                raw_report['input_file']
              )
              Array(raw_report['features']).each do |feature|
                append_error_requests(
                  requests,
                  Array(feature['errors']),
                  feature['id']
                )
                Array(feature['primitives']).each do |primitive|
                  append_error_requests(
                    requests,
                    Array(primitive['errors']),
                    feature['id'],
                    primitive['id']
                  )
                end
              end
              requests
            end

            def append_error_requests(target, errors, *context)
              errors.each do |error|
                next unless error.is_a?(Hash)

                code = error_code_number(error['code'])
                next unless RECHECKABLE_CODES.include?(code)

                text = ([error] + context).map do |value|
                  value.is_a?(Hash) ? value.to_json : value.to_s
                end.join(' ')
                cells = text.scan(/cell_[A-Za-z0-9_.-]+/).uniq
                next if cells.length < 2

                target << {
                  'code' => code,
                  'cells' => cells.first(2)
                }
              end
            end

            def error_code_number(value)
              if defined?(Val3dityReportSchema)
                Val3dityReportSchema.error_code_number(value)
              else
                value.to_s[/\d+/].to_i
              end
            rescue StandardError
              value.to_s[/\d+/].to_i
            end

            def normalize_requests(requests)
              Array(requests).filter_map { |row| normalize_request(row) }
            end

            def normalize_request(row)
              return nil unless row.is_a?(Hash)

              code = error_code_number(row['code'] || row[:code])
              return nil unless RECHECKABLE_CODES.include?(code)

              cells = Array(row['cells'] || row[:cells])
                .map(&:to_s)
                .reject(&:empty?)
              return nil if cells.length < 2

              {
                'code' => code,
                'cells' => cells.first(2)
              }
            end

            def deduplicate_requests(requests)
              seen = {}
              requests.each_with_object([]) do |request, result|
                key = [request['code'], request['cells'].sort]
                next if seen[key]

                seen[key] = true
                result << request
              end
            end

            def unique_request_count(requests)
              requests.map do |row|
                [row['code'], row['cells'].sort]
              end.uniq.length
            end

            def unique_pair_count(requests)
              requests.map { |row| row['cells'].sort }.uniq.length
            end

            def write_request_file(
              requests,
              path,
              source_path:,
              started_at: nil
            )
              payload = {
                'schema_version' => REQUEST_SCHEMA_VERSION,
                'generated_at' => Time.now.iso8601(6),
                'captured_at' => started_at&.iso8601(6),
                'source_path' => source_path,
                'request_count' => requests.length,
                'unique_request_count' => unique_request_count(requests),
                'unique_pair_count' => unique_pair_count(requests),
                'requests' => requests
              }.compact
              File.write(
                path,
                JSON.pretty_generate(payload),
                encoding: 'UTF-8'
              )
              path
            end

            def status_counts(rows)
              rows.each_with_object(Hash.new(0)) do |row, counts|
                status = row.dig('result', 'status') ||
                         (row['error'] ? 'error' : 'unknown')
                counts[status.to_s] += 1
              end.sort.to_h
            end

            def stringify_keys(value)
              case value
              when Hash
                value.each_with_object({}) do |(key, item), result|
                  result[key.to_s] = stringify_keys(item)
                end
              when Array
                value.map { |item| stringify_keys(item) }
              when Symbol
                value.to_s
              else
                value
              end
            end

            def deep_copy(value)
              JSON.parse(JSON.generate(value))
            end

            def sanitize_name(value)
              text = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              text.empty? ? 'recheck_only' : text
            end

            def replaying
              @replay_depth = @replay_depth.to_i + 1
              yield
            ensure
              @replay_depth = [@replay_depth.to_i - 1, 0].max
            end

            def replaying?
              @replay_depth.to_i.positive?
            end

            def elapsed_ms(started)
              ((monotonic_now - started) * 1000.0).round(3)
            end

            def monotonic_now
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end

          module RunnerCapturePatch
            private

            def recheck_overlap_errors!(*args, **kwargs)
              Val3dityRecheckOnlyRunner.begin_capture(self)
              super
            ensure
              Val3dityRecheckOnlyRunner.finish_capture(self)
            end

            def recheck_cell_pair(code, cell_id1, cell_id2)
              Val3dityRecheckOnlyRunner.capture_request(
                code,
                cell_id1,
                cell_id2
              )
              super
            end
          end
        end
      end
    end
  end
end

runner =
  ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityRunner
harness =
  ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityRecheckOnlyRunner

runner.prepend(harness::RunnerCapturePatch) unless
  runner.ancestors.include?(harness::RunnerCapturePatch)

harness.log(
  'loaded: captures exact recheck requests and supports canonical replay'
)
