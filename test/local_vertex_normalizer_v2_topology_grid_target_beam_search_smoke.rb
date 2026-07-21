# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        class TopologyChangedError < StandardError; end

        def initialize
          @tolerance_mm = 0.001
        end

        private

        def topology_grid_target_assignment(*)
          [nil, 7]
        end

        def topology_preserving_grid_target_plan(*)
          { overrides: {}, report: {} }
        end

        def repair_topology_grid_targets(*)
          :ok
        end

        def topology_grid_target_candidates(_source_mm, _constraints, current)
          current == [0, 0, 0] ? [[1, 0, 0]] : []
        end

        def topology_target_collision_signature(_targets)
          []
        end

        def topology_face_embedding_analysis(face, targets)
          keys = face[:loops].flat_map { |loop| loop[:source_keys] }
          valid = keys.all? { |key| targets[key] == [1, 0, 0] }
          {
            valid: valid,
            loops: [{ intersections: [] }],
            cross_loop_intersections: [],
            containment_valid: true,
            issue_counts: valid ? {} : keys.to_h { |key| [key, 1] }
          }
        end

        def topology_grid_target_displacement_mm(_source_mm, target)
          target[0].to_f
        end
      end
    end
  end
end

require_relative '../indoor3d/application/local_vertex_normalizer/topology_grid_target_beam_search_v2'

normalizer =
  ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer.new
keys = (1..6).map { |index| [index.to_f, 0.0, 0.0] }
face_records = [{
  face_key: 100,
  loops: [{ outer: true, source_keys: keys }]
}]
targets = keys.to_h { |key| [key, [0, 0, 0]] }
source_mm = keys.to_h { |key| [key, [0.0, 0.0, 0.0]] }
faces_by_key = keys.to_h { |key| [key, [0]] }
analysis = {
  valid: false,
  issue_counts: keys.to_h { |key| [key, 1] }
}

assignment, attempts = normalizer.send(
  :topology_grid_target_assignment,
  face_records,
  0,
  analysis,
  targets,
  source_mm,
  {},
  faces_by_key,
  []
)

unless assignment && assignment.length == 6
  raise "beam search did not solve >4 correlated vertices: #{assignment.inspect}"
end
unless assignment.values.all? { |target| target == [1, 0, 0] }
  raise "unexpected beam assignment: #{assignment.inspect}"
end
unless attempts > 7
  raise "beam attempts were not included: #{attempts.inspect}"
end

puts 'LocalVertexNormalizer topology grid beam search smoke test: OK'
