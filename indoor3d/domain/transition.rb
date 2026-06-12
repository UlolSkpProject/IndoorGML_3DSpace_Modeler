# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class Transition < AbstractFeature
        attr_reader :state1
        attr_reader :state2
        attr_reader :cell1
        attr_reader :cell2
        attr_reader :state1_id
        attr_reader :state2_id
        attr_reader :cell1_id
        attr_reader :cell2_id
        attr_reader :waypoint_candidates
        attr_reader :selected_waypoint_candidate
        attr_reader :selected_waypoint
        attr_reader :selected_waypoint_normal
        attr_reader :selected_waypoint_normal1
        attr_reader :selected_waypoint_normal2
        attr_accessor :editable

        TRANSITION_RADIUS = State::STATE_NODE_RADIUS * 0.5 unless const_defined?(:TRANSITION_RADIUS, false)
        TRANSITION_BASE_HEIGHT = 1.0 unless const_defined?(:TRANSITION_BASE_HEIGHT, false)

        def initialize(state1 = nil, state2 = nil, _parent_entities = nil, cell1: nil, cell2: nil)
          super()

          @state1 = state1
          @state2 = state2
          @cell1 = cell1
          @cell2 = cell2
          @waypoint_candidates = []
          @selected_waypoint_candidate = nil
          @selected_waypoint = nil
          @selected_waypoint_normal = nil
          @selected_waypoint_normal1 = nil
          @selected_waypoint_normal2 = nil
          capture_reference_ids
          @editable = false
        end

        def update(point1, point2, waypoint_candidates: nil)
          return false unless valid_states?

          candidates = Array(waypoint_candidates).compact
          candidates = [midpoint(point1, point2)] if candidates.empty?
          set_waypoint_candidates(candidates, point1: point1, point2: point2)
          capture_reference_ids
          true
        end

        def set_waypoint_candidates(points, selected_index: 0, point1: nil, point2: nil)
          @waypoint_candidates = Array(points).compact.filter_map { |candidate| normalize_waypoint_candidate(candidate) }
          @selected_waypoint_candidate = shortest_waypoint_candidate(point1, point2) ||
                                         @waypoint_candidates[selected_index.to_i] ||
                                         @waypoint_candidates.first
          @selected_waypoint = @selected_waypoint_candidate&.dig(:point)
          @selected_waypoint_normal1 = @selected_waypoint_candidate&.dig(:normal1)
          @selected_waypoint_normal2 = @selected_waypoint_candidate&.dig(:normal2)
          @selected_waypoint_normal = @selected_waypoint_normal1
        end

        def valid?
          valid_states?
        end

        def connected_to?(state)
          @state1 == state || @state2 == state
        end

        def erase!
          @state1 = nil
          @state2 = nil
          @cell1 = nil
          @cell2 = nil
          @waypoint_candidates = []
          @selected_waypoint_candidate = nil
          @selected_waypoint = nil
          @selected_waypoint_normal = nil
          @selected_waypoint_normal1 = nil
          @selected_waypoint_normal2 = nil
        end

        def self.restore(state1, state2, cell1: nil, cell2: nil, id: nil, name: nil)
          transition = allocate
          transition.send(:initialize_restored, state1, state2, cell1, cell2, id, name)
          transition
        end

        def edge
          nil
        end

        def valid_edge
          entity = edge
          return nil unless entity&.valid?

          entity
        rescue StandardError
          nil
        end

        private

        def initialize_restored(state1, state2, cell1, cell2, id, name)
          @state1 = state1
          @state2 = state2
          @cell1 = cell1
          @cell2 = cell2
          @waypoint_candidates = []
          @selected_waypoint_candidate = nil
          @selected_waypoint = nil
          @selected_waypoint_normal = nil
          @selected_waypoint_normal1 = nil
          @selected_waypoint_normal2 = nil
          capture_reference_ids
          @editable = false
          @id = id unless id.to_s.empty?
          @name = name.to_s
        end

        def midpoint(point1, point2)
          return nil unless point1.is_a?(Geom::Point3d) && point2.is_a?(Geom::Point3d)

          Geom::Point3d.new(
            (point1.x + point2.x) / 2.0,
            (point1.y + point2.y) / 2.0,
            (point1.z + point2.z) / 2.0
          )
        end

        def shortest_waypoint_candidate(point1, point2)
          return nil unless point1.is_a?(Geom::Point3d) && point2.is_a?(Geom::Point3d)
          return nil if @waypoint_candidates.empty?

          @waypoint_candidates.min_by do |candidate|
            waypoint = candidate[:point]
            point1.distance(waypoint) + waypoint.distance(point2)
          end
        end

        def normalize_waypoint_candidate(candidate)
          return { point: candidate, normal: nil } if candidate.is_a?(Geom::Point3d)
          return nil unless candidate.is_a?(Hash)

          point = candidate[:point]
          normal1 = candidate[:normal1] || candidate[:normal]
          normal2 = candidate[:normal2]
          return nil unless point.is_a?(Geom::Point3d)

          { point: point, normal1: normalized_vector(normal1), normal2: normalized_vector(normal2) }
        rescue StandardError
          nil
        end

        def normalized_vector(vector)
          return nil unless vector.is_a?(Geom::Vector3d)

          vector = vector.clone
          vector.normalize! if vector.length > 0.001
          vector
        rescue StandardError
          nil
        end

        def capture_reference_ids
          @state1_id = @state1&.id
          @state2_id = @state2&.id
          @cell1_id = @cell1&.id || @state1&.duality_cell&.id
          @cell2_id = @cell2&.id || @state2&.duality_cell&.id
        end

        def valid_states?
          return false if @state1.nil? || @state2.nil?
          return false if @state1 == @state2
          return false unless @state1.is_a?(State)
          return false unless @state2.is_a?(State)
          return false unless @state1.valid?
          return false unless @state2.valid?

          true
        end
      end

    end
  end
end
