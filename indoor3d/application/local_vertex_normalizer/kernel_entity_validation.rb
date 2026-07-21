# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # ----------------------------------------------------------------------
        # Validation and geometry inventory
        # ----------------------------------------------------------------------

        def valid_entity_definition?(entity)
          entity&.respond_to?(:valid?) && entity.valid? &&
            entity.respond_to?(:definition) && entity.definition&.valid?
        end

        def validate_entity!(entity)
          unless valid_entity_definition?(entity)
            raise ArgumentError, 'Valid SketchUp group or component instance expected'
          end

          return if entity.respond_to?(:manifold?) && entity.manifold? == true

          raise TopologyChangedError,
                "Local vertex normalize requires a manifold solid: #{entity_label(entity)}"
        end

        def validate_rebuilt_entity!(entity, topology)
          valid = entity&.valid? &&
                  entity.respond_to?(:manifold?) && entity.manifold? == true &&
                  closed_topology?(topology)
          return if valid

          raise TopologyChangedError,
                "Local vertex reconstruction damaged topology: " \
                "#{entity_label(entity)} #{topology.inspect}"
        end

        def ensure_unique_definition(entity)
          definition = entity.definition
          return unless definition.respond_to?(:instances)
          return unless Array(definition.instances).length > 1

          if entity.respond_to?(:make_unique)
            entity.make_unique
            return
          end

          raise ArgumentError, 'Shared component definition cannot be normalized independently'
        end

        def geometry_vertices(entities)
          entities.grep(@edge_class).flat_map(&:vertices).uniq
        end

        def geometry_counts(entities)
          edges = entities.grep(@edge_class)
          {
            faces: entities.grep(@face_class).length,
            edges: edges.length,
            vertices: edges.flat_map(&:vertices).uniq.length,
            boundary_edges: edges.count { |edge| edge.faces.length == 1 },
            wire_edges: edges.count { |edge| edge.faces.empty? },
            overused_edges: edges.count { |edge| edge.faces.length > 2 },
            orientation_conflicts: edges.count do |edge|
              next false unless edge.faces.length == 2

              edge.reversed_in?(edge.faces[0]) == edge.reversed_in?(edge.faces[1])
            rescue StandardError
              false
            end
          }
        end

        def closed_topology?(topology)
          closed_surface?(topology) && topology[:orientation_conflicts].to_i.zero?
        end

        def closed_surface?(topology)
          topology[:faces].to_i.positive? &&
            topology[:boundary_edges].to_i.zero? &&
            topology[:wire_edges].to_i.zero? &&
            topology[:overused_edges].to_i.zero?
        end

        def topology_anomaly_score(topology)
          topology[:boundary_edges].to_i +
            topology[:wire_edges].to_i +
            topology[:overused_edges].to_i
        end

        def entity_label(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          persistent_id = entity.respond_to?(:persistent_id) ? entity.persistent_id : nil
          "name=#{name.inspect} persistent_id=#{persistent_id.inspect}"
        rescue StandardError
          entity.class.to_s
        end
      end
    end
  end
end
