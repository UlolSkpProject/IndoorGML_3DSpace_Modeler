# frozen_string_literal: true

require_relative '../indoor3d/validity/val3dity_overlap_geometry_rechecker'
require_relative 'val3dity_recheck_clipped_operand_probe_v3'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only phase-1 proxy rechecker.
        #
        # v3 topology is used as a conservative gate. For a closed v3 pair the
        # more complex operand is cropped by a simple expanded target AABB using
        # SketchUp's native solid Boolean. The resulting proxy solid is then
        # intersected with the original target operand. Any gate/build/manifold
        # failure falls back to the unchanged production full-solid recheck.
        #
        # This is intentionally not production code. It benchmarks the complete
        # proxy-solid decision path before replacing the native AABB crop with a
        # manually reconstructed clipped mesh and cap triangulation.
        module Val3dityRecheckV3BoxProxy
          MODE = 'v3_native_aabb_proxy_then_target_boolean'
          GUARD_MARGIN_MM = 5.0
          GUARD_MARGIN_IN = GUARD_MARGIN_MM / 25.4

          class Rechecker < Val3dityOverlapGeometryRechecker
            attr_reader :proxy_records, :mesh_cache

            def initialize(**options)
              super
              @v3_analyzer = Val3dityRecheckClippedOperandProbeV3::Analyzer.new(
                options.fetch(:tolerance)
              )
              @mesh_cache = {}
              @proxy_records = {}
            end

            def proxy_record(cell_id1, cell_id2)
              @proxy_records[pair_key_for_proxy(cell_id1, cell_id2)]
            end

            private

            def model_solid_intersection_for_pair(group1, group2, cell_id1, cell_id2)
              started = clock
              cells = [cell_id1.to_s, cell_id2.to_s]
              record = {
                'cells' => cells,
                'mode' => MODE,
                'guard_margin_mm' => GUARD_MARGIN_MM,
                'path' => nil,
                'fallback_reason' => nil
              }

              gate_started = clock
              analysis = @v3_analyzer.analyze(group1, group2, cells, @mesh_cache)
              record['gate_elapsed_ms'] = elapsed_ms(gate_started)
              record['v3_analysis'] = analysis

              gate_reason = v3_gate_failure_reason(analysis)
              if gate_reason
                fallback_started = clock
                result = super(group1, group2, cell_id1, cell_id2)
                finalize_original_fallback(
                  record, result, gate_reason, fallback_started, started
                )
                return result
              end

              source_index = analysis.fetch('source_operand_index').to_i
              source = source_index.zero? ? group1 : group2
              target = source_index.zero? ? group2 : group1
              record['source_operand_index'] = source_index
              record['source_cell'] = cells[source_index]
              record['target_cell'] = cells[1 - source_index]

              proxy_result = proxy_intersection(source, target, cells, record)
              if proxy_result[:fallback]
                fallback_started = clock
                result = super(group1, group2, cell_id1, cell_id2)
                finalize_original_fallback(
                  record,
                  result,
                  proxy_result[:fallback_reason] || 'proxy_unknown_failure',
                  fallback_started,
                  started
                )
                return result
              end

              record['path'] = 'v3_box_proxy'
              record['intersection_status'] = proxy_result[:status].to_s
              record['intersection_reason'] = proxy_result[:reason].to_s if proxy_result[:reason]
              record['intersection_volume_in3'] = proxy_result[:volume] if proxy_result.key?(:volume)
              record['intersection_component_count'] = proxy_result[:component_count] if
                proxy_result.key?(:component_count)
              record['total_elapsed_ms'] = elapsed_ms(started)
              store_record(record)
              proxy_result
            rescue StandardError => e
              record ||= { 'cells' => [cell_id1.to_s, cell_id2.to_s], 'mode' => MODE }
              record['proxy_exception'] = "#{e.class}: #{e.message}"
              fallback_started = clock
              result = super(group1, group2, cell_id1, cell_id2)
              finalize_original_fallback(
                record, result, 'proxy_exception', fallback_started, started || clock
              )
              result
            end

            def v3_gate_failure_reason(analysis)
              return 'v3_analysis_error' unless analysis['status'] == 'ok'
              return 'surface_miss' if analysis['surface_miss_requires_containment_test'] == true
              return 'global_cap_open' unless analysis['global_cap_graph_closed'] == true

              nil
            end

            def finalize_original_fallback(record, result, reason, fallback_started, started)
              record['path'] = 'original_full_recheck_fallback'
              record['fallback_reason'] = reason.to_s
              record['fallback_elapsed_ms'] = elapsed_ms(fallback_started)
              record['intersection_status'] = result[:status].to_s if result.is_a?(Hash)
              record['intersection_reason'] = result[:reason].to_s if result.is_a?(Hash) && result[:reason]
              record['intersection_volume_in3'] = result[:volume] if result.is_a?(Hash) && result.key?(:volume)
              record['intersection_component_count'] = result[:component_count] if
                result.is_a?(Hash) && result.key?(:component_count)
              record['total_elapsed_ms'] = elapsed_ms(started)
              store_record(record)
            end

            def proxy_intersection(source, target, cell_ids, record)
              model = @model || Sketchup.active_model
              return fallback_result('model_unavailable') unless model
              return fallback_result('input_not_manifold') unless
                valid_manifold_group?(source) && valid_manifold_group?(target)

              source_copy = nil
              crop_box = nil
              proxy = nil
              target_copy = nil
              result = nil

              outcome = @indoor_model.with_indoor_model_operation(
                'IndoorGML v3 box proxy recheck',
                rollback: true
              ) do
                source_copy_started = clock
                source_copy = build_boolean_copy(source)
                record['source_copy_elapsed_ms'] = elapsed_ms(source_copy_started)
                next fallback_result('source_copy_failed') unless source_copy
                next fallback_result('source_copy_not_manifold') unless
                  valid_manifold_group?(source_copy)

                crop_box_started = clock
                crop_box = build_crop_box(source, target)
                record['crop_box_build_elapsed_ms'] = elapsed_ms(crop_box_started)
                next fallback_result('crop_box_build_failed') unless crop_box
                next fallback_result('crop_box_not_manifold') unless
                  valid_manifold_group?(crop_box)
                next fallback_result('crop_boolean_unsupported') unless
                  source_copy.respond_to?(:intersect)

                crop_started = clock
                proxy = source_copy.intersect(crop_box)
                record['crop_boolean_elapsed_ms'] = elapsed_ms(crop_started)
                next fallback_result('crop_boolean_failed') if proxy.nil?

                proxy_faces = valid_faces(proxy)
                proxy_edges = valid_edges(proxy)
                record['proxy_face_count'] = proxy_faces.length
                record['proxy_edge_count'] = proxy_edges.length
                next fallback_result('proxy_empty') if proxy_faces.empty? && proxy_edges.empty?
                next fallback_result('proxy_not_manifold') unless valid_manifold_group?(proxy)

                proxy_volume = solid_group_volume(proxy)
                next fallback_result('proxy_nonpositive_volume') unless
                  proxy_volume && proxy_volume.positive?
                record['proxy_volume_in3'] = proxy_volume

                target_copy_started = clock
                target_copy = build_boolean_copy(target)
                record['target_copy_elapsed_ms'] = elapsed_ms(target_copy_started)
                next fallback_result('target_copy_failed') unless target_copy
                next fallback_result('target_copy_not_manifold') unless
                  valid_manifold_group?(target_copy)
                next fallback_result('target_boolean_unsupported') unless
                  proxy.respond_to?(:intersect)

                target_started = clock
                result = proxy.intersect(target_copy)
                record['target_boolean_elapsed_ms'] = elapsed_ms(target_started)
                next fallback_result('target_boolean_failed') if result.nil?

                classify_proxy_result(result, cell_ids)
              end
              outcome
            rescue StandardError => e
              record['proxy_operation_exception'] = "#{e.class}: #{e.message}"
              fallback_result('proxy_operation_exception')
            ensure
              cleanup_entities(result, target_copy, proxy, crop_box, source_copy, source, target)
            end

            def classify_proxy_result(result, cell_ids)
              faces = valid_faces(result)
              edges = valid_edges(result)
              if faces.empty? && edges.empty?
                return {
                  status: :not_reproduced,
                  reason: 'NO_VALID_INTERSECTION_GROUP_RETURNED',
                  volume: 0.0,
                  component_count: 0
                }
              end

              return non_solid_intersection_result(result, faces, edges) unless
                valid_manifold_group?(result)

              volume = solid_group_volume(result)
              return non_solid_intersection_result(result, faces, edges) if
                volume.nil? || volume <= 0.0

              cache_intersection_overlay_geometry(result, cell_ids, volume)
              {
                status: :reproduced,
                reason: 'REPRODUCED_AS_VALID_SKETCHUP_INTERSECTION',
                volume: volume,
                component_count: face_components(faces).length
              }
            end

            def build_crop_box(source, target)
              parent = source.respond_to?(:parent) ? source.parent : nil
              entities = parent.respond_to?(:entities) ? parent.entities : nil
              return nil unless entities&.respond_to?(:add_group)

              bounds = target.bounds
              min = [
                bounds.min.x.to_f - GUARD_MARGIN_IN,
                bounds.min.y.to_f - GUARD_MARGIN_IN,
                bounds.min.z.to_f - GUARD_MARGIN_IN
              ]
              max = [
                bounds.max.x.to_f + GUARD_MARGIN_IN,
                bounds.max.y.to_f + GUARD_MARGIN_IN,
                bounds.max.z.to_f + GUARD_MARGIN_IN
              ]
              return nil unless 3.times.all? { |axis| max[axis] > min[axis] }

              group = entities.add_group
              group.name = '__IndoorGML_V3_CROP_BOX__' if group.respond_to?(:name=)
              points = box_points(min, max)
              faces = [
                [0, 3, 2, 1],
                [4, 5, 6, 7],
                [0, 1, 5, 4],
                [3, 7, 6, 2],
                [0, 4, 7, 3],
                [1, 2, 6, 5]
              ].map do |indices|
                group.entities.add_face(indices.map { |index| points.fetch(index) })
              end
              unless faces.all? { |face| face&.valid? }
                group.erase! if group.valid?
                return nil
              end

              group
            rescue StandardError
              group.erase! if group&.valid?
              nil
            end

            def box_points(min, max)
              [
                Geom::Point3d.new(min[0], min[1], min[2]),
                Geom::Point3d.new(max[0], min[1], min[2]),
                Geom::Point3d.new(max[0], max[1], min[2]),
                Geom::Point3d.new(min[0], max[1], min[2]),
                Geom::Point3d.new(min[0], min[1], max[2]),
                Geom::Point3d.new(max[0], min[1], max[2]),
                Geom::Point3d.new(max[0], max[1], max[2]),
                Geom::Point3d.new(min[0], max[1], max[2])
              ]
            end

            def valid_faces(group)
              return [] unless group&.valid? && group.respond_to?(:definition)

              group.definition.entities.grep(Sketchup::Face).select(&:valid?)
            rescue StandardError
              []
            end

            def valid_edges(group)
              return [] unless group&.valid? && group.respond_to?(:definition)

              group.definition.entities.grep(Sketchup::Edge).select(&:valid?)
            rescue StandardError
              []
            end

            def fallback_result(reason)
              { fallback: true, fallback_reason: reason.to_s }
            end

            def cleanup_entities(*entities)
              protected = entities.last(2)
              entities[0...-2].compact.uniq(&:object_id).each do |entity|
                next if protected.include?(entity)
                next unless entity.respond_to?(:valid?) && entity.valid?

                entity.erase!
              rescue StandardError
                nil
              end
            end

            def store_record(record)
              cells = Array(record['cells'])
              @proxy_records[pair_key_for_proxy(cells[0], cells[1])] = record
            end

            def pair_key_for_proxy(cell_id1, cell_id2)
              [cell_id1.to_s, cell_id2.to_s].sort.join('|')
            end

            def elapsed_ms(started)
              ((clock - started) * 1000.0).round(3)
            end

            def clock
              Process.clock_gettime(Process::CLOCK_MONOTONIC)
            end
          end

          class << self
            def log(message)
              text = "[IndoorGML][V3BoxProxy] #{message}"
              if defined?(IndoorCore::Logger) && IndoorCore::Logger.respond_to?(:puts)
                IndoorCore::Logger.puts(text)
              else
                puts(text)
              end
            rescue StandardError
              nil
            end
          end

          log(
            'loaded: v3 topology gate + native AABB proxy solid + original fallback; ' \
            'production code unchanged'
          )
        end
      end
    end
  end
end
