# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/validity/val3dity_overlap_geometry_rechecker'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityOverlapGeometryRecheckerTest < Minitest::Test
          def test_report_ids_resolve_to_the_original_cellspace_entities
            entity1 = FakeEntity.new
            entity2 = FakeEntity.new
            indoor_model = FakeIndoorModel.new(
              [FakeCellSpace.new('A', entity1), FakeCellSpace.new('B', entity2)],
              nil
            )
            rechecker = RecordingRechecker.new(indoor_model: indoor_model, tolerance: 0.001)

            analysis = rechecker.pair_analysis('cell_A', 'cell_B')

            assert_equal :ok, analysis[:status]
            assert_same entity1, analysis[:cell1][:entity]
            assert_same entity2, analysis[:cell2][:entity]
            assert_equal [entity1, entity2], rechecker.face_entities
            assert_equal [[entity1, entity2]], rechecker.intersection_entities
          end

          def test_missing_cellspace_is_reported_without_reading_exported_gml
            indoor_model = FakeIndoorModel.new([FakeCellSpace.new('A', FakeEntity.new)], nil)
            rechecker = RecordingRechecker.new(indoor_model: indoor_model, tolerance: 0.001)

            analysis = rechecker.pair_analysis('cell_A', 'cell_B')

            assert_equal :inconclusive, analysis[:status]
            assert_equal %w[cell_A cell_B], analysis[:cells]
            assert_equal 'CELLSPACE_NOT_FOUND: cell_B', analysis[:reason]
            assert_empty rechecker.intersection_entities
          end

          def test_invalid_cellspace_entity_is_reported_explicitly
            invalid_entity = FakeEntity.new(valid: false)
            indoor_model = FakeIndoorModel.new([FakeCellSpace.new('A', invalid_entity)], nil)
            rechecker = RecordingRechecker.new(indoor_model: indoor_model, tolerance: 0.001)

            analysis = rechecker.pair_analysis('cell_A', 'cell_B')

            assert_equal :inconclusive, analysis[:status]
            assert_equal 'CELLSPACE_ENTITY_INVALID: cell_A', analysis[:reason]
          end

          def test_report_id_mapping_matches_safe_id_and_duplicate_suffix_rules
            entity1 = FakeEntity.new
            entity2 = FakeEntity.new
            indoor_model = FakeIndoorModel.new(
              [FakeCellSpace.new('A B', entity1), FakeCellSpace.new('A?B', entity2)],
              nil
            )
            rechecker = RecordingRechecker.new(indoor_model: indoor_model, tolerance: 0.001)

            first = rechecker.send(:model_cell_geometry, 'cell_A_B')
            second = rechecker.send(:model_cell_geometry, 'cell_A_B_2')

            assert_same entity1, first[:entity]
            assert_same entity2, second[:entity]
          end

          def test_pair_analysis_is_cached_by_sorted_pair
            entity1 = FakeEntity.new
            entity2 = FakeEntity.new
            indoor_model = FakeIndoorModel.new(
              [FakeCellSpace.new('A', entity1), FakeCellSpace.new('B', entity2)],
              nil
            )
            rechecker = RecordingRechecker.new(indoor_model: indoor_model, tolerance: 0.001)

            first = rechecker.pair_analysis('cell_A', 'cell_B')
            second = rechecker.pair_analysis('cell_B', 'cell_A')

            assert_same first, second
            assert_equal [entity1, entity2], rechecker.face_entities
            assert_equal 1, rechecker.intersection_entities.length
          end

          def test_best_candidate_prefers_701_penetration_then_area
            rechecker = Val3dityOverlapGeometryRechecker.new(
              indoor_model: FakeIndoorModel.new([], nil),
              tolerance: 0.001
            )
            candidates = [
              { distance: 0.0, overlap_area: 100.0 },
              { distance: -0.001, overlap_area: 5.0 }
            ]

            assert_equal candidates.last, rechecker.best_candidate(candidates, 701)
            assert_equal candidates.first, rechecker.best_candidate(candidates, 704)
          end

          def test_boolean_uses_original_entities_and_aborts_temporary_result_operation
            model = FakeBooleanModel.new
            group1 = FakeBooleanGroup.new(intersection: nil)
            group2 = FakeBooleanGroup.new(intersection: nil)
            indoor_model = FakeIndoorModel.new([], model)
            rechecker = BooleanRechecker.new(
              indoor_model: indoor_model,
              tolerance: 0.001,
              model: model
            )

            result = rechecker.send(:model_solid_intersection, group1, group2)

            assert_equal :inconclusive, result[:status]
            assert_equal 'BOOLEAN_OPERATION_FAILED', result[:reason]
            assert_same group2, group1.intersected_with
            assert group1.valid?
            assert group2.valid?
            assert_equal 1, model.abort_count
          end

          FakeCellSpace = Struct.new(:id, :sketchup_group)
          FakeIndoorModel = Struct.new(:cell_spaces, :model)

          class FakeEntity
            def initialize(valid: true)
              @valid = valid
            end

            def valid?
              @valid
            end
          end

          class RecordingRechecker < Val3dityOverlapGeometryRechecker
            attr_reader :face_entities, :intersection_entities

            def initialize(**options)
              super
              @face_entities = []
              @intersection_entities = []
            end

            private

            def entity_faces(entity)
              @face_entities << entity
              [{ entity: entity }]
            end

            def shared_face_candidates(*)
              []
            end

            def model_solid_intersection(entity1, entity2)
              @intersection_entities << [entity1, entity2]
              { status: :not_reproduced, reason: 'NO_VALID_INTERSECTION_GROUP_RETURNED' }
            end
          end

          class BooleanRechecker < Val3dityOverlapGeometryRechecker
            private

            def valid_manifold_group?(_group)
              true
            end
          end

          class FakeBooleanModel
            attr_reader :abort_count

            def initialize
              @abort_count = 0
            end

            def start_operation(*)
              true
            end

            def abort_operation
              @abort_count += 1
            end
          end

          class FakeBooleanGroup
            attr_reader :intersected_with

            def initialize(intersection:)
              @intersection = intersection
              @valid = true
            end

            def intersect(other)
              @intersected_with = other
              @intersection
            end

            def valid?
              @valid
            end

            def erase!
              @valid = false
            end
          end
        end
      end
    end
  end
end
