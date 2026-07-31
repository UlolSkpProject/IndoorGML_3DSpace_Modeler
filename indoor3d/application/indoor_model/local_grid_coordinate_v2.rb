# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Experimental CellSpace lifecycle context that keeps the existing lifecycle
      # ordering but delegates coordinate preparation to the local-grid V2 path.
      # The legacy CellSpaceLifecycleContext remains unchanged.
      class CellSpaceLifecycleLocalGridContextV2 < CellSpaceLifecycleContext
        def initialize(coordinate_preparer:, **callbacks)
          @coordinate_preparer = coordinate_preparer
          super(**callbacks)
        end

        def initialize_scene(cell_space, storey: default_storey_name)
          cell_space.set_storey(storey)
          @coordinate_preparer.call(cell_space)
          @name_cell_space_entity.call(cell_space)
          @apply_cell_space_material.call(cell_space)
        end
      end

      class IndoorModel
        # Opt-in CellSpace creation/refresh path that preserves a 0.001 mm local
        # coordinate grid across local-axis alignment and origin recentering.
        #
        # The existing create/refresh paths are intentionally left untouched.
        module LocalGridCoordinateV2
          LOCAL_GRID_V2_TOLERANCE_MM = 0.001
          LOCAL_GRID_V2_MM_PER_INCH = 25.4
          LOCAL_GRID_V2_FRAME_EPSILON = 1.0e-10

          def convert_single_group_to_cell_space_local_grid_v2(
            sketchup_group,
            cell_type = CellSpaceType::GENERAL,
            category_code = nil
          )
            with_validation_focus_mutation_batch do
              with_indoor_model_operation('IndoorGML Convert Group to CellSpace Local Grid V2') do
                cell_space = cell_space_lifecycle_service_local_grid_v2.create_from_group(
                  sketchup_group,
                  cell_type: cell_type,
                  category_code: category_code
                )
                flush_validation_focus_row_topology_sync
                cell_space
              end
            end
          end

          def convert_cell_space_jobs_bulk_local_grid_v2(
            jobs,
            fallback_target:,
            original_active_path:,
            preserve_source: nil,
            operation_name: 'Convert Solid Groups to CellSpace Local Grid V2',
            activate_root_context: true
          )
            model = @model || Sketchup.active_model
            active_path = ActivePathController.new(model, logger: IndoorCore::Logger)
            service = BulkCellSpaceConversionService.new(
              model: model,
              jobs: jobs,
              fallback_target: fallback_target,
              target_entities: model.entities,
              converter: proc do |source, cell_type, category_code, storey|
                cell_space_lifecycle_service_local_grid_v2.create_from_group_deferred(
                  source,
                  cell_type: cell_type,
                  category_code: category_code,
                  storey: storey
                )
              end,
              synchronize_all: proc { synchronize_topology_after_bulk_conversion },
              apply_lock_policy: proc { apply_indoor_lock_policy },
              runtime_snapshot: proc { bulk_conversion_runtime_snapshot },
              runtime_restore: proc { |snapshot| restore_bulk_conversion_runtime(snapshot) },
              apply_guards: proc { |&block| with_bulk_cell_space_conversion(&block) },
              operation_runner: proc do |name, **options, &block|
                with_indoor_model_operation(name, **options, &block)
              end,
              restore_active_path: proc { active_path.restore(original_active_path, close_when_nil: true) },
              activate_root_context: activate_root_context ? proc { active_path.close_to_root } : nil,
              clear_dirty_topology: proc { clear_bulk_dirty_topology },
              logger: IndoorCore::Logger,
              labeler: ConversionMessageFormatter.method(:group_label),
              preserve_source: preserve_source,
              operation_name: operation_name
            )
            with_validation_focus_mutation_batch { service.call }
          end

          # Experimental refresh entrypoint. Legacy refresh_runtime_data is not
          # overridden and continues to use the existing recenter behavior.
          def refresh_runtime_data_local_grid_v2(initial_model_load: false)
            with_indoor_model_operation('IndoorGML Refresh Runtime Data Local Grid V2', transparent: true) do
              next true if guard_active?(:@refreshing_runtime)

              with_guard_flag(:@refreshing_runtime) do
                sync do
                  prepare_primal_children_for_initial_load if initial_model_load
                  restore_runtime_from_current_model(persist_repaired_ids: true)
                  recenter_runtime_cell_spaces_local_grid_v2
                  apply_initial_cell_space_materials if initial_model_load
                  rebuild_runtime_transitions_from_cell_adjacency
                end
                invalidate_overlay_transition_points
                apply_indoor_lock_policy
                @editor_session.apply_display_state
                IndoorCore::Logger.puts(
                  "[IndoorGML] Runtime refreshed Local Grid V2: " \
                  "cells=#{@cell_spaces.length}, states=#{@states.length}, transitions=#{@transitions.length}"
                )
                true
              end
            end
          end

          private

          def cell_space_lifecycle_service_local_grid_v2
            @cell_space_lifecycle_service_local_grid_v2 ||= CellSpaceLifecycleService.new(
              source_preparer: CellSpaceLifecycleSourcePreparer.new(
                converted_group: method(:converted_group?),
                type_resolver: IndoorCore.method(:resolve_cell_space_type_and_category),
                geometry_preparer: Utils::Geometry.method(:prepare_cell_space_source_group!),
                tag_storey_resolver: IndoorCore.method(:tag_cell_space_storey),
                storey_resolver: IndoorCore.method(:resolve_cell_space_storey),
                storey_value_resolver: IndoorCore.method(:resolve_cell_space_storey_value)
              ),
              context: CellSpaceLifecycleLocalGridContextV2.new(
                coordinate_preparer: method(:initialize_cell_space_coordinates_local_grid_v2),
                ensure_space_features_groups: method(:ensure_space_features_groups),
                place_cell_group: method(:place_cell_group),
                default_storey_name: method(:default_storey_name),
                fixed_state_height_offset: method(:fixed_state_height_offset),
                recenter_cell_space_geometry: method(:recenter_cell_space_geometry),
                name_cell_space_entity: method(:name_cell_space_entity),
                apply_cell_space_material: method(:apply_cell_space_material),
                track_cell_space_entity: method(:track_cell_space_entity),
                apply_indoor_lock_policy: method(:apply_indoor_lock_policy),
                register_cell_space: method(:register_cell_space),
                register_state: method(:register_state),
                unregister_cell_space: method(:unregister_cell_space),
                unregister_state: method(:unregister_state),
                write_attributes: method(:write_attributes),
                write_cell_space_attributes: method(:write_cell_space_attributes),
                synchronize_adjacency_and_transitions_for_cell_space: method(:synchronize_adjacency_and_transitions_for_cell_space),
                erase_transitions_for_state: method(:erase_transitions_for_state),
                erase_adjacency_for_cell_space: method(:erase_adjacency_for_cell_space)
              )
            )
          end

          # Creation policy:
          #   1. decide/apply the final local frame;
          #   2. recenter using a translation snapped to the 0.001 mm grid.
          #
          # LVN is beta functionality and must only run through its explicit
          # console/API entrypoint.
          def initialize_cell_space_coordinates_local_grid_v2(cell_space)
            raise ArgumentError, 'CellSpace is invalid during Local Grid V2 initialization' unless cell_space&.valid?

            group = cell_space.sketchup_group
            ensure_cell_space_is_child_of_primal_space!(cell_space)
            frame_report = align_cell_space_local_frame_local_grid_v2(group)
            recenter_report = recenter_cell_space_geometry_local_grid_v2(
              group,
              fixed_z_offset_from_bottom: fixed_state_height_offset(cell_space)
            )
            log_local_grid_v2_coordinate_report(cell_space, frame_report, recenter_report, normalized: :unchecked)
            true
          end

          # Refresh policy:
          # - evaluate/apply the local frame;
          # - recenter without implicitly invoking beta LVN.
          def refresh_cell_space_coordinates_local_grid_v2(cell_space)
            return false unless cell_space&.valid?

            ensure_cell_space_is_child_of_primal_space!(cell_space)
            group = cell_space.sketchup_group
            frame_report = align_cell_space_local_frame_local_grid_v2(group)
            recenter_report = recenter_cell_space_geometry_local_grid_v2(
              group,
              fixed_z_offset_from_bottom: fixed_state_height_offset(cell_space)
            )

            log_local_grid_v2_coordinate_report(
              cell_space,
              frame_report,
              recenter_report,
              normalized: :unchecked
            )
            true
          end

          def recenter_runtime_cell_spaces_local_grid_v2
            @cell_spaces.each do |cell_space|
              next unless cell_space&.valid?

              refresh_cell_space_coordinates_local_grid_v2(cell_space)
              write_cell_space_attributes(cell_space)
            rescue StandardError => e
              IndoorCore::Logger.puts(
                "[IndoorGML] Runtime CellSpace Local Grid V2 recenter skipped: " \
                "cell=#{cell_space&.id} #{e.class}: #{e.message}"
              )
            end
          end

          # Equivalent geometric intent to the legacy dominant-wall alignment, but
          # it skips a no-op frame rewrite and reports whether local coordinates were
          # materially transformed.
          def align_cell_space_local_frame_local_grid_v2(cell_space_entity)
            return local_grid_v2_frame_report(false, false, nil, nil) unless cell_space_entity&.valid?
            return local_grid_v2_frame_report(false, false, nil, nil) unless @primal_group&.valid?
            return local_grid_v2_frame_report(false, false, nil, nil) unless cell_space_entity.respond_to?(:definition)

            cell_space_entity.make_unique if cell_space_entity.respond_to?(:make_unique)

            root_world = Utils::Transformation.root_transformation_in_model(@primal_group)
            old_world = root_world * cell_space_entity.transformation
            axes = dominant_vertical_face_axes(cell_space_entity, old_world)
            source = :dominant_vertical_face_normal
            unless axes
              world_points = cell_space_world_vertex_points(cell_space_entity, old_world)
              axes = horizontal_obb_axes(world_points)
              source = :horizontal_obb
            end
            return local_grid_v2_frame_report(false, false, nil, nil) unless axes

            desired_world = Geom::Transformation.axes(
              old_world.origin,
              Geom::Vector3d.new(axes[:x]),
              Geom::Vector3d.new(axes[:y]),
              Geom::Vector3d.new(0.0, 0.0, 1.0)
            )
            geometry_transform = desired_world.inverse * old_world
            changed = local_grid_v2_transform_material?(geometry_transform)
            return local_grid_v2_frame_report(false, false, source, axes[:angle]) unless changed

            definition_entities = cell_space_entity.definition.entities
            entities = definition_entities.to_a
            return local_grid_v2_frame_report(false, false, source, axes[:angle]) if entities.empty?

            definition_entities.transform_entities(geometry_transform, entities)
            set_group_transformation(
              cell_space_entity,
              root_world.inverse * desired_world
            )

            IndoorCore::Logger.puts(
              '[IndoorGML] CellSpace Local Grid V2 frame aligned: ' \
              "entity_id=#{cell_space_entity.entityID} source=#{source} " \
              "angle_deg=#{format('%.9f', axes[:angle] * 180.0 / Math::PI)}"
            )
            local_grid_v2_frame_report(true, true, source, axes[:angle])
          end

          def local_grid_v2_frame_report(changed, applied, source, angle)
            {
              changed: changed,
              applied: applied,
              source: source,
              angle_rad: angle
            }
          end

          def local_grid_v2_transform_material?(transformation)
            values = transformation.to_a.map(&:to_f)
            identity = [
              1.0, 0.0, 0.0, 0.0,
              0.0, 1.0, 0.0, 0.0,
              0.0, 0.0, 1.0, 0.0,
              0.0, 0.0, 0.0, 1.0
            ]
            values.each_index.any? do |index|
              (values[index] - identity[index]).abs > LOCAL_GRID_V2_FRAME_EPSILON
            end
          rescue StandardError
            true
          end

          def recenter_cell_space_geometry_local_grid_v2(
            cell_space_entity,
            fixed_z_offset_from_bottom: nil
          )
            fixed_z = if fixed_z_offset_from_bottom.nil?
                        nil
                      else
                        fixed_local_z_from_world_offset(
                          cell_space_entity,
                          fixed_z_offset_from_bottom
                        )
                      end
            raw_center = Utils::Geometry.find_shell_inner_centroid(
              cell_space_entity,
              fixed_z: fixed_z
            )
            return local_grid_v2_recenter_report(false, raw_center, raw_center) if
              raw_center.distance(ORIGIN) <= 0.001

            snapped_center = snap_local_grid_v2_point(
              raw_center,
              LOCAL_GRID_V2_TOLERANCE_MM
            )

            set_group_transformation(
              cell_space_entity,
              cell_space_entity.transformation * Geom::Transformation.translation(snapped_center)
            )
            cell_space_entity.definition.entities.transform_entities(
              Geom::Transformation.translation(snapped_center.vector_to(ORIGIN)),
              cell_space_entity.definition.entities.to_a
            )

            local_grid_v2_recenter_report(true, raw_center, snapped_center)
          end

          def local_grid_v2_recenter_report(applied, raw_center, snapped_center)
            {
              applied: applied,
              raw_center_mm: local_grid_v2_point_mm(raw_center),
              snapped_center_mm: local_grid_v2_point_mm(snapped_center)
            }
          end

          def snap_local_grid_v2_point(point, tolerance_mm)
            Geom::Point3d.new(
              snap_local_grid_v2_value_inch(point.x, tolerance_mm),
              snap_local_grid_v2_value_inch(point.y, tolerance_mm),
              snap_local_grid_v2_value_inch(point.z, tolerance_mm)
            )
          end

          def snap_local_grid_v2_value_inch(value_inch, tolerance_mm)
            tolerance = Float(tolerance_mm)
            raise ArgumentError, 'Local Grid V2 tolerance must be greater than zero' unless tolerance.positive?

            value_mm = value_inch.to_f * LOCAL_GRID_V2_MM_PER_INCH
            snapped_mm = (value_mm / tolerance).round * tolerance
            snapped_mm / LOCAL_GRID_V2_MM_PER_INCH
          end

          def local_grid_v2_point_mm(point)
            return nil unless point

            [point.x, point.y, point.z].map do |value|
              value.to_f * LOCAL_GRID_V2_MM_PER_INCH
            end
          end

          def log_local_grid_v2_coordinate_report(
            cell_space,
            frame_report,
            recenter_report,
            normalized:
          )
            group = cell_space.sketchup_group
            IndoorCore::Logger.puts(
              '[IndoorGML] CellSpace Local Grid V2 coordinates: ' \
              "cell=#{cell_space.id} entity_id=#{group.entityID} " \
              "frame_changed=#{frame_report[:changed]} recentered=#{recenter_report[:applied]} " \
              "normalized=#{normalized}"
            )
          end
        end
      end
    end
  end
end
