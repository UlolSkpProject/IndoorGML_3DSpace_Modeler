# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Reference-point diagnostic overlay for Room candidates, representatives,
      # and final Reference Points.
      class ReferencePointDebugOverlayRenderer
        POINT_COLORS = {
          0 => Sketchup::Color.new(255, 140, 0),  # Unclassified reference
          1 => Sketchup::Color.new(40, 220, 100), # Face midpoint: green
          2 => Sketchup::Color.new(175, 95, 240), # Corner bisector: purple
          3 => Sketchup::Color.new(235, 60, 60),  # Cluster centroid: red
          4 => Sketchup::Color.new(0, 0, 0),      # Final reference: black
          5 => Sketchup::Color.new(235, 20, 145)  # Protected reference: magenta X
        }.freeze
        REFERENCE_POINT_SIZE_PIXELS = 8
        REFERENCE_POINT_STYLE = 2
        FINAL_REFERENCE_POINT_KIND = 4
        # The requested SketchUp draw_points style (STATE_POINT_STYLE = 5).
        FINAL_REFERENCE_POINT_STYLE = 5
        PROTECTED_REFERENCE_POINT_KIND = 5
        PROTECTED_REFERENCE_POINT_SIZE_PIXELS = 14
        PROTECTED_REFERENCE_POINT_STYLE = 4 # SketchUp X glyph

        def initialize(indoor_model:, transform_context:)
          @indoor_model = indoor_model
          @transform_context = transform_context
        end

        def draw(view)
          grouped = render_points_by_kind

          # Diagnostic candidates first; final points on top.
          grouped.each do |kind, points|
            next if kind == FINAL_REFERENCE_POINT_KIND ||
                    kind == PROTECTED_REFERENCE_POINT_KIND || points.empty?

            view.draw_points(
              points,
              REFERENCE_POINT_SIZE_PIXELS,
              REFERENCE_POINT_STYLE,
              POINT_COLORS.fetch(kind, POINT_COLORS[0])
            )
          end

          final_points = Array(grouped[FINAL_REFERENCE_POINT_KIND])
          unless final_points.empty?
            view.draw_points(
              final_points,
              REFERENCE_POINT_SIZE_PIXELS,
              FINAL_REFERENCE_POINT_STYLE,
              POINT_COLORS.fetch(FINAL_REFERENCE_POINT_KIND)
            )
          end

          # Overlay protected nodes last so their X markers stay visible
          # without altering State, graph topology or original diagnostics.
          protected_points = Array(grouped[PROTECTED_REFERENCE_POINT_KIND])
          return if protected_points.empty?

          view.draw_points(
            protected_points,
            PROTECTED_REFERENCE_POINT_SIZE_PIXELS,
            PROTECTED_REFERENCE_POINT_STYLE,
            POINT_COLORS.fetch(PROTECTED_REFERENCE_POINT_KIND)
          )
        end

        def extent_points
          points = render_points_by_kind.values.flatten
          return [] if points.empty?

          xs = points.map(&:x)
          ys = points.map(&:y)
          zs = points.map(&:z)
          [
            Geom::Point3d.new(xs.min, ys.min, zs.min),
            Geom::Point3d.new(xs.max, ys.max, zs.max)
          ]
        end

        private

        def render_points_by_kind
          grouped = @indoor_model.debug_reference_points_by_kind
          visible_cell_ids = visible_debug_cell_ids
          grouped.each_with_object({}) do |(kind, owned_points), result|
            result[kind] = Array(owned_points).flat_map do |record|
              next [] unless record.is_a?(Hash) && record[:cell_id] && record[:point]
              next [] unless debug_cell_visible?(record[:cell_id], visible_cell_ids)

              @transform_context.overlay_cell_reference_points(
                [record[:point]], record[:cell_id]
              )
            end
          end
        rescue StandardError
          {}
        end

        def visible_debug_cell_ids
          return nil unless @indoor_model.respond_to?(:cell_spaces) &&
                            @indoor_model.respond_to?(:dual_overlay_state_visible?)

          Array(@indoor_model.cell_spaces).each_with_object({}) do |cell_space, visible|
            next unless cell_space
            next unless @indoor_model.dual_overlay_state_visible?(cell_space.duality_state)

            visible[cell_space.id.to_s] = true
          end
        rescue StandardError
          {}
        end

        def debug_cell_visible?(cell_id, visible_cell_ids)
          visible_cell_ids.nil? || visible_cell_ids[cell_id.to_s] == true
        end
      end
    end
  end
end
