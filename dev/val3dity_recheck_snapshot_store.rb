# frozen_string_literal: true

require 'json'
require 'time'
require 'fileutils'

require_relative 'val3dity_recheck_only_runner'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Development-only persistent storage for recheck test inputs.
        #
        # Normal validation work directories live under %TEMP% and may be removed
        # automatically. This store copies the raw val3dity report plus the exact
        # captured [code, cell1, cell2] request list into dev/recheck_snapshots.
        module Val3dityRecheckSnapshotStore
          SCHEMA_VERSION = 1
          SNAPSHOT_ROOT = File.expand_path('recheck_snapshots', __dir__).freeze
          REPORT_FILE = 'report.json'
          REQUEST_FILE = 'recheck_requests.json'
          METADATA_FILE = 'snapshot.json'

          class << self
            def root
              SNAPSHOT_ROOT
            end

            def snapshot_report(path, name: nil, requests: nil, captured_at: nil)
              source = File.expand_path(path.to_s)
              raise "Validation report was not found: #{source}" unless File.file?(source)

              harness = recheck_harness
              rows = requests || harness.requests_from_report(source)
              normalized = normalize_requests(rows)
              raise 'Recheck request list is empty.' if normalized.empty?

              timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
              snapshot_name = sanitize_name(name || default_snapshot_name(timestamp))
              directory = unique_directory(snapshot_name)
              FileUtils.mkdir_p(directory)

              report_path = File.join(directory, REPORT_FILE)
              request_path = File.join(directory, REQUEST_FILE)
              metadata_path = File.join(directory, METADATA_FILE)

              FileUtils.cp(source, report_path)
              write_requests(
                request_path,
                normalized,
                source_path: report_path,
                captured_at: captured_at
              )

              metadata = {
                'schema_version' => SCHEMA_VERSION,
                'created_at' => Time.now.iso8601(6),
                'name' => File.basename(directory),
                'original_report_path' => source,
                'report_path' => report_path,
                'request_path' => request_path,
                'report_size_bytes' => File.size(report_path),
                'request_count' => normalized.length,
                'unique_request_count' => unique_request_count(normalized),
                'unique_pair_count' => unique_pair_count(normalized),
                'model_path' => active_model_path,
                'model_title' => active_model_title
              }.compact
              File.write(metadata_path, JSON.pretty_generate(metadata), encoding: 'UTF-8')

              @last_directory = directory
              @last_report_path = report_path
              @last_request_path = request_path
              log("persistent snapshot saved: #{directory}")
              metadata
            end

            def snapshot_latest(name: nil)
              path = recheck_harness.latest_validation_report_path
              raise 'Latest temporary validation report was not found.' unless path

              snapshot_report(path, name: name)
            end

            def capture_from_runner(runner, requests, captured_at: nil)
              report_path = runner.instance_variable_get(:@report_json_path)
              unless report_path && File.file?(report_path)
                log("persistent snapshot skipped; report missing: #{report_path}")
                return nil
              end

              normalized = normalize_requests(requests)
              if normalized.empty?
                log('persistent snapshot skipped; request list is empty')
                return nil
              end

              report_name = runner.instance_variable_get(:@report_name) || 'report'
              timestamp = (captured_at || Time.now).strftime('%Y%m%d-%H%M%S')
              name = "#{default_snapshot_name(timestamp)}_#{sanitize_name(report_name)}"
              snapshot_report(
                report_path,
                name: name,
                requests: normalized,
                captured_at: captured_at
              )
            rescue StandardError => e
              log("persistent snapshot capture failed: #{e.class}: #{e.message}")
              nil
            end

            def list
              return [] unless Dir.exist?(SNAPSHOT_ROOT)

              Dir.children(SNAPSHOT_ROOT).filter_map do |entry|
                directory = File.join(SNAPSHOT_ROOT, entry)
                next unless File.directory?(directory)
                next unless File.file?(File.join(directory, REQUEST_FILE))

                directory
              end.sort_by { |directory| File.mtime(directory) }.reverse
            rescue StandardError => e
              log("snapshot listing failed: #{e.class}: #{e.message}")
              []
            end

            def latest_directory
              return @last_directory if @last_directory && File.directory?(@last_directory)

              list.first
            end

            def resolve_directory(name_or_path = nil)
              return latest_directory if name_or_path.nil?

              expanded = File.expand_path(name_or_path.to_s)
              return expanded if snapshot_directory?(expanded)

              named = File.join(SNAPSHOT_ROOT, sanitize_name(name_or_path))
              snapshot_directory?(named) ? named : nil
            end

            def request_path(name_or_path = nil)
              directory = resolve_directory(name_or_path)
              directory && File.join(directory, REQUEST_FILE)
            end

            def report_path(name_or_path = nil)
              directory = resolve_directory(name_or_path)
              directory && File.join(directory, REPORT_FILE)
            end

            def run(name_or_path = nil, **options)
              path = request_path(name_or_path)
              raise 'Persistent recheck snapshot was not found.' unless path && File.file?(path)

              recheck_harness.run_from_requests(path, **options)
            end

            def last_directory
              @last_directory
            end

            def last_report_path
              @last_report_path
            end

            def last_request_path
              @last_request_path
            end

            def log(message)
              recheck_harness.log("[Snapshot] #{message}")
            rescue StandardError
              puts("[IndoorGML][RecheckOnly][Snapshot] #{message}")
            end

            private

            def recheck_harness
              Val3dityRecheckOnlyRunner
            end

            def normalize_requests(rows)
              Array(rows).filter_map do |row|
                next unless row.is_a?(Hash)

                code = (row['code'] || row[:code]).to_s[/\d+/].to_i
                next unless [701, 704].include?(code)

                cells = Array(row['cells'] || row[:cells]).map(&:to_s).reject(&:empty?)
                next if cells.length < 2

                {
                  'code' => code,
                  'cells' => cells.first(2)
                }
              end
            end

            def write_requests(path, requests, source_path:, captured_at: nil)
              payload = {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'captured_at' => captured_at&.iso8601(6),
                'source_path' => source_path,
                'request_count' => requests.length,
                'unique_request_count' => unique_request_count(requests),
                'unique_pair_count' => unique_pair_count(requests),
                'requests' => requests
              }.compact
              File.write(path, JSON.pretty_generate(payload), encoding: 'UTF-8')
              path
            end

            def unique_request_count(requests)
              requests.map { |row| [row['code'], row['cells'].sort] }.uniq.length
            end

            def unique_pair_count(requests)
              requests.map { |row| row['cells'].sort }.uniq.length
            end

            def unique_directory(name)
              FileUtils.mkdir_p(SNAPSHOT_ROOT)
              base = File.join(SNAPSHOT_ROOT, name)
              return base unless File.exist?(base)

              suffix = 2
              loop do
                candidate = "#{base}_#{suffix}"
                return candidate unless File.exist?(candidate)

                suffix += 1
              end
            end

            def snapshot_directory?(path)
              File.directory?(path) && File.file?(File.join(path, REQUEST_FILE))
            end

            def default_snapshot_name(timestamp)
              model_name = File.basename(active_model_path.to_s, '.*')
              model_name = 'unsaved_model' if model_name.empty?
              "#{sanitize_name(model_name)}_#{timestamp}"
            end

            def sanitize_name(value)
              text = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              text.empty? ? 'recheck_snapshot' : text
            end

            def active_model_path
              return nil unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)

              path = Sketchup.active_model&.path.to_s
              path.empty? ? nil : path
            rescue StandardError
              nil
            end

            def active_model_title
              return nil unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)

              title = Sketchup.active_model&.title.to_s
              title.empty? ? nil : title
            rescue StandardError
              nil
            end
          end

          # Wraps the existing capture hook. The exact request list has already
          # been collected by Val3dityRecheckOnlyRunner when +super+ returns.
          module HarnessPatch
            def finish_capture(runner)
              captured_at = instance_variable_get(:@capture_session)&.dig(:started_at)
              super
            ensure
              Val3dityRecheckSnapshotStore.capture_from_runner(
                runner,
                Array(last_requests),
                captured_at: captured_at
              )
            end

            def run_last(**options)
              if Array(last_requests).empty?
                path = Val3dityRecheckSnapshotStore.request_path
                return run_from_requests(path, **options) if path && File.file?(path)
              end

              super
            end
          end
        end
      end
    end
  end
end

harness = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityRecheckOnlyRunner
store = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityRecheckSnapshotStore
harness.singleton_class.prepend(store::HarnessPatch) unless harness.singleton_class.ancestors.include?(store::HarnessPatch)

harness.define_singleton_method(:snapshot_root) { store.root }
harness.define_singleton_method(:snapshot_report) { |path, **options| store.snapshot_report(path, **options) }
harness.define_singleton_method(:snapshot_latest) { |**options| store.snapshot_latest(**options) }
harness.define_singleton_method(:list_snapshots) { store.list }
harness.define_singleton_method(:run_snapshot) { |name_or_path = nil, **options| store.run(name_or_path, **options) }
harness.define_singleton_method(:last_snapshot_dir) { store.last_directory }
harness.define_singleton_method(:last_snapshot_report_path) { store.last_report_path }
harness.define_singleton_method(:last_snapshot_request_path) { store.last_request_path }

store.log("loaded: root=#{store.root}")
