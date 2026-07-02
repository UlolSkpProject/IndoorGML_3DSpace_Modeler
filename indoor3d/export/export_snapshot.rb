# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ExportSnapshot
          PointSnapshot = Struct.new(:x, :y, :z, keyword_init: true)
          SurfaceSnapshot = Struct.new(:exterior, :interiors, :id_hint, keyword_init: true)
          StateSnapshot = Struct.new(:id, :position, :duality_cell, keyword_init: true) do
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
            :category_code,
            :category_label,
            :category_code_space,
            :category_standard,
            :navigation_class,
            :navigation_class_code_space,
            :navigation_function,
            :navigation_function_code_space,
            :navigation_usage,
            :navigation_usage_code_space,
            keyword_init: true
          )
          TransitionSnapshot = Struct.new(:id, :state1, :state2, :state1_position, :state2_position, keyword_init: true)

          attr_reader :cell_spaces, :transitions

          def self.build(indoor_model:, cell_spaces: nil, transitions: nil)
            new_builder(indoor_model: indoor_model, cell_spaces: cell_spaces, transitions: transitions).build
          end

          def initialize(cell_spaces:, transitions:)
            @cell_spaces = Array(cell_spaces).freeze
            @transitions = Array(transitions).freeze
          end

          def self.new_builder(indoor_model:, cell_spaces:, transitions:)
            Builder.new(indoor_model: indoor_model, cell_spaces: cell_spaces, transitions: transitions)
          end

          class Builder
            def initialize(indoor_model:, cell_spaces:, transitions:)
              @indoor_model = indoor_model
              @source_cell_spaces = cell_spaces || indoor_model.cell_spaces
              @source_transitions = transitions || indoor_model.transitions
            end

            def build
              cell_snapshots_by_source = {}
              cell_snapshots = exportable_cell_spaces.map do |cell_space|
                cell_snapshots_by_source[cell_space] = build_cell_space_snapshot(cell_space)
              end
              transitions = exportable_transitions(cell_snapshots_by_source).map do |transition|
                build_transition_snapshot(transition, cell_snapshots_by_source)
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
              cell_snapshot = CellSpaceSnapshot.new(
                id: cell_space.id,
                cell_type: cell_space.cell_type,
                storey: cell_space.storey,
                surfaces: build_surfaces(group),
                category_code: value_for(cell_space, :category_code),
                category_label: value_for(cell_space, :category_label),
                category_code_space: value_for(cell_space, :category_code_space),
                category_standard: value_for(cell_space, :category_standard),
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
                state2_position: transition_point_model_position(transition.state2_point) || state2.position
              )
            end

            def value_for(object, name)
              object.respond_to?(name) ? object.public_send(name) : nil
            end

            def build_surfaces(group)
              return [] unless group&.respond_to?(:definition) && defined?(Sketchup::Face)

              transform = cell_space_world_transformation(group)
              group.definition.entities.grep(Sketchup::Face).map.with_index do |face, index|
                normal = transformed_face_normal(face, transform)
                SurfaceSnapshot.new(
                  exterior: oriented_ring_points(face.outer_loop, transform, normal, true),
                  interiors: interior_rings(face, transform, normal),
                  id_hint: index
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
              polygon_normal = polygon_normal(ring)
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

            def polygon_normal(points)
              return nil if points.length < 3

              x = 0.0
              y = 0.0
              z = 0.0
              points.each_with_index do |point, index|
                next_point = points[(index + 1) % points.length]
                x += (point.y - next_point.y) * (point.z + next_point.z)
                y += (point.z - next_point.z) * (point.x + next_point.x)
                z += (point.x - next_point.x) * (point.y + next_point.y)
              end
              normal = Geom::Vector3d.new(x, y, z)
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
              return nil unless defined?(Geom::Point3d) && point.is_a?(Geom::Point3d)

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
