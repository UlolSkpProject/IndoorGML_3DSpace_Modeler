# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'time'

require_relative 'val3dity_recheck_v3_mesh_proxy_non_solid_fallback'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only geometry snapshot producer for independent v3 verification.
        #
        # This tool does not call SketchUp Solid Boolean and does not modify the
        # validation report. It captures the three triangle sets required by an
        # independent verifier:
        #
        # - original source mesh S
        # - target mesh T and expanded crop box B
        # - current v3 reconstructed proxy P
        #
        # The generated JSON is intentionally self-contained so the verifier can
        # run without SketchUp and without loading any v3 clipping/cap code.
        module Val3dityRecheckV3ProxyEquivalenceSnapshot
          MODE = 'v3_proxy_geometry_equivalence_snapshot'
          DEFAULT_STABLE_SAMPLE_COUNT = 30

          class CaptureAnalyzer < Val3dityRecheckV3MeshProxy::RebuildAnalyzer
            def capture_rebuild(group1, group2, cell_ids, cache)
              started = monotonic_now
              source, target, source_index = choose_source(group1, group2)
              source_id = cell_ids.fetch(source_index).to_s
              target_id = cell_ids.fetch(1 - source_index).to_s
              source_mesh, cache_hit = cached_rebuild_mesh(
                source,
                source_id,
                cache
              )
              crop = expanded_bounds(target.bounds)
              rebuilt = rebuild_geometry(source_mesh, crop)
              target_mesh = capture_group_mesh(target)
              proxy_geometry = rebuilt[:geometry]

              {
                'status' => rebuilt[:error] ? 'error' : 'ok',
                'error' => rebuilt[:error]&.to_s,
                'cells' => cell_ids.map(&:to_s),
                'source_operand_index' => source_index,
                'source_cell' => source_id,
                'target_cell' => target_id,
                'source_mesh_cache_hit' => cache_hit,
                'coordinate_space' => 'SketchUp parent space',
                'coordinate_unit' => 'inch',
                'crop_margin_mm' => Val3dityRecheckV3MeshProxy::GUARD_MARGIN_MM,
                'crop_box' => stringify_bounds(crop),
                'target_crop_containment' => target_crop_containment(
                  target_mesh.fetch('triangles'),
                  crop
                ),
                'source_group' => group_identity(source),
                'target_group' => group_identity(target),
                'source_mesh' => capture_mesh(
                  source_mesh.fetch(:face_count),
                  source_mesh.fetch(:triangles)
                ),
                'target_mesh' => target_mesh,
                'proxy_mesh' => capture_proxy_mesh(proxy_geometry),
                'v3_rebuild_report' => rebuilt.fetch(:report),
                'capture_elapsed_ms' => elapsed_ms(started)
              }
            rescue StandardError => e
              {
                'status' => 'error',
                'error' => "#{e.class}: #{e.message}",
                'cells' => Array(cell_ids).map(&:to_s),
                'capture_elapsed_ms' => elapsed_ms(started)
              }
            end

            private

            def capture_group_mesh(group)
              faces = Utils::Geometry.entity_faces_in_parent_space(group)
              triangles = faces.flat_map do |face|
                Array(face[:triangles])
              end.map do |triangle|
                triangle.map { |point| xyz(point) }
              end
              capture_mesh(faces.length, triangles)
            end

            def capture_mesh(face_count, triangles)
              rows = deep_float_triangles(triangles)
              {
                'face_count' => face_count.to_i,
                'triangle_count' => rows.length,
                'bounds' => triangle_bounds_union(rows),
                'sha256' => triangle_sha256(rows),
                'triangles' => rows
              }
            end

            def capture_proxy_mesh(geometry)
              return nil unless geometry

              rows = deep_float_triangles(geometry.fetch(:triangles))
              {
                'triangle_count' => rows.length,
                'clipped_surface_triangle_count_before_conforming' =>
                  geometry[:clipped_surface_triangle_count].to_i,
                'cap_triangle_count_before_conforming' =>
                  geometry[:cap_triangle_count].to_i,
                'bounds' => triangle_bounds_union(rows),
                'sha256' => triangle_sha256(rows),
                'triangles' => rows
              }
            end

            def deep_float_triangles(triangles)
              Array(triangles).map do |triangle|
                Array(triangle).map do |point|
                  Array(point).first(3).map(&:to_f)
                end
              end
            end

            def triangle_sha256(triangles)
              Digest::SHA256.hexdigest(JSON.generate(triangles))
            end

            def triangle_bounds_union(triangles)
              points = triangles.flatten(1)
              return nil if points.empty?

              {
                'min' => 3.times.map do |axis|
                  points.map { |point| point.fetch(axis).to_f }.min
                end,
                'max' => 3.times.map do |axis|
                  points.map { |point| point.fetch(axis).to_f }.max
                end
              }
            end

            def stringify_bounds(bounds)
              {
                'min' => Array(bounds.fetch(:min)).map(&:to_f),
                'max' => Array(bounds.fetch(:max)).map(&:to_f)
              }
            end

            def target_crop_containment(triangles, crop)
              points = Array(triangles).flatten(1)
              clearances = points.flat_map do |point|
                3.times.flat_map do |axis|
                  [
                    point.fetch(axis).to_f - crop.fetch(:min).fetch(axis).to_f,
                    crop.fetch(:max).fetch(axis).to_f - point.fetch(axis).to_f
                  ]
                end
              end
              minimum = clearances.min
              {
                'point_count' => points.length,
                'all_vertices_inside_or_on_box' =>
                  !minimum.nil? && minimum >= 0.0,
                'all_vertices_strictly_inside_box' =>
                  !minimum.nil? && minimum.positive?,
                'minimum_clearance_in' => minimum,
                'minimum_clearance_mm' => minimum && minimum * 25.4
              }
            end

            def group_identity(group)
              {
                'name' => group.respond_to?(:name) ? group.name.to_s : nil,
                'entity_id' => group.respond_to?(:entityID) ? group.entityID : nil,
                'persistent_id' =>
                  group.respond_to?(:persistent_id) ? group.persistent_id : nil,
                'object_id' => group.object_id
              }
            rescue StandardError
              { 'object_id' => group.object_id }
            end
          end

          class CaptureRechecker < Val3dityOverlapGeometryRechecker
            attr_reader :captures, :mesh_cache

            def initialize(**options)
              super
              @capture_analyzer = CaptureAnalyzer.new(options.fetch(:tolerance))
              @captures = {}
              @mesh_cache = {}
            end

            def capture(cell_id1, cell_id2)
              @captures[pair_key(cell_id1, cell_id2)]
            end

            private

            # pair_analysis resolves the production CellSpace groups and calls
            # this method. Replace only the native Boolean stage with a pure
            # geometry capture. The returned value exists solely to let the base
            # pair-analysis pipeline finish; it is not written to the real report.
            def model_solid_intersection_for_pair(
              group1,
              group2,
              cell_id1,
              cell_id2
            )
              cells = [cell_id1.to_s, cell_id2.to_s]
              capture = @capture_analyzer.capture_rebuild(
                group1,
                group2,
                cells,
                @mesh_cache
              )
              @captures[pair_key(cell_id1, cell_id2)] = capture

              if capture['status'] == 'ok'
                {
                  status: :not_reproduced,
                  reason: 'CAPTURE_ONLY_BOOLEAN_NOT_EXECUTED',
                  volume: 0.0,
                  component_count: 0
                }
              else
                {
                  status: :inconclusive,
                  reason: capture['error'] || 'CAPTURE_REBUILD_FAILED',
                  volume: nil,
                  component_count: nil
                }
              end
            rescue StandardError => e
              @captures[pair_key(cell_id1, cell_id2)] = {
                'status' => 'error',
                'error' => "#{e.class}: #{e.message}",
                'cells' => [cell_id1.to_s, cell_id2.to_s]
              }
              {
                status: :inconclusive,
                reason: "CAPTURE_EXCEPTION: #{e.class}: #{e.message}",
                volume: nil,
                component_count: nil
              }
            end

            def pair_key(cell_id1, cell_id2)
              [cell_id1.to_s, cell_id2.to_s].sort.join('|')
            end
          end

          class << self
            attr_reader :last_result_path, :last_progress_log_path, :last_snapshot

            def run(paired_report_path,
                    comparison_path: nil,
                    output_dir: nil,
                    report_name: nil,
                    stable_sample_count: DEFAULT_STABLE_SAMPLE_COUNT,
                    indoor_model: nil)
              paired_report_path = file!(paired_report_path, 'Paired v3 report')
              comparison_path = resolve_comparison_path(
                paired_report_path,
                comparison_path
              )
              paired = read_json(paired_report_path)
              comparison = read_json(comparison_path)
              decisions = Array(paired.dig('v3_mesh_proxy', 'decisions'))
              raise 'Paired report contains no v3 decisions.' if decisions.empty?
              validate_reports!(paired, comparison, decisions)

              indoor_model ||= IndoorCore::IndoorModel.current
              unless indoor_model&.model == Sketchup.active_model
                raise 'IndoorModel.current is not bound to the active SketchUp model.'
              end

              selected = select_decisions(
                decisions,
                comparison,
                stable_sample_count.to_i
              )
              pairs = group_selected_pairs(selected)
              raise 'No verification pairs were selected.' if pairs.empty?

              stamp = Time.now.strftime('%Y%m%d-%H%M%S')
              output_dir = File.expand_path(
                output_dir || File.join(
                  File.dirname(paired_report_path),
                  'equivalence',
                  stamp
                )
              )
              FileUtils.mkdir_p(output_dir)
              name = sanitize(report_name || "v3_proxy_equivalence_snapshot_#{stamp}")
              result_path = File.join(output_dir, "#{name}.json")
              progress_path = File.join(output_dir, 'progress.jsonl')
              @last_result_path = result_path
              @last_progress_log_path = progress_path

              rechecker = CaptureRechecker.new(
                indoor_model: indoor_model,
                model: indoor_model.model,
                tolerance: Utils::Geometry::VALIDATION_TOLERANCE,
                logger: nil
              )

              pair_rows = []
              mesh_catalog = {}
              errors = []
              File.open(progress_path, 'w:UTF-8') do |io|
                io.sync = true
                append(io, {
                  'event' => 'start',
                  'generated_at' => Time.now.iso8601(6),
                  'mode' => MODE,
                  'paired_report_path' => paired_report_path,
                  'comparison_path' => comparison_path,
                  'selected_request_count' => selected.length,
                  'selected_unique_pair_count' => pairs.length,
                  'sketchup_boolean_executed' => false
                })

                pairs.each_with_index do |pair, pair_index|
                  started = clock
                  cells = pair.fetch('cells')
                  analysis = rechecker.pair_analysis(cells[0], cells[1])
                  capture = rechecker.capture(cells[0], cells[1])
                  catalog_capture_meshes!(capture, mesh_catalog) if capture
                  row = pair.merge(
                    'capture' => capture,
                    'base_pair_analysis_status' => analysis[:status].to_s,
                    'base_pair_analysis_reason' => analysis[:reason]&.to_s,
                    'adjacency_candidate_count' =>
                      Array(analysis[:adjacency_candidates]).length,
                    'elapsed_ms' => elapsed_ms(started)
                  )
                  pair_rows << row
                  append(io, {
                    'event' => 'pair',
                    'generated_at' => Time.now.iso8601(6),
                    'processed' => pair_index + 1,
                    'total' => pairs.length,
                    'cells' => cells,
                    'cohorts' => pair['cohorts'],
                    'capture_status' => capture && capture['status'],
                    'capture_error' => capture && capture['error'],
                    'elapsed_ms' => row['elapsed_ms']
                  })
                rescue StandardError => e
                  error = {
                    'pair_index' => pair_index,
                    'cells' => pair['cells'],
                    'error' => "#{e.class}: #{e.message}"
                  }
                  errors << error
                  append(io, error.merge(
                    'event' => 'error',
                    'generated_at' => Time.now.iso8601(6)
                  ))
                end
              end

              cohort_counts = selected.each_with_object(Hash.new(0)) do |row, counts|
                Array(row['cohorts']).each { |cohort| counts[cohort] += 1 }
              end.sort.to_h
              capture_status_counts = pair_rows.map do |row|
                row.dig('capture', 'status') || 'missing'
              end.tally.sort.to_h

              snapshot = {
                'schema_version' => 1,
                'generated_at' => Time.now.iso8601(6),
                'mode' => MODE,
                'geometry_reexecuted' => true,
                'sketchup_boolean_executed' => false,
                'validation_report_modified' => false,
                'production_decision_modified' => false,
                'source_paired_report_path' => paired_report_path,
                'source_comparison_path' => comparison_path,
                'request_sha256' => paired['request_sha256'],
                'snapshot_request_count' => decisions.length,
                'selected_request_count' => selected.length,
                'selected_unique_pair_count' => pairs.length,
                'selection_cohort_counts' => cohort_counts,
                'capture_status_counts' => capture_status_counts,
                'mesh_cache_entry_count' => rechecker.mesh_cache.length,
                'mesh_catalog' => mesh_catalog.sort.to_h,
                'coordinate_contract' => {
                  'space' => 'SketchUp parent space',
                  'unit' => 'inch',
                  'json_number_encoding' =>
                    'Ruby JSON shortest round-trip IEEE-754 double',
                  'independent_verifier_rule' =>
                    'must not require or load v3 clipping, cap, repair, or SketchUp Boolean code'
                },
                'pairs' => pair_rows,
                'errors' => errors,
                'completed' => errors.empty? && pair_rows.length == pairs.length,
                'adoptable_for_production' => false,
                'next_stage' =>
                  'run independent offline proxy geometry equivalence verifier'
              }

              File.write(
                result_path,
                JSON.pretty_generate(snapshot),
                encoding: 'UTF-8'
              )
              File.open(progress_path, 'a:UTF-8') do |io|
                append(io, {
                  'event' => 'finish',
                  'generated_at' => Time.now.iso8601(6),
                  'result_path' => result_path,
                  'selected_unique_pair_count' => pairs.length,
                  'captured_pair_count' => pair_rows.length,
                  'error_count' => errors.length,
                  'capture_status_counts' => capture_status_counts
                })
              end

              @last_snapshot = snapshot
              snapshot
            end

            private

            def validate_reports!(paired, comparison, decisions)
              unless paired['request_sha256'].to_s == comparison['request_sha256'].to_s
                raise 'Paired and comparison request SHA-256 values differ.'
              end
              unless paired['request_count'].to_i == decisions.length
                raise 'Paired report request count does not match decisions.'
              end
              unless comparison['request_count'].to_i == decisions.length
                raise 'Comparison request count does not match paired decisions.'
              end
            end

            def select_decisions(decisions, comparison, stable_sample_count)
              by_index = decisions.to_h { |row| [row.fetch('index').to_i, row] }
              cohorts = Hash.new { |hash, key| hash[key] = [] }

              Array(comparison.dig('pair_comparison', 'mismatches')).each do |row|
                index = row.fetch('index').to_i
                initial_status = row.dig('initial', 'status').to_s
                v3_status = row.dig('v3', 'status').to_s
                cohorts[index] << 'decision_mismatch'
                cohorts[index] << "initial_#{initial_status}_to_v3_#{v3_status}"
              end
              decisions.each do |row|
                index = row.fetch('index').to_i
                status = row['status'].to_s
                proxy = row['proxy'] || {}
                path = proxy['path'].to_s
                cohorts[index] << 'kept_control' if status == 'kept'
                cohorts[index] << 'inconclusive_control' if status == 'inconclusive'
                cohorts[index] << 'fallback_control' if
                  path == 'original_full_recheck_fallback'
                cohorts[index] << 'boundary_repair_applied' if
                  proxy.dig(
                    'v3_analysis',
                    'reconstructed_topology',
                    'boundary_ear_repair_applied'
                  ) == true
              end

              stable_direct = decisions.select do |row|
                index = row.fetch('index').to_i
                row['status'].to_s == 'suppressed' &&
                  row.dig('proxy', 'path').to_s == 'v3_direct_mesh_proxy' &&
                  cohorts[index].empty?
              end
              representative_sample(
                stable_direct,
                [stable_sample_count, 0].max
              ).each do |row|
                cohorts[row.fetch('index').to_i] << 'stable_direct_suppressed_control'
              end

              cohorts.keys.sort.filter_map do |index|
                row = by_index[index]
                next unless row

                row.merge('cohorts' => cohorts[index].uniq.sort)
              end
            end

            def representative_sample(rows, count)
              return [] if count.zero? || rows.empty?
              return rows if rows.length <= count

              ranked_source = rows.sort_by do |row|
                [
                  -row.dig('proxy', 'v3_analysis', 'source_triangle_count').to_i,
                  row.fetch('index').to_i
                ]
              end
              ranked_proxy = rows.sort_by do |row|
                [
                  -row.dig(
                    'proxy',
                    'v3_analysis',
                    'reconstructed_total_triangle_count'
                  ).to_i,
                  row.fetch('index').to_i
                ]
              end
              by_index = rows.sort_by { |row| row.fetch('index').to_i }
              selected = []
              third = [count / 3, 1].max
              selected.concat(ranked_source.first(third))
              selected.concat(ranked_proxy.first(third))

              remaining = count - selected.uniq { |row| row.fetch('index').to_i }.length
              if remaining.positive?
                step = by_index.length.to_f / remaining
                remaining.times do |offset|
                  selected << by_index[[(offset * step).floor, by_index.length - 1].min]
                end
              end
              selected.uniq { |row| row.fetch('index').to_i }.first(count)
            end

            def group_selected_pairs(rows)
              grouped = {}
              rows.each do |row|
                cells = Array(row['cells']).map(&:to_s)
                key = cells.sort.join('|')
                entry = grouped[key] ||= {
                  'cells' => cells,
                  'request_indices' => [],
                  'codes' => [],
                  'cohorts' => [],
                  'source_decisions' => []
                }
                entry['request_indices'] << row.fetch('index').to_i
                entry['codes'] << row['code'].to_i
                entry['cohorts'].concat(Array(row['cohorts']))
                entry['source_decisions'] << {
                  'index' => row.fetch('index').to_i,
                  'code' => row['code'].to_i,
                  'status' => row['status'].to_s,
                  'reason' => row['reason'].to_s,
                  'path' => row.dig('proxy', 'path'),
                  'fallback_reason' => row.dig('proxy', 'fallback_reason'),
                  'intersection_status' =>
                    row.dig('proxy', 'intersection_status')
                }
              end
              grouped.values.each do |entry|
                entry['request_indices'].uniq!.sort!
                entry['codes'].uniq!.sort!
                entry['cohorts'].uniq!.sort!
                entry['source_decisions'].sort_by! { |row| row['index'] }
              end
              grouped.values.sort_by { |entry| entry['request_indices'].min }
            end

            def catalog_capture_meshes!(capture, catalog)
              %w[source_mesh target_mesh].each do |field|
                mesh = capture[field]
                next unless mesh.is_a?(Hash)

                sha = mesh['sha256'].to_s
                next if sha.empty?

                catalog[sha] ||= mesh
                capture[field] = {
                  'mesh_sha256' => sha,
                  'face_count' => mesh['face_count'],
                  'triangle_count' => mesh['triangle_count'],
                  'bounds' => mesh['bounds']
                }
              end
            end

            def resolve_comparison_path(paired_report_path, explicit)
              return file!(explicit, 'Recompared report') if explicit

              candidate = paired_report_path.sub(/\.json\z/, '_recompared.json')
              file!(candidate, 'Recompared report')
            end

            def read_json(path)
              JSON.parse(File.read(path, encoding: 'UTF-8'))
            end

            def file!(path, label)
              expanded = File.expand_path(path.to_s)
              raise "#{label} was not found: #{expanded}" unless File.file?(expanded)

              expanded
            end

            def sanitize(value)
              text = value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
              text.empty? ? 'v3_proxy_equivalence_snapshot' : text
            end

            def append(io, payload)
              io.write(JSON.generate(payload))
              io.write("\n")
              io.flush
            end

            def elapsed_ms(started)
              ((clock - started) * 1000.0).round(3)
            end

            def clock
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end
        end
      end
    end
  end
end
