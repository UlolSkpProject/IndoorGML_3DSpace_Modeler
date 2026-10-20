# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class StateOverlayRenderer
        # view.draw_points에 alpha값이 적용되지 않음
        DUAL_STATE_COLOR = Sketchup::Color.new(35, 120, 255, 0)
        STATE_BASE_POINT_SIZE_PIXELS = 12.0
        STATE_MIN_POINT_SIZE_PIXELS = 2
        STATE_MAX_POINT_SIZE_PIXELS = 24
        # SketchUp draw_points style 7 is a filled triangle.
        STATE_POINT_STYLE = 7

        def initialize(indoor_model:, transform_context:)
          @indoor_model = indoor_model
          @transform_context = transform_context
          @render_states = []
          @render_state_points = []
          @render_state_groups = {}
          @cell_transform_keys = {}
          @primal_transform_key = nil
          @render_state_points_dirty = true
          clear_extent_cache
        end

        def draw(view, state_radius_scale: 1.0)
          prepare_state_points
          return if @render_state_points.empty?

          view.draw_points(
            @render_state_points,
            overlay_state_point_size(state_radius_scale: state_radius_scale),
            STATE_POINT_STYLE,
            DUAL_STATE_COLOR
          )
        end

        def clear_cache
          @render_states = []
          @render_state_points = []
          @render_state_groups = {}
          @cell_transform_keys = {}
          @primal_transform_key = nil
          @render_state_points_dirty = true
          clear_extent_cache
        end

        def overlay_state_point(state)
          @transform_context.overlay_render_point(@transform_context.overlay_state_root_local_point(state))
        rescue StandardError
          state.position
        end

        def overlay_state_bounds_radius(state, state_radius_scale:)
          (state.radius || State.display_radius) * state_radius_scale
        end

        def overlay_state_extent_points(state_radius_scale:)
          prepare_state_points
          return [] if @render_state_points.empty?

          scale = state_radius_scale.to_f
          return @render_state_extent_points if @render_state_extent_scale == scale

          min_x = nil
          min_y = nil
          min_z = nil
          max_x = nil
          max_y = nil
          max_z = nil

          @render_state_points.each_with_index do |point, index|
            state = @render_states[index]
            radius = overlay_state_bounds_radius(state, state_radius_scale: scale)
            low_x = point.x - radius
            low_y = point.y - radius
            low_z = point.z - radius
            high_x = point.x + radius
            high_y = point.y + radius
            high_z = point.z + radius

            min_x = low_x if min_x.nil? || low_x < min_x
            min_y = low_y if min_y.nil? || low_y < min_y
            min_z = low_z if min_z.nil? || low_z < min_z
            max_x = high_x if max_x.nil? || high_x > max_x
            max_y = high_y if max_y.nil? || high_y > max_y
            max_z = high_z if max_z.nil? || high_z > max_z
          end

          @render_state_extent_scale = scale
          @render_state_extent_points = [
            Geom::Point3d.new(min_x, min_y, min_z),
            Geom::Point3d.new(max_x, max_y, max_z)
          ]
        end

        def overlay_state_point_size(state_radius_scale:)
          size = STATE_BASE_POINT_SIZE_PIXELS * state_radius_scale
          size.round.clamp(STATE_MIN_POINT_SIZE_PIXELS, STATE_MAX_POINT_SIZE_PIXELS)
        end

        private

        def prepare_state_points
          if @render_state_points_dirty
            rebuild_state_points
          else
            refresh_selected_state_points
          end
        end

        def rebuild_state_points
          @render_states.clear
          @render_state_points.clear
          @render_state_groups.clear
          @cell_transform_keys.clear
          clear_extent_cache

          root_local_points = []
          @indoor_model.states.each do |state|
            next unless state&.valid?()
            next unless @transform_context.overlay_state_visible?(state)

            @render_states << state
            root_local_points << state_root_local_point(state)
            remember_state_group(state, @render_states.length - 1)
          end

          if @transform_context.respond_to?(:overlay_render_points)
            @render_state_points.concat(@transform_context.overlay_render_points(root_local_points))
          else
            root_local_points.each do |point|
              @render_state_points << @transform_context.overlay_render_point(point)
            end
          end
          @primal_transform_key = current_primal_transform_key
          @render_state_groups.each_value do |entry|
            @cell_transform_keys[entry[:group].object_id] = current_cell_transform_key(entry[:cell])
          end
          @render_state_points_dirty = false
        end

        # State points normally remain cached. While the user is transforming a
        # selected CellSpace (or the PrimalSpaceFeatures container), compare only
        # the relevant transform fingerprints and refresh the affected points.
        # Observer/topology invalidation remains the fallback for unselected and
        # programmatic changes.
        def refresh_selected_state_points
          selected_entities = current_selection_entities
          return if selected_entities.empty?

          primal_group = @indoor_model.primal_group if @indoor_model.respond_to?(:primal_group)
          if primal_group && selected_entities.any? { |entity| entity.equal?(primal_group) }
            current_key = current_primal_transform_key
            if current_key != @primal_transform_key
              rebuild_state_points
              return
            end
          end

          points_changed = false
          selected_entities.each do |entity|
            entry = @render_state_groups[entity.object_id]
            next unless entry && entry[:group].equal?(entity)

            group_key = entity.object_id
            current_key = current_cell_transform_key(entry[:cell])
            next if current_key == @cell_transform_keys[group_key]

            entry[:indices].each do |index|
              @render_state_points[index] = overlay_state_point(@render_states[index])
            end
            @cell_transform_keys[group_key] = current_key
            points_changed = true
          end
          clear_extent_cache if points_changed
        rescue StandardError
          # Rendering should keep the last valid cache if selection inspection
          # happens during an entity lifecycle transition.
          nil
        end

        def remember_state_group(state, index)
          cell = state&.duality_cell
          group = cell&.valid_sketchup_group
          return unless group

          entry = (@render_state_groups[group.object_id] ||= {
            group: group,
            cell: cell,
            indices: []
          })
          entry[:indices] << index
        rescue StandardError
          nil
        end

        def current_selection_entities
          model = @indoor_model.model if @indoor_model.respond_to?(:model)
          selection = model&.selection
          selection ? selection.to_a : []
        rescue StandardError
          []
        end

        def current_primal_transform_key
          if @transform_context.respond_to?(:overlay_render_context_cache_key)
            @transform_context.overlay_render_context_cache_key
          else
            transformation_key(@indoor_model.primal_group&.transformation)
          end
        rescue StandardError
          nil
        end

        def current_cell_transform_key(cell)
          transformation = if @indoor_model.respond_to?(:reference_cell_space_transformation)
                             @indoor_model.reference_cell_space_transformation(cell.id)
                           else
                             cell&.valid_sketchup_group&.transformation
                           end
          [current_primal_transform_key, transformation_key(transformation)]
        rescue StandardError
          nil
        end

        def transformation_key(transformation)
          return nil unless transformation.respond_to?(:to_a)

          transformation.to_a.map { |value| value.to_f.round(6) }
        end

        def state_root_local_point(state)
          @transform_context.overlay_state_root_local_point(state)
        rescue StandardError
          state.position
        end

        def clear_extent_cache
          @render_state_extent_scale = nil
          @render_state_extent_points = []
        end
      end
    end
  end
end
