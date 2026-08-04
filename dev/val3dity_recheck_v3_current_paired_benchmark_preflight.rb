# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_current_paired_benchmark'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3CurrentPairedBenchmarkPreflight
          private

          def validate_snapshot_against_current_model!(
            directory,
            request_path,
            requests,
            indoor_model
          )
            checker = Val3dityOverlapGeometryRechecker.new(
              indoor_model: indoor_model,
              model: indoor_model.model,
              tolerance: Utils::Geometry::VALIDATION_TOLERANCE,
              logger: nil
            )

            requested_ids = requests.flat_map do |request|
              Array(request['cells']).map(&:to_s)
            end.reject(&:empty?).uniq.sort

            rows = requested_ids.map do |cell_id|
              geometry = checker.send(:model_cell_geometry, cell_id)
              {
                'cell_id' => cell_id,
                'status' => geometry[:status].to_s,
                'reason' => geometry[:reason]&.to_s
              }
            rescue StandardError => e
              {
                'cell_id' => cell_id,
                'status' => 'error',
                'reason' => "#{e.class}: #{e.message}"
              }
            end

            failures = rows.reject { |row| row['status'] == 'ok' }
            metadata_path = File.join(directory, 'snapshot.json')
            metadata = if File.file?(metadata_path)
                         JSON.parse(File.read(metadata_path, encoding: 'UTF-8'))
                       else
                         {}
                       end
            current_model_path = indoor_model.model.path.to_s
            current_model_title = indoor_model.model.title.to_s

            preflight = {
              'request_path' => request_path,
              'request_count' => requests.length,
              'requested_unique_cell_count' => requested_ids.length,
              'resolved_unique_cell_count' => rows.length - failures.length,
              'unresolved_unique_cell_count' => failures.length,
              'resolution_status_counts' =>
                rows.map { |row| row['status'] }.tally.sort.to_h,
              'failure_reason_prefix_counts' =>
                failures.map do |row|
                  row['reason'].to_s.split(':', 2).first
                end.tally.sort.to_h,
              'failure_samples' => failures.first(20),
              'snapshot_model_path' => metadata['model_path'],
              'snapshot_model_title' => metadata['model_title'],
              'current_model_path' => current_model_path.empty? ? nil : current_model_path,
              'current_model_title' => current_model_title.empty? ? nil : current_model_title,
              'valid' => failures.empty?
            }

            return preflight if failures.empty?

            details = failures.first(10).map do |row|
              "  #{row['cell_id']}: #{row['reason']}"
            end.join("\n")
            raise RuntimeError,
                  "Recheck snapshot does not match the current IndoorModel.\n" \
                  "resolved=#{preflight['resolved_unique_cell_count']} / " \
                  "#{preflight['requested_unique_cell_count']} unique CellSpaces\n" \
                  "snapshot_model=#{preflight['snapshot_model_path'] || '(unknown)'}\n" \
                  "current_model=#{preflight['current_model_path'] || '(unsaved/unknown)'}\n" \
                  "Do not remap report CellSpace IDs heuristically. Capture a fresh " \
                  "snapshot and replay it in the same SketchUp model session.\n" \
                  "Examples:\n#{details}"
          end

          public

          def run_snapshot(
            name_or_path = nil,
            report_name: nil,
            indoor_model: nil
          )
            store = Val3dityRecheckSnapshotStore
            directory = store.resolve_directory(name_or_path)
            request_path = store.request_path(name_or_path)
            unless directory && request_path && File.file?(request_path)
              raise 'Persistent recheck snapshot was not found.'
            end

            model_context = indoor_model || IndoorCore::IndoorModel.current
            unless model_context&.model == Sketchup.active_model
              raise 'IndoorModel.current is not bound to the active SketchUp model.'
            end

            requests = Val3dityRecheckOnlyRunner.requests_from_file(request_path)
            preflight = validate_snapshot_against_current_model!(
              directory,
              request_path,
              requests,
              model_context
            )

            result = super(
              name_or_path,
              report_name: report_name,
              indoor_model: model_context
            )
            result['input_preflight'] = preflight
            result['benchmark_input_valid'] = true
            File.write(
              last_result_path,
              JSON.pretty_generate(result),
              encoding: 'UTF-8'
            )
            @last_snapshot = result
            result
          end
        end

        benchmark = Val3dityRecheckV3CurrentPairedBenchmark
        patch = Val3dityRecheckV3CurrentPairedBenchmarkPreflight
        benchmark.singleton_class.prepend(patch) unless
          benchmark.singleton_class.ancestors.include?(patch)
      end
    end
  end
end
