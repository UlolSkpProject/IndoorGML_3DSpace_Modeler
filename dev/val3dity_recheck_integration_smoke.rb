# frozen_string_literal: true

require 'fileutils'
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
              dev_chain_files = expected_dev_chain_files(root)
              compile_files = production_files + dev_chain_files + [__FILE__]
              checks = compile_files.map { |path| compile_check(path) }
              checks.concat(repository_layout_checks(root, production_files))

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
              checks << require_chain_check(root)

              checks.concat(class_architecture_checks)
              checks << runner_default_check

              failures = checks.reject { |row| row['pass'] == true }
              @last_result = {
                'schema_version' => 3,
                'root' => root,
                'production_file_count' => production_files.length,
                'dev_chain_file_count' => dev_chain_files.length,
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
              puts "dev_chain_file_count  : #{result['dev_chain_file_count']}"
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
              %w[
                indoor3d/validity/val3dity_full_intersection_rechecker.rb
                indoor3d/validity/val3dity_overlap_geometry_rechecker.rb
                indoor3d/validity/overlap_recheck/clipped_operand_analyzer.rb
                indoor3d/validity/overlap_recheck/clipped_mesh_rechecker.rb
                indoor3d/validity/overlap_recheck/interior_loop_cap.rb
                indoor3d/validity/overlap_recheck/boundary_ear_repair.rb
                indoor3d/validity/overlap_recheck/boundary_dp_repair.rb
                indoor3d/validity/overlap_recheck/boundary_edge_projection.rb
                indoor3d/validity/overlap_recheck/boundary_global_edge_support.rb
                indoor3d/validity/overlap_recheck/safety_confirmation.rb
                indoor3d/validity/overlap_recheck/adaptive_routing.rb
              ].map { |path| File.join(root, path) }
            end

            def expected_dev_chain_files(root)
              %w[
                dev/val3dity_recheck_benchmark.rb
                dev/val3dity_recheck_only_runner.rb
                dev/val3dity_recheck_snapshot_store.rb
                dev/val3dity_recheck_integration_benchmark.rb
              ].map { |path| File.join(root, path) }
            end

            def compile_check(path)
              return check(
                "file exists: #{relative_path(path)}",
                false,
                path
              ) unless File.file?(path)

              if defined?(RubyVM::InstructionSequence)
                RubyVM::InstructionSequence.compile_file(path)
                check("syntax: #{relative_path(path)}", true, 'compiled')
              else
                check(
                  "syntax: #{relative_path(path)}",
                  true,
                  'RubyVM unavailable; SketchUp already parsed loaded files'
                )
              end
            rescue SyntaxError, StandardError => e
              check(
                "syntax: #{relative_path(path)}",
                false,
                "#{e.class}: #{e.message}"
              )
            end

            def repository_layout_checks(root, production_files)
              ruby_files = %w[indoor3d dev test].flat_map do |directory|
                Dir.glob(File.join(root, directory, '**', '*.rb'))
              end.uniq.reject do |path|
                File.expand_path(path) == File.expand_path(__FILE__)
              end
              sources = ruby_files.filter_map do |path|
                [path, File.read(path, encoding: 'UTF-8')] if File.file?(path)
              rescue EncodingError
                nil
              end

              forbidden_tokens = {
                'legacy V3 recheck constant removed' =>
                  ['Val3dity', 'Recheck', 'V3'].join,
                'legacy v3 recheck filename reference removed' =>
                  ['val3dity', '_recheck_', 'v3'].join,
                'legacy clipped-operand probe reference removed' =>
                  ['val3dity_recheck_', 'clipped_operand_probe'].join,
                'legacy clipped-operand probe constant removed' =>
                  ['Val3dityRecheck', 'ClippedOperandProbe'].join,
                'legacy v3 kill switch removed' =>
                  ['INDOORGML', '_DISABLE_', 'V3_RECHECK'].join
              }
              checks = forbidden_tokens.map do |label, token|
                matches = sources.filter_map do |path, content|
                  relative_path(path) if content.include?(token)
                end
                check(label, matches.empty?, matches.join(', '))
              end

              production_sources = production_files.filter_map do |path|
                [path, File.read(path, encoding: 'UTF-8')] if File.file?(path)
              end
              dev_requires = production_sources.filter_map do |path, content|
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

              forbidden_files = Dir.glob(
                File.join(root, 'dev', 'val3dity_recheck_v3*')
              ) + Dir.glob(
                File.join(root, 'indoor3d', '**', '*recheck*v3*')
              ) + Dir.glob(
                File.join(
                  root,
                  'dev',
                  'val3dity_recheck_clipped_operand_probe*'
                )
              )
              checks << check(
                'obsolete recheck version files removed',
                forbidden_files.empty?,
                forbidden_files.map { |path| relative_path(path) }.join(', ')
              )

              checks
            end

            def require_chain_check(root)
              require File.join(
                root,
                'dev',
                'val3dity_recheck_integration_benchmark'
              )
              required = defined?(Val3dityRecheckIntegrationBenchmark) &&
                         defined?(Val3dityRecheckSnapshotStore) &&
                         defined?(Val3dityRecheckOnlyRunner)
              check(
                'integration benchmark require chain loads',
                !!required,
                'benchmark -> snapshot store -> replay runner'
              )
            rescue LoadError, StandardError => e
              check(
                'integration benchmark require chain loads',
                false,
                "#{e.class}: #{e.message}"
              )
            end

            def class_architecture_checks
              canonical = Val3dityOverlapGeometryRechecker
              engine = Val3dityClippedMeshRecheck::Rechecker
              adaptive = Val3dityClippedMeshRecheck::AdaptiveRouting
              safety = Val3dityClippedMeshRecheck::SafetyConfirmation
              confirmation = Val3dityFullIntersectionRechecker
              ancestors = canonical.ancestors
              chain = ancestors.first(10).map(&:to_s).join(' -> ')

              [
                check(
                  'canonical class inherits clipped-mesh engine',
                  !!(canonical < engine),
                  chain
                ),
                check(
                  'adaptive routing precedes clipped-mesh engine',
                  ancestors.index(adaptive) && ancestors.index(engine) &&
                    ancestors.index(adaptive) < ancestors.index(engine),
                  chain
                ),
                check(
                  'safety confirmation precedes clipped-mesh engine',
                  ancestors.index(safety) && ancestors.index(engine) &&
                    ancestors.index(safety) < ancestors.index(engine),
                  chain
                ),
                check(
                  'adaptive threshold is 300 faces',
                  Val3dityClippedMeshRecheck.simple_solid_face_threshold == 300,
                  Val3dityClippedMeshRecheck.simple_solid_face_threshold.inspect
                ),
                check(
                  'full geometry is internal confirmation ancestor only',
                  !!(canonical < confirmation) && canonical != confirmation,
                  chain
                ),
                check(
                  'canonical class exposes recheck path records',
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

            def runner_default_check
              indoor_model = IndoorCore::IndoorModel.current
              return check(
                'runner default rechecker is canonical',
                false,
                'IndoorModel.current is not bound to active model'
              ) unless indoor_model&.model == Sketchup.active_model

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
