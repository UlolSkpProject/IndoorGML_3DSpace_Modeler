# frozen_string_literal: true

require 'json'
require 'time'

require_relative 'val3dity_recheck_v3_current_paired_benchmark_preflight'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3CurrentPairedBenchmarkVolumeGate
          REPRODUCED_REASON = 'REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION'

          private

          def value(hash, key)
            if key.to_s == 'actual_overlap_volume'
              mm3 = if hash.key?('actual_overlap_volume_mm3')
                      hash['actual_overlap_volume_mm3']
                    elsif hash.key?(:actual_overlap_volume_mm3)
                      hash[:actual_overlap_volume_mm3]
                    end
              return mm3 unless mm3.nil?
            end

            super
          end

          def compare(full, v3)
            result = super
            by_index = v3.to_h { |row| [row['index'], row] }
            missing_volumes = []
            component_failures = []

            full.each do |base|
              next unless reproduced_kept?(base)

              live = by_index[base['index']]
              next unless live && live['status'] == 'kept'

              unless positive_finite?(base['volume']) && positive_finite?(live['volume'])
                missing_volumes << [base, live]
              end

              base_components = base['component_count'].to_i
              live_components = live['component_count'].to_i
              unless base_components.positive? &&
                     live_components.positive? &&
                     base_components == live_components
                component_failures << [base, live]
              end
            end

            result.merge(
              'reproduced_kept_missing_volume_count' => missing_volumes.length,
              'reproduced_kept_component_failure_count' => component_failures.length,
              'reproduced_kept_missing_volumes' => missing_volumes,
              'reproduced_kept_component_failures' => component_failures
            )
          end

          def reproduced_kept?(row)
            row['status'] == 'kept' && row['reason'] == REPRODUCED_REASON
          end

          def positive_finite?(value)
            number = Float(value)
            number.finite? && number.positive?
          rescue ArgumentError, TypeError
            false
          end

          def acceptance_pass?(result)
            comparison = result['comparison'] || {}
            result['completed'] == true &&
              result['benchmark_input_valid'] == true &&
              comparison['pair_count_match'] == true &&
              %w[
                suppressed_regression_count
                kept_regression_count
                kept_volume_mismatch_count
                reproduced_kept_missing_volume_count
                reproduced_kept_component_failure_count
              ].all? { |key| comparison[key].to_i.zero? }
          end

          def postcheck_runner(model, kind, output_dir)
            runner = Val3dityRunner.new(
              File.join(output_dir, "__kept_volume_#{kind}.gml"),
              report_name: "kept_volume_#{kind}",
              work_dir: output_dir,
              indoor_model: model
            )
            klass = kind == :v3 ?
              Val3dityRecheckV3MeshProxy::Rechecker :
              Val3dityOverlapGeometryRechecker
            checker = klass.new(
              indoor_model: model,
              model: model.model,
              tolerance: Utils::Geometry::VALIDATION_TOLERANCE,
              logger: nil
            )
            runner.instance_variable_set(:@overlap_geometry_rechecker, checker)
            [runner, checker]
          end

          def recheck_postcheck_pair(runner, checker, request, kind)
            started = clock
            result = runner.send(
              :recheck_cell_pair,
              request['code'],
              request['cells'][0],
              request['cells'][1]
            )
            row = {
              'index' => request['index'],
              'code' => request['code'],
              'cells' => request['cells'],
              'status' => value(result, 'status').to_s,
              'tolerated' => value(result, 'tolerated'),
              'reason' => value(result, 'reason').to_s,
              'volume_mm3' => value(result, 'actual_overlap_volume'),
              'component_count' => value(result, 'intersection_component_count'),
              'elapsed_ms' => elapsed(started)
            }
            row['proxy'] = checker.proxy_record(*request['cells']) if kind == :v3
            row
          end

          def postcheck_row_pass?(full_row, v3_row)
            full_row['status'] == 'kept' &&
              v3_row['status'] == 'kept' &&
              full_row['reason'] == REPRODUCED_REASON &&
              v3_row['reason'] == REPRODUCED_REASON &&
              positive_finite?(full_row['volume_mm3']) &&
              positive_finite?(v3_row['volume_mm3']) &&
              full_row['component_count'].to_i.positive? &&
              full_row['component_count'].to_i == v3_row['component_count'].to_i &&
              same_volume?(full_row['volume_mm3'], v3_row['volume_mm3'])
          end

          public

          def run_snapshot(name_or_path = nil, report_name: nil, indoor_model: nil)
            result = super
            result['comparison']['volume_unit'] = 'mm3'
            result['volume_gate_pass'] = %w[
              kept_volume_mismatch_count
              reproduced_kept_missing_volume_count
              reproduced_kept_component_failure_count
            ].all? { |key| result['comparison'][key].to_i.zero? }
            result['final_pass'] = acceptance_pass?(result)
            File.write(last_result_path, JSON.pretty_generate(result), encoding: 'UTF-8')
            @last_snapshot = result
            result
          end

          def print_report(result = @last_snapshot)
            output = super
            comparison = result['comparison'] || {}
            puts "reproduced_kept_missing_volume_count   : #{comparison['reproduced_kept_missing_volume_count']}"
            puts "reproduced_kept_component_failure_count: #{comparison['reproduced_kept_component_failure_count']}"
            puts "volume_gate_pass                        : #{result['volume_gate_pass']}"
            puts "FINAL PASS WITH VOLUME GATE             : #{result['final_pass']}"
            output
          end

          def run_kept_volume_postcheck(result_or_path, indoor_model: nil, report_name: nil)
            source_path = result_or_path.is_a?(String) ? result_or_path : nil
            source = if source_path
                       JSON.parse(File.read(source_path, encoding: 'UTF-8'))
                     else
                       result_or_path
                     end
            raise ArgumentError, 'Benchmark result hash or JSON path is required.' unless source.is_a?(Hash)
            unless source['benchmark_input_valid'] == true && source.dig('input_preflight', 'valid') == true
              raise 'The source benchmark did not pass input preflight.'
            end

            model = indoor_model || IndoorCore::IndoorModel.current
            unless model&.model == Sketchup.active_model
              raise 'IndoorModel.current is not bound to the active SketchUp model.'
            end

            full_by_index = Array(source.dig('full', 'decisions')).to_h { |row| [row['index'], row] }
            v3_by_index = Array(source.dig('v3', 'decisions')).to_h { |row| [row['index'], row] }
            requests = full_by_index.values.filter_map do |row|
              live = v3_by_index[row['index']]
              next unless reproduced_kept?(row) && live && reproduced_kept?(live)

              {
                'index' => row['index'],
                'code' => row['code'],
                'cells' => row['cells']
              }
            end
            raise 'No reproduced kept pairs were found in the benchmark result.' if requests.empty?

            output_dir = if source_path
                           File.dirname(source_path)
                         else
                           File.dirname(last_result_path.to_s)
                         end
            raise 'Output directory could not be resolved.' if output_dir.to_s.empty?

            full_runner, full_checker = postcheck_runner(model, :full, output_dir)
            v3_runner, v3_checker = postcheck_runner(model, :v3, output_dir)
            rows = requests.map do |request|
              full_row = recheck_postcheck_pair(full_runner, full_checker, request, :full)
              v3_row = recheck_postcheck_pair(v3_runner, v3_checker, request, :v3)
              {
                'index' => request['index'],
                'code' => request['code'],
                'cells' => request['cells'],
                'full' => full_row,
                'v3' => v3_row,
                'pass' => postcheck_row_pass?(full_row, v3_row)
              }
            end

            stamp = Time.now.strftime('%Y%m%d-%H%M%S')
            name = sanitize(report_name || "kept_volume_postcheck_#{stamp}")
            path = File.join(output_dir, "#{name}.json")
            result = {
              'schema_version' => 1,
              'generated_at' => Time.now.iso8601(6),
              'mode' => 'focused_reproduced_kept_volume_postcheck',
              'source_result_path' => source_path,
              'source_request_sha256' => source['request_sha256'],
              'pair_count' => rows.length,
              'rows' => rows,
              'failure_count' => rows.count { |row| row['pass'] != true },
              'pass' => rows.all? { |row| row['pass'] == true }
            }
            File.write(path, JSON.pretty_generate(result), encoding: 'UTF-8')
            result['result_path'] = path
            result
          end

          def print_kept_volume_postcheck(result)
            puts
            puts('=' * 110)
            puts('FOCUSED REPRODUCED KEPT VOLUME POSTCHECK')
            puts('=' * 110)
            puts "pair_count     : #{result['pair_count']}"
            Array(result['rows']).each do |row|
              puts "index=#{row['index']} pass=#{row['pass']} cells=#{row['cells'].join(' | ')}"
              puts "  full: status=#{row.dig('full', 'status')} volume_mm3=#{row.dig('full', 'volume_mm3')} components=#{row.dig('full', 'component_count')}"
              puts "  v3  : status=#{row.dig('v3', 'status')} volume_mm3=#{row.dig('v3', 'volume_mm3')} components=#{row.dig('v3', 'component_count')}"
            end
            puts "failure_count  : #{result['failure_count']}"
            puts "PASS           : #{result['pass']}"
            puts "result_path    : #{result['result_path']}"
            puts('=' * 110)
            result
          end
        end

        benchmark = Val3dityRecheckV3CurrentPairedBenchmark
        patch = Val3dityRecheckV3CurrentPairedBenchmarkVolumeGate
        benchmark.singleton_class.prepend(patch) unless
          benchmark.singleton_class.ancestors.include?(patch)
      end
    end
  end
end
