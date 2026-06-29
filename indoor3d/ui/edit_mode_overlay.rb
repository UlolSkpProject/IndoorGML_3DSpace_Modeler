# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditModeOverlay < Sketchup::Overlay
        OVERLAY_ID = 'ulol.indoor3dgml_modeler.edit_mode_overlay'
        OVERLAY_NAME = 'IndoorGML Edit Mode'
        TITLE = 'EDIT MODE - INDOOR GML'
        FIX_TITLE = 'FIX MODE - INDOOR GML'
        HINT_LABEL = 'Cellspace editing active'
        FIX_HINT_LABEL = 'Validation error fixing active'
        PRIMARY_COLOR = Sketchup::Color.new(22, 130, 82, 255)
        PRIMARY_TRANSLUCENT_COLOR = Sketchup::Color.new(22, 130, 82, 210)
        FIX_PRIMARY_COLOR = Sketchup::Color.new(185, 28, 28, 255)
        FIX_PRIMARY_TRANSLUCENT_COLOR = Sketchup::Color.new(185, 28, 28, 210)
        HINT_COLOR = Sketchup::Color.new(214, 245, 229)
        FIX_HINT_COLOR = Sketchup::Color.new(254, 226, 226)
        DUAL_STATE_COLOR = Sketchup::Color.new(35, 120, 255, 255)
        DUAL_TRANSITION_COLOR = Sketchup::Color.new(255, 255, 255, 220)
        PROGRESS_BACKDROP_COLOR = Sketchup::Color.new(17, 24, 39, 220)
        PROGRESS_TRACK_COLOR = Sketchup::Color.new(75, 85, 99, 220)
        PROGRESS_FILL_COLOR = Sketchup::Color.new(22, 130, 82, 235)
        PROGRESS_TEXT_COLOR = Sketchup::Color.new(255, 255, 255, 255)
        STATE_CIRCLE_SEGMENTS = 8
        UNIT_CIRCLE = (0...STATE_CIRCLE_SEGMENTS).map do |i|
          angle = (2.0 * Math::PI * i) / STATE_CIRCLE_SEGMENTS
          [Math.cos(angle), Math.sin(angle)]
        end.freeze
        OVERLAY_RADIUS_SCALE = 1.0
        OVERLAY_MIN_RADIUS_PIXELS = 1.0
        OVERLAY_MAX_RADIUS_PIXELS = 7.0
        TRANSITION_DEPTH_OFFSET_PIXELS = 2.0
        TRANSITION_MIN_CURVE_SEGMENTS = 3
        TRANSITION_RIGHT_ANGLE_CURVE_SEGMENTS = 6
        TRANSITION_CURVE_SEGMENTS = 9
        MIN_TRANSITION_CURVE_CACHE_LIMIT = 2048

        def initialize(indoor_model)
          @indoor_model = indoor_model
          @transition_curve_cache = {}
          @world_transition_line_points = nil
          @world_transition_line_points_key = nil
          @transition_draw_points = []
          super(OVERLAY_ID, OVERLAY_NAME, description: 'Shows when IndoorGML editing is active.')
        end

        def invalidate_transition_points
          @transition_curve_cache&.clear
          @world_transition_line_points = nil
          @world_transition_line_points_key = nil
          @transition_draw_points&.clear
        end

        def draw(view)
          begin
            return unless @indoor_model.editing?() || @indoor_model.dual_overlay_visible?() || @indoor_model.progress_active?()

            if @indoor_model.editing?()
              draw_screen_border(view)
              draw_banner(view)
            end
            draw_dual_space_overlay(view) if draw_dual_overlay?
            draw_progress_bar(view) if @indoor_model.progress_active?()
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode overlay draw failed: #{e.class}: #{e.message}"
          end
        end

        def getExtents
          begin
            bounds = Geom::BoundingBox.new
            add_dual_overlay_bounds(bounds) if draw_dual_overlay?
            bounds
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode overlay extents failed: #{e.class}: #{e.message}"
            Geom::BoundingBox.new
          end
        end

        private

        def draw_dual_overlay?
          return false unless renderable_active_context?
          return false if @indoor_model.respond_to?(:cell_space_geometry_editing?) && @indoor_model.cell_space_geometry_editing?()

          @indoor_model.editing?() || @indoor_model.dual_overlay_visible?()
        end

        def add_dual_overlay_bounds(bounds)
          @indoor_model.states.each do |state|
            next unless state&.valid?()
            next unless overlay_state_visible?(state)

            point = overlay_state_point(state)
            radius = (state.radius || State.display_radius) * OVERLAY_RADIUS_SCALE
            bounds.add(
              Geom::Point3d.new(point.x - radius, point.y - radius, point.z - radius),
              Geom::Point3d.new(point.x + radius, point.y + radius, point.z + radius)
            )
          end
        end

        def draw_banner(view)
          w = view.vpwidth()
          h = 56
          draw_2d_quad(
            view,
            [
              [0, 0, 0],
              [w, 0, 0],
              [w, h, 0],
              [0, h, 0]
            ],
            screen_overlay_translucent_color
          )

          view.draw_text(
            Geom::Point3d.new(18, 13, 0),
            screen_overlay_title,
            text_options(size: 18, bold: true, color: Sketchup::Color.new(255, 255, 255))
          )
          view.draw_text(
            Geom::Point3d.new(18, 34, 0),
            screen_overlay_hint,
            text_options(size: 11, bold: false, color: screen_overlay_hint_color)
          )
        end

        def draw_screen_border(view)
          w = view.vpwidth()
          h = view.vpheight()
          t = 4
          c = screen_overlay_color
          draw_2d_quads(
            view,
            [
              [[0, 0, 0], [w, 0, 0], [w, t, 0], [0, t, 0]],
              [[0, h - t, 0], [w, h - t, 0], [w, h, 0], [0, h, 0]],
              [[0, 0, 0], [t, 0, 0], [t, h, 0], [0, h, 0]],
              [[w - t, 0, 0], [w, 0, 0], [w, h, 0], [w - t, h, 0]]
            ],
            c
          )
        end

        def draw_dual_space_overlay(view)
          begin
            draw_overlay_transitions(view)
            draw_overlay_states(view)
          ensure
            view.line_width = 1 if view.respond_to?(:line_width=)
          end
        end

        def draw_progress_bar(view)
          width = view.vpwidth()
          height = view.vpheight()
          panel_width = [[width - 48, 460].min, 220].max
          panel_height = 56
          x = ((width - panel_width) / 2.0).round
          y = height - panel_height - 28
          padding = 12
          bar_height = 10
          bar_width = panel_width - (padding * 2)
          bar_x = x + padding
          bar_y = y + panel_height - padding - bar_height
          total = [@indoor_model.progress_total, 1].max
          current = [[@indoor_model.progress_current, 0].max, total].min
          ratio = current.to_f / total
          fill_width = (bar_width * ratio).round

          draw_2d_quad(
            view,
            [
              [x, y, 0],
              [x + panel_width, y, 0],
              [x + panel_width, y + panel_height, 0],
              [x, y + panel_height, 0]
            ],
            PROGRESS_BACKDROP_COLOR
          )
          draw_2d_quad(
            view,
            [
              [bar_x, bar_y, 0],
              [bar_x + bar_width, bar_y, 0],
              [bar_x + bar_width, bar_y + bar_height, 0],
              [bar_x, bar_y + bar_height, 0]
            ],
            PROGRESS_TRACK_COLOR
          )
          if fill_width.positive?
            draw_2d_quad(
              view,
              [
                [bar_x, bar_y, 0],
                [bar_x + fill_width, bar_y, 0],
                [bar_x + fill_width, bar_y + bar_height, 0],
                [bar_x, bar_y + bar_height, 0]
              ],
              PROGRESS_FILL_COLOR
            )
          end
          view.draw_text(
            Geom::Point3d.new(x + padding, y + 9, 0),
            "#{@indoor_model.progress_message} #{current}/#{total}",
            text_options(size: 11, bold: true, color: PROGRESS_TEXT_COLOR)
          )
        end

        def draw_overlay_states(view)
          view.drawing_color = DUAL_STATE_COLOR
          right_axis, up_axis = camera_billboard_axes(view)
          points = []
          @indoor_model.states.each do |state|
            next unless state&.valid?()
            next unless overlay_state_visible?(state)

            center = offset_state_point_in_front_of_transitions(view, overlay_state_point(state))
            radius = overlay_state_radius(view, center, state)
            points.concat(billboard_disk_triangle_points(center, right_axis, up_axis, radius))
          end
          view.draw(GL_TRIANGLES, points) unless points.empty?
        end

        def draw_overlay_transitions(view)
          return if @indoor_model.respond_to?(:validation_focus_active?) && @indoor_model.validation_focus_active?

          view.line_width = overlay_transition_line_width if view.respond_to?(:line_width=)
        
          camera_direction = view.camera.direction.clone
          camera_direction.normalize!
          depth_distance = view.pixels_to_model(TRANSITION_DEPTH_OFFSET_PIXELS, Geom::Point3d.new(0, 0, 0))
          world_points = transition_line_points
          return if world_points.empty?

          points = offset_transition_line_points(world_points, camera_direction, depth_distance)
          view.drawing_color = DUAL_TRANSITION_COLOR
          view.draw(GL_LINES, points)
        end

        def transition_line_points
          cache_key = transition_line_points_cache_key
          if @world_transition_line_points.nil? || @world_transition_line_points_key != cache_key
            @world_transition_line_points = build_world_transition_line_points
            @world_transition_line_points_key = cache_key
          end
          @world_transition_line_points
        end

        def transition_line_points_cache_key
          primal_group = @indoor_model.primal_group
          return nil unless primal_group&.valid?

          rounded_transform_key(primal_group.transformation)
        end

        def build_world_transition_line_points
          primal_tf = @indoor_model.primal_group&.valid? ? @indoor_model.primal_group.transformation : nil
          points = []
          @indoor_model.transitions.each do |transition|
            next unless transition&.valid?()
            next unless transition.state1&.valid?() && transition.state2&.valid?()
            next unless overlay_transition_visible?(transition)
        
            segments = transition_curve_segments(transition, primal_tf)
            points.concat(segments[:default])
            points.concat(segments[:first])
            points.concat(segments[:second])
          end
          points
        end

        def overlay_state_visible?(state)
          if @indoor_model.respond_to?(:dual_overlay_state_visible?)
            return @indoor_model.dual_overlay_state_visible?(state)
          end

          return true unless @indoor_model.respond_to?(:validation_focus_active?)
          return true unless @indoor_model.validation_focus_active?

          @indoor_model.validation_focus_state?(state)
        rescue StandardError
          false
        end

        def overlay_transition_visible?(transition)
          if @indoor_model.respond_to?(:dual_overlay_transition_visible?)
            return @indoor_model.dual_overlay_transition_visible?(transition)
          end

          overlay_state_visible?(transition.state1) && overlay_state_visible?(transition.state2)
        rescue StandardError
          false
        end

        def validation_focus_active?
          @indoor_model.respond_to?(:validation_focus_active?) && @indoor_model.validation_focus_active?
        end

        def screen_overlay_color
          validation_focus_active? ? FIX_PRIMARY_COLOR : PRIMARY_COLOR
        end

        def screen_overlay_translucent_color
          validation_focus_active? ? FIX_PRIMARY_TRANSLUCENT_COLOR : PRIMARY_TRANSLUCENT_COLOR
        end

        def screen_overlay_title
          validation_focus_active? ? FIX_TITLE : TITLE
        end

        def screen_overlay_hint
          validation_focus_active? ? FIX_HINT_LABEL : HINT_LABEL
        end

        def screen_overlay_hint_color
          validation_focus_active? ? FIX_HINT_COLOR : HINT_COLOR
        end

        def overlay_state_radius(view, center, state)
          degree_scale = overlay_state_degree_scale(state)
          model_radius = (state.radius || State.display_radius) * OVERLAY_RADIUS_SCALE * degree_scale
          clamp_overlay_radius(view, center, model_radius, pixel_scale: degree_scale)
        end

        def overlay_state_degree_scale(state)
          transition_count = state.transitions.count { |transition| transition&.valid? }
          scale = 1.0 + (Math.sqrt([transition_count - 1, 0].max) * 0.12)
          [scale, 1.45].min
        end

        def overlay_transition_line_width
          [(OVERLAY_MIN_RADIUS_PIXELS * 1.25).round, 2].max
        end

        def transition_curve_segments(transition, primal_tf)
          control_points = []
          curve_input = transition_curve_input(transition, primal_tf)
          control_points = curve_input[:points]
          return empty_transition_segment_groups if control_points.length < 2
        
          curve_point_groups = cached_transition_curve_point_groups(transition, curve_input)
          {
            default: polyline_segments(curve_point_groups[:default]),
            first:   polyline_segments(curve_point_groups[:first]),
            second:  polyline_segments(curve_point_groups[:second])
          }
        rescue StandardError => e
          IndoorCore::Logger.puts "[IndoorGML] Transition curve draw failed: #{e.class}: #{e.message}"
          { default: polyline_segments(control_points || []), first: [], second: [] }
        end

        def empty_transition_segment_groups
          { default: [], first: [], second: [] }
        end

        def cached_transition_curve_point_groups(transition, curve_input)
          control_points = curve_input[:points]
          return { default: control_points, first: [], second: [] } if control_points.length < 3

          @transition_curve_cache ||= {}
          key = transition_curve_cache_key(transition, curve_input)
          cached = @transition_curve_cache[key]
          return cached if cached

          @transition_curve_cache.clear if @transition_curve_cache.length > transition_curve_cache_limit
          groups = curve_input[:normal1] && curve_input[:normal2] ?
            hermite_transition_curve_point_groups(control_points, curve_input[:normal1], curve_input[:normal2]) :
            { default: control_points, first: [], second: [] }
          @transition_curve_cache[key] = groups
          groups
        end

        def transition_curve_cache_key(transition, curve_input)
          [
            transition.id,
            curve_input[:points].map { |point| rounded_point_key(point) },
            rounded_vector_key(curve_input[:normal1]),
            rounded_vector_key(curve_input[:normal2])
          ]
        rescue StandardError
          [transition.id, Time.now.to_f]
        end

        def rounded_point_key(point)
          return nil unless point.is_a?(Geom::Point3d)

          [point.x.to_f.round(6), point.y.to_f.round(6), point.z.to_f.round(6)]
        end

        def rounded_vector_key(vector)
          return nil unless vector.is_a?(Geom::Vector3d)

          [vector.x.to_f.round(6), vector.y.to_f.round(6), vector.z.to_f.round(6)]
        end

        def rounded_transform_key(transformation)
          return nil unless transformation.respond_to?(:to_a)

          transformation.to_a.map { |value| value.to_f.round(6) }
        end

        def transition_curve_cache_limit
          transition_count = @indoor_model.transitions.length
          [transition_count * 2, MIN_TRANSITION_CURVE_CACHE_LIMIT].max
        rescue StandardError
          MIN_TRANSITION_CURVE_CACHE_LIMIT
        end

        def hermite_transition_curve_point_groups(control_points, normal1, normal2)
          return { default: control_points, first: [], second: [] } unless control_points.length == 3

          point1, waypoint, point2 = control_points
          unless normal1.is_a?(Geom::Vector3d) && normal1.length > 0.001 &&
                 normal2.is_a?(Geom::Vector3d) && normal2.length > 0.001
            return { default: control_points, first: [], second: [] }
          end

          dir1 = point1.vector_to(waypoint)
          dir2 = point2.vector_to(waypoint)
          tangent1_mag = dir1.length
          tangent2_mag = dir2.length
          return { default: control_points, first: [], second: [] } if tangent1_mag <= 0.001 || tangent2_mag <= 0.001

          first_waypoint_tangent = scaled_normal(normal1, tangent1_mag * tangent_angle_weight(dir1, normal1))
          second_waypoint_tangent = scaled_normal(normal2, tangent2_mag * tangent_angle_weight(dir2, normal2))

          first_start_tangent = scaled_vector(point1, waypoint, 2.0)
          first_end_tangent = first_waypoint_tangent
          second_start_tangent = scaled_vector(point2, waypoint, 2.0)
          second_end_tangent = second_waypoint_tangent
          first_segment_count = transition_curve_segment_count(dir1, normal1)
          second_segment_count = transition_curve_segment_count(dir2, normal2)

          first_segment = Utils::Math::HermiteSpline.generate_segment(
            point1,
            waypoint,
            first_start_tangent,
            first_end_tangent,
            first_segment_count
          )
          second_segment = Utils::Math::HermiteSpline.generate_segment(
            point2,
            waypoint,
            second_start_tangent,
            second_end_tangent,
            second_segment_count
          )
          { default: [], first: first_segment, second: second_segment }
        end

        def scaled_normal(normal, magnitude)
          tangent = normal.clone
          tangent.normalize!
          tangent.length = magnitude
          tangent
        end

        def tangent_angle_weight(direction, normal)
          dir = direction.clone
          norm = normal.clone
          dir.normalize!
          norm.normalize!
          dot = [[dir.dot(norm), -1.0].max, 1.0].min
          0.55 - (0.45 * dot)
        end

        def transition_curve_segment_count(direction, waypoint_direction)
          angle = vector_angle_degrees(direction, waypoint_direction)
          return TRANSITION_CURVE_SEGMENTS if angle.nil?

          segments =
            if angle <= 90.0
              TRANSITION_MIN_CURVE_SEGMENTS +
                ((angle / 90.0) * (TRANSITION_RIGHT_ANGLE_CURVE_SEGMENTS - TRANSITION_MIN_CURVE_SEGMENTS))
            else
              TRANSITION_RIGHT_ANGLE_CURVE_SEGMENTS -
                (((angle - 90.0) / 90.0) * (TRANSITION_RIGHT_ANGLE_CURVE_SEGMENTS - TRANSITION_CURVE_SEGMENTS))
            end
          segments.round.clamp(TRANSITION_MIN_CURVE_SEGMENTS, TRANSITION_CURVE_SEGMENTS)
        end

        def vector_angle_degrees(vector1, vector2)
          return nil unless vector1.is_a?(Geom::Vector3d) && vector2.is_a?(Geom::Vector3d)
          return nil if vector1.length <= 0.001 || vector2.length <= 0.001

          first = vector1.clone
          second = vector2.clone
          first.normalize!
          second.normalize!
          dot = [[first.dot(second), -1.0].max, 1.0].min
          Math.acos(dot) * 180.0 / Math::PI
        end

        def scaled_vector(from, to, scale)
          vector = from.vector_to(to)
          vector.length = vector.length * scale if vector.length > 0.001
          vector
        end

        def transition_curve_input(transition, primal_tf)
          point1 = overlay_state_point_with_tf(transition.state1, primal_tf)
          point2 = overlay_state_point_with_tf(transition.state2, primal_tf)
          return { points: [], normal1: nil, normal2: nil } if point1.distance(point2) <= 0.001

          waypoint = overlay_transition_waypoint_with_tf(transition.selected_waypoint, primal_tf)
          points = waypoint ? [point1, waypoint, point2] : [point1, point2]
          {
            points: points,
            normal1: overlay_transition_normal_with_tf(transition.selected_waypoint_normal1, primal_tf),
            normal2: overlay_transition_normal_with_tf(transition.selected_waypoint_normal2, primal_tf)
          }
        end

        def overlay_state_point_with_tf(state, primal_tf)
          point = state.position
          return point.transform(primal_tf) if primal_tf
          point
        rescue StandardError
          state.position
        end

        def overlay_transition_waypoint_with_tf(point, primal_tf)
          return nil unless point.is_a?(Geom::Point3d)
          return point.transform(primal_tf) if primal_tf
          point
        rescue StandardError
          point
        end

        def overlay_transition_normal_with_tf(vector, primal_tf)
          return nil unless vector.is_a?(Geom::Vector3d)

          normal = primal_tf ? vector.transform(primal_tf) : vector.clone
          return nil unless normal.is_a?(Geom::Vector3d)

          normal.normalize! if normal.length > 0.001
          normal
        rescue StandardError
          nil
        end

        def offset_transition_line_points(points, camera_direction, depth_distance)
          @transition_draw_points ||= []
          @transition_draw_points.clear
          points.each do |point|
            @transition_draw_points << Geom::Point3d.new(
              point.x + (camera_direction.x * depth_distance),
              point.y + (camera_direction.y * depth_distance),
              point.z + (camera_direction.z * depth_distance)
            )
          end
          @transition_draw_points
        end

        def polyline_segments(points)
          points.each_cons(2).flat_map do |from, to|
            # next [] if from.distance(to) <= 0.001
            [from, to]
          end
        end

        def offset_state_point_in_front_of_transitions(view, point)
          direction = view.camera.direction.clone
          direction.normalize!
          distance = view.pixels_to_model(TRANSITION_DEPTH_OFFSET_PIXELS, point)
          Geom::Point3d.new(
            point.x - (direction.x * distance),
            point.y - (direction.y * distance),
            point.z - (direction.z * distance)
          )
        rescue StandardError
          point
        end

        def renderable_active_context?
          path = Sketchup.active_model&.active_path
          return true if path.nil?
          return false unless path.length == 1

          primal_group = @indoor_model.primal_group
          primal_group&.valid? && path.first == primal_group
        rescue StandardError
          false
        end

        def clamp_overlay_radius(view, center, model_radius, pixel_scale: 1.0)
          screen_min_radius = view.pixels_to_model(OVERLAY_MIN_RADIUS_PIXELS * pixel_scale, center)
          screen_max_radius = view.pixels_to_model(OVERLAY_MAX_RADIUS_PIXELS * pixel_scale, center)
          [[model_radius, screen_min_radius].max, screen_max_radius].min
        end

        def billboard_disk_triangle_points(center, right_axis, up_axis, radius)
          points = UNIT_CIRCLE.map do |cos_a, sin_a|
            Geom::Point3d.new(
              center.x + (right_axis.x * cos_a * radius) + (up_axis.x * sin_a * radius),
              center.y + (right_axis.y * cos_a * radius) + (up_axis.y * sin_a * radius),
              center.z + (right_axis.z * cos_a * radius) + (up_axis.z * sin_a * radius)
            )
          end
          points.each_with_index.flat_map do |point, index|
            [center, point, points[(index + 1) % STATE_CIRCLE_SEGMENTS]]
          end
        end


        def camera_billboard_axes(view)
          up_axis = view.camera.up.clone
          up_axis.normalize!
          right_axis = view.camera.direction.cross(up_axis)
          right_axis.normalize!
          [right_axis, up_axis]
        end

        def overlay_state_point(state)
          point = state.position
          primal_group = @indoor_model.primal_group
          return point.transform(primal_group.transformation) if primal_group&.valid?

          point
        rescue StandardError
          state.position
        end

        def draw_2d_quad(view, points, color)
          draw_2d_quads(view, [points], color)
        end

        def draw_2d_quads(view, quads, color)
          view.drawing_color = color
          points = quads.flatten(1).map { |point| Geom::Point3d.new(*point) }
          view.draw2d(GL_QUADS, points) unless points.empty?
        end

        def text_options(size:, bold:, color:)
          {
            size: size,
            bold: bold,
            color: color
          }
        end
      end

    end
  end
end
