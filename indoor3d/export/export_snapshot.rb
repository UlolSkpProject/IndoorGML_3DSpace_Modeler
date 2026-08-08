# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ExportSnapshot
          PointSnapshot = Struct.new(:x, :y, :z, keyword_init: true)
          SurfaceSnapshot = Struct.new(:exterior, :interiors, :id_hint, keyword_init: true)
          StateSnapshot = Struct.new(:id, :position, :duality_cell, :transition_ids, keyword_init: true) do
            def initialize(*args, **kwargs)
              super
              self.transition_ids = Array(transition_ids)
            end

            def valid?
              true
            end
          end
          CellSpaceSnapshot = Struct.new(
            :id,
            :cell_type,
            :storey,
            :duality_state,
            :surfaces,
            :interior_shells,
            :category_code,
            :navigation_class,
            :navigation_class_code_space,
            :navigation_function,
            :navigation_function_code_space,
            :navigation_usage,
            :navigation_usage_code_space,
            keyword_init: true
          )
          TransitionSnapshot = Struct.new(
            :id,
            :state1,
            :state2,
            :state1_position,
            :waypoint_position,
            :state2_position,
            keyword_init: true
          )

          TRANSITION_GEOMETRY_ENDPOINTS = :endpoints
          TRANSITION_GEOMETRY_SHARED_FACE_WAYPOINT = :shared_face_waypoint
          TRANSITION_GEOMETRY_MODES = [
            TRANSITION_GEOMETRY_ENDPOINTS,
            TRANSITION_GEOMETRY_SHARED_FACE_WAYPOINT
          ].freeze

          class UnsupportedCellSpaceGeometryError < ArgumentError; end

          attr_reader :cell_spaces, :transitions

          def self.build(indoor_model:, cell_spaces: nil, transitions: nil,
                         transition_geometry_mode: TRANSITION_GEOMETRY_ENDPOINTS)
            Builder.new(
              indoor_model: indoor_model,
              cell_spaces: cell_spaces,
              transitions: transitions,
              transition_geometry_mode: transition_geometry_mode
            ).build
          end

          def initialize(cell_spaces:, transitions:)
            @cell_spaces = Array(cell_spaces).freeze
            @transitions = Array(transitions).freeze
          end

          class Builder
            def initialize(indoor_model:, cell_spaces:, transitions:, transition_geometry_mode:)
              @indoor_model = indoor_model
              @source_cell_spaces = cell_spaces || indoor_model.cell_spaces
              @source_transitions = transitions || indoor_model.transitions
              @transition_geometry_mode = normalize_transition_geometry_mode(transition_geometry_mode)
            end

            def build
              cell_snapshots_by_source = {}
              cell_snapshots = exportable_cell_spaces.map do |cell_space|
                cell_snapshots_by_source[cell_space] = build_cell_space_snapshot(cell_space)
              end
              transition_ids_by_state = Hash.new { |hash, state| hash[state] = [] }
              transitions = exportable_transitions(cell_snapshots_by_source).map do |transition|
                transition_snapshot = build_transition_snapshot(transition, cell_snapshots_by_source)
                transition_ids_by_state[transition_snapshot.state1] << transition_snapshot.id
                transition_ids_by_state[transition_snapshot.state2] << transition_snapshot.id
                transition_snapshot
              end
              cell_snapshots.each do |cell_snapshot|
                state = cell_snapshot.duality_state
                state.transition_ids = transition_ids_by_state[state].uniq
              end
              ExportSnapshot.new(cell_spaces: cell_snapshots, transitions: transitions)
            end

            private

            def exportable_cell_spaces
              @exportable_cell_spaces ||= Array(@source_cell_spaces).select do |cell_space|
                cell_space&.valid_sketchup_group && cell_space.duality_state&.valid?
              end.uniq
            end

            def exportable_transitions(cell_snapshots_by_source)
              Array(@source_transitions).select do |transition|
                transition&.valid? &&
                  transition.state1&.valid? &&
                  transition.state2&.valid? &&
                  cell_snapshots_by_source.key?(transition.state1.duality_cell) &&
                  cell_snapshots_by_source.key?(transition.state2.duality_cell)
              end.uniq
            end

            def build_cell_space_snapshot(cell_space)
              state = cell_space.duality_state
              group = cell_space.valid_sketchup_group
              geometry = validate_supported_cell_geometry!(cell_space, group)
              cell_snapshot = CellSpaceSnapshot.new(
                id: cell_space.id,
                cell_type: cell_space.cell_type,
                storey: cell_space.storey,
                surfaces: build_surfaces(group, geometry[:exterior_faces]),
                interior_shells: Array(geometry[:interior_face_components]).map do |faces|
                  build_surfaces(group, faces)
                end,
                category_code: value_for(cell_space, :category_code),
                navigation_class: value_for(cell_space, :navigation_class),
                navigation_class_code_space: value_for(cell_space, :navigation_class_code_space),
                navigation_function: value_for(cell_space, :navigation_function),
                navigation_function_code_space: value_for(cell_space, :navigation_function_code_space),
                navigation_usage: value_for(cell_space, :navigation_usage),
                navigation_usage_code_space: value_for(cell_space, :navigation_usage_code_space)
              )
              state_snapshot = StateSnapshot.new(
                id: state.id,
                position: state_export_position(state),
                duality_cell: cell_snapshot
              )
              cell_snapshot.duality_state = state_snapshot
              cell_snapshot
            end

            def build_transition_snapshot(transition, cell_snapshots_by_source)
              state1 = cell_snapshots_by_source.fetch(transition.state1.duality_cell).duality_state
              state2 = cell_snapshots_by_source.fetch(transition.state2.duality_cell).duality_state
              TransitionSnapshot.new(
                id: transition.id,
                state1: state1,
                state2: state2,
                state1_position: transition_point_model_position(transition.state1_point) || state1.position,
                waypoint_position: transition_waypoint_model_position(transition),
                state2_position: transition_point_model_position(transition.state2_point) || state2.position
              )
            end

            def normalize_transition_geometry_mode(value)
              mode = value.to_sym
              return mode if TRANSITION_GEOMETRY_MODES.include?(mode)

              raise ArgumentError, "Unsupported transition_geometry_mode: #{value.inspect}"
            rescue NoMethodError
              raise ArgumentError, "Unsupported transition_geometry_mode: #{value.inspect}"
            end

            def transition_waypoint_model_position(transition)
              return nil unless @transition_geometry_mode == TRANSITION_GEOMETRY_SHARED_FACE_WAYPOINT
              return nil unless transition.respond_to?(:selected_waypoint)

              waypoint = transition_point_model_position(transition.selected_waypoint)
              return nil if same_point?(waypoint, transition_point_model_position(transition.state1_point))
              return nil if same_point?(waypoint, transition_point_model_position(transition.state2_point))

              waypoint
            end

            def same_point?(first, second)
              return false unless first && second

              (first.x.to_f - second.x.to_f).abs <= 1.0e-9 &&
                (first.y.to_f - second.y.to_f).abs <= 1.0e-9 &&
                (first.z.to_f - second.z.to_f).abs <= 1.0e-9
            end

            def validate_supported_cell_geometry!(cell_space, group)
              return {} unless group&.respond_to?(:definition) && defined?(Sketchup::Face)
              return {} unless defined?(Utils::Geometry) && Utils::Geometry.respond_to?(:validate_cell_space_source_group)

              result = Utils::Geometry.validate_cell_space_source_group(group)
              return result if result[:valid]

              reason = result[:reason] || 'unsupported CellSpace solid geometry'
              raise UnsupportedCellSpaceGeometryError,
                    "CellSpace #{cell_space.id} cannot be exported: #{reason}."
            end

            def value_for(object, name)
              object.respond_to?(name) ? object.public_send(name) : nil
            end

            def build_surfaces(group, faces = nil)
              return [] unless group&.respond_to?(:definition) && defined?(Sketchup::Face)

              transform = cell_space_world_transformation(group)
              all_faces = group.definition.entities.grep(Sketchup::Face)
              source_faces = faces || all_faces
              face_indices = all_faces.each_with_index.to_h
              Array(source_faces).map.with_index do |face, index|
                normal = transformed_face_normal(face, transform)
                SurfaceSnapshot.new(
                  exterior: oriented_ring_points(face.outer_loop, transform, normal, true),
                  interiors: interior_rings(face, transform, normal),
                  id_hint: face_indices.fetch(face, index)
                )
              end
            end

            def interior_rings(face, transform, normal)
              face.loops.filter_map do |loop|
                next if loop == face.outer_loop

                oriented_ring_points(loop, transform, normal, false)
              end
            end

            def loop_points(loop, transform)
              loop.vertices.map do |vertex|
                vertex.position.transform(transform)
              end
            end

            def oriented_ring_points(loop, transform, normal, align_with_normal)
              ring = loop_points(loop, transform)
              polygon_normal = Utils::Geometry.polygon_normal(ring, epsilon: 0.000001)
              if normal && polygon_normal
                same_direction = polygon_normal.dot(normal) >= 0.0
                ring.reverse! if same_direction != align_with_normal
              end
              ring << ring.first if ring.first
              ring.map { |point| copy_point(point) }
            end

            def transformed_face_normal(face, transform)
              normal = face.normal.transform(transform)
              return nil if normal.length <= 0.000001

              normal.normalize!
              normal
            end

            def state_export_position(state)
              group = state&.duality_cell&.valid_sketchup_group
              if group
                begin
                  return copy_point(Utils::Transformation.entity_world_transformation_under_root(group, @indoor_model.primal_group).origin)
                rescue StandardError
                  nil
                end
              end

              copy_point(state.position)
            end

            def transition_point_model_position(point)
              return nil unless point
              return copy_point(point) unless defined?(Geom::Point3d) && point.is_a?(Geom::Point3d)

              copy_point(Utils::Transformation.root_local_point_to_model(point, @indoor_model.primal_group))
            rescue StandardError
              copy_point(point)
            end

            def cell_space_world_transformation(group)
              Utils::Transformation.entity_world_transformation_under_root(group, @indoor_model.primal_group)
            end

            def copy_point(point)
              return nil unless point

              PointSnapshot.new(x: point.x, y: point.y, z: point.z)
            end
          end
        end
      end
    end
  end
end
