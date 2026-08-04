# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_fallback_fix'
require_relative 'val3dity_recheck_v3_mesh_proxy_benchmark'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Runs the existing direct-mesh proxy benchmark inside one outer
        # rollback operation. Inner per-pair operation requests are therefore
        # nested and do not create/abort separate SketchUp operations.
        # Geometry/recheck decisions are unchanged; this isolates operation
        # churn as a possible source of cumulative latency.
        module Val3dityRecheckV3MeshProxyOuterOperationBenchmark
          MODE = 'recheck_only_v3_mesh_proxy_single_outer_operation'

          class << self
            attr_reader :last_result_path, :last_progress_log_path, :last_snapshot

            def run_snapshot(name_or_path = nil, indoor_model: nil, **options)
              indoor_model ||= IndoorCore::IndoorModel.current
              raise 'IndoorModel.current is not bound to the active model.' unless
                indoor_model&.model == Sketchup.active_model

              snapshot = nil
              indoor_model.with_indoor_model_operation(
                'IndoorGML v3 mesh proxy outer-operation benchmark',
                rollback: true
              ) do
                snapshot = Val3dityRecheckV3MeshProxyBenchmark.run_snapshot(
                  name_or_path,
                  indoor_model: indoor_model,
                  **options
                )
              end

              snapshot['mode'] = MODE
              snapshot['single_outer_operation'] = true
              snapshot['inner_pair_operations_nested'] = true
              snapshot['production_code_modified'] = false
              snapshot['adoptable_for_production'] = false

              result_path = Val3dityRecheckV3MeshProxyBenchmark.last_result_path
              if result_path && File.file?(result_path)
                File.write(
                  result_path,
                  JSON.pretty_generate(snapshot),
                  encoding: 'UTF-8'
                )
              end

              @last_result_path = result_path
              @last_progress_log_path =
                Val3dityRecheckV3MeshProxyBenchmark.last_progress_log_path
              @last_snapshot = snapshot
              snapshot
            end
          end
        end
      end
    end
  end
end
