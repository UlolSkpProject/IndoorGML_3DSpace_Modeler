# frozen_string_literal: true

require 'json'
require 'tmpdir'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckIntegrationSmoke
          class << self
            attr_reader :last_result

            def run(root: default_root)
              root = File.expand_path(root)
              production_files = expected_production_files(root)
              benchmark_file = File.join(
                root,
                'dev',
                'val3dity_recheck_integration_benchmark.rb'
              )
              compile_files = production_files + [benchmark_file, __FILE__]
              checks = []

              compile_files.each do |path|
                checks << compile_check(path)
              end

              checks.concat(file_layout_checks(root, production_files))

              require File.join(
                root,
                'indoor3d',
                'validity',
                'val3dity_overlap_geometry_rechecker'
              )
              require File.join(
                root,
                'indoor3d',
                'validity',
                'val3dity_runner'
              )

              checks.concat(class_architecture_checks)
              checks << runner_default_check(root)

              failures = checks.reject { |row| row['pass'] == true }
              @last_result = {
                'schema_version' => 1,
                'root' => root,
                'production_file_count' => production_files.length,
                'check_count' => checks.length,
                'failure_count' => failures.length,
                'checks' => checks,
                'failures' => failures,
                'pass' => failures.empty?
              }
            end

            def print_report(result = @last_result)
              raise 'No integration smoke result is available.' unless result

              puts
              puts('=' * 110)
              puts('VAL3DITY RECHECK INTEGRATION SMOKE')
              puts('=' * 110)
              puts "root                  : #{result['root']}"
              puts "production_file_count : #{result['production_file_count']}"
              puts "check_count           : #{result['check_count']}"
              puts "failure_count         : #{result['failure_count']}"
              Array(result['checks']).each do |row|
                marker = row['pass'] == true ? 'PASS' : 'FAIL'
                puts "[#{marker}] #{row['name']}"
                puts "       #{row['detail']}" unless row['detail'].to_s.empty?
              end
              puts "INTEGRATION PASS      : #{result['pass']}"
              puts('=' * 110)
              result
            end

            private

            def default_root
              File.expand_path('..', __dir__)
            end

            def expected_production_files(root)
              relative = [
                'indoor3d/validity/val3dity_full_intersection_rechecker.rb',
                'indoor3d/validity/val3dity_overlap_geometry_rechecker.rb',
                'indoor3d/validity/overlap_recheck/clipped_operand_analyzer.rb',
                'indoor3d/validity/overlap_recheck/clipped_mesh_rechecker.rb',
                'indoor3d/validity/overlap_recheck/interior_loop_cap.rb',
                'indoor3d/validity/overlap_recheck/boundary_ear_repair.rb',
                'indoor3d/validity/overlap_recheck/boundary_dp_repair.rb',
                'indoor3d/validity/overlap_recheck/boundary_edge_projection.rb',
                'indoor3d/validity/overlap_recheck/boundary_global_edge_support.rb',
                'indoor3d/validity/overlap_recheck/safety_confirmation.rb'
              ]
              relative.map { |path| File.join(root, path) }
            end

            def compile_check(path)
              unless File.file?(path)
                return check(
                  "file exists: #{relative_path(path)}",
                  false,
                  path
                )
              end

              if defined?(RubyVM::InstructionSequence)
                RubyVM::InstructionSequence.compile_file(path)
                check("syntax: #{relative_path(path)}", true, 'compiled')
              else
                check(
                  "syntax: #{relative_path(path)}",
                  true,
                  'RubyVM unavailable; file was already parsed by SketchUp load'
                )
              end
            rescue SyntaxError => e
              check(
                "syntax: #{relative_path(path)}",
                false,
                "#{e.class}: #{e.message}"
              )
            rescue StandardError => e
              check(
                "syntax: #{relative_path(path)}",
                false,
                "#{e.class}: #{e.message}"
              )
            end

            def file_layout_checks(root, production_files)
              active_files = production_files + [
                File.join(root, 'indoor3d', 'core.rb'),
                File.join(root, 'indoor3d', 'validity', 'val3dity_runner.rb')
              ]
              source = active_files.filter_map do |path|
                next unless File.file?(path)

                [path, File.read(path, encoding: 'UTF-8')]
              end

              forbidden = {
                'legacy V3 constant' => 'Val3dityRecheckV3',
                'legacy v3 filename reference' => 'val3dity_recheck_v3',
                'legacy v3 kill switch' => 'INDOORGML_DISABLE_V3_RECHECK'
              }
              checks = forbidden.map do |label, token|
                matches = source.filter_map do |path, content|
                  relative_path(path) if content.include?(token)
                end
                check(label, matches.empty?, matches.join(', '))
              end

              dev_requires = source.filter_map do |path, content|
                relative_path(path) if content.match?(
                  /require(?:_relative)?\s+['\"][^'\"]*dev\//
                )
              end
              checks << check(
                'production source has no dev require',
                dev_requires.empty?,
                dev_requires.join(', ')
              )

              obsolete_patch = File.join(
                root,
                'indoor3d',
                'validity',
                'val3dity_runner_v3_recheck_patch.rb'
              )
              checks << check(
                'obsolete production patch removed',
                !File.exist?(obsolete_patch),
                relative_path(obsolete_patch)
              )

              recheck_v3_files = Dir.glob(
                File.join(root, 'dev', 'val3dity_recheck_v3*')
              ) + Dir.glob(
                File.join(root, 'indoor3d', '**', '*recheck*v3*')
              )
              checks << check(
                'recheck v3 files removed',
                recheck_v3_files.empty?,
                recheck_v3_files.map { |path| relative_path(path) }.join(', ')
              )

              old_probe_files = Dir.glob(
                File.join(
                  root,
                  'dev',
                  'val3dity_recheck_clipped_operand_probe*'
                )
              )
              checks << check(
                'old clipped operand probes removed',
                old_probe_files.empty?,
                old_probe_files.map { |path| relative_path(path) }.join(', ')
              )

              checks
            end

            def class_architecture_checks
              canonical = Val3dityOverlapGeometryRechecker
              engine = Val3dityClippedMeshRecheck::Rechecker
              safety = Val3dityClippedMeshRecheck::SafetyConfirmation
              full = Val3dityFullIntersectionRechecker
              ancestors = canonical.ancestors

              [
                check(
                  'canonical class inherits clipped-mesh engine',
                  canonical < engine,
                  ancestors.first(8).map(&:to_s).join(' -> ')
                ),
                check(
                  'safety confirmation is prepended before engine',
                  ancestors.index(safety) && ancestors.index(engine) &&
                    ancestors.index(safety) < ancestors.index(engine),
                  ancestors.first(8).map(&:to_s).join(' -> ')
                ),
                check(
                  'full geometry engine is internal ancestor only',
                  canonical < full && canonical != full,
                  ancestors.first(8).map(&:to_s).join(' -> ')
                ),
                check(
                  'canonical class exposes primary path records',
                  canonical.public_instance_methods.include?(:proxy_record),
                  canonical.public_instance_methods(false).sort.inspect
                ),
                check(
                  'confirmation and explicit tolerance gates enabled',
                  Val3dityClippedMeshRecheck.full_confirmation_enabled? &&
                    Val3dityClippedMeshRecheck.explicit_overlap_tolerance_enabled?,
                  'both gates must remain enabled'
                )
              ]
            end

            def runner_default_check(root)
              indoor_model = IndoorCore::IndoorModel.current
              unless indoor_model&.model == Sketchup.active_model
                return check(
                  'runner default rechecker is canonical',
                  false,
                  'IndoorModel.current is not bound to active model'
                )
              end

              work_dir = Dir.mktmpdir('indoor_gml_recheck_smoke')
              runner = Val3dityRunner.new(
                File.join(work_dir, '__integration_smoke.gml'),
                report_name: 'integration_smoke',
                work_dir: work_dir,
                indoor_model: indoor_model
              )
              rechecker = runner.send(:overlap_geometry_rechecker)
              check(
                'runner default rechecker is canonical',
                rechecker.class == Val3dityOverlapGeometryRechecker,
                rechecker.class.to_s
              )
            rescue StandardError => e
              check(
                'runner default rechecker is canonical',
                false,
                "#{e.class}: #{e.message}"
              )
            ensure
              FileUtils.remove_entry(work_dir) if
                defined?(work_dir) && work_dir && Dir.exist?(work_dir)
            end

            def check(name, passed, detail = nil)
              {
                'name' => name,
                'pass' => passed == true,
                'detail' => detail.to_s
              }
            end

            def relative_path(path)
              path.to_s.sub(%r{\A#{Regexp.escape(default_root)}/?}, '')
            end
          end
        end
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  tool = ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::
    Val3dityRecheckIntegrationSmoke
  tool.print_report(tool.run)
end
