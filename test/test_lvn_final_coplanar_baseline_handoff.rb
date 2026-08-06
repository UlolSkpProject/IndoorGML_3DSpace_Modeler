# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class Edge; end unless const_defined?(:Edge, false)
  class Face; end unless const_defined?(:Face, false)
end

require_relative '../indoor3d/application/local_vertex_normalizer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizerFinalCoplanarBaselineHandoffTest < Minitest::Test
        class FakeEntity
          attr_reader :definition

          def initialize(entities, manifold: true)
            @definition = Struct.new(:entities).new(entities)
            @manifold = manifold
          end

          def manifold?
            @manifold
          end
        end

        class ProbeNormalizer
          GRID_EPSILON_MM = 1.0e-6

          prepend LocalVertexNormalizerFinalCoplanarBaselineHandoff

          attr_reader :fallback_calls,
                      :selected_baseline,
                      :local_vertex_normalizer_diagnostic_profile

          def initialize(mode: :full, role: :post_coplanar_cleanup)
            @mode = mode
            @role = role
            @triangles = [{ points: [1, 2, 3] }]
            @fallback = [{ points: [7, 8, 9] }]
            @topology = closed_topology
            @current_topology = @topology.dup
            @current_residual = 0.0
            @fallback_calls = 0
            @mutate_topology_after_capture = false
            @mutate_residual_after_capture = false
          end

          def mutate_topology_after_capture!
            @mutate_topology_after_capture = true
          end

          def mutate_residual_after_capture!
            @mutate_residual_after_capture = true
          end

          def fail_inner!
            @mode = :raise
          end

          def enable_diagnostic_profile!
            @local_vertex_normalizer_diagnostic_profile = {}
          end

          private

          def normalize_entity(entity)
            entities = entity.definition.entities
            case @mode
            when :full
              final_normalized_mesh_state(
                entities,
                nil,
                nil,
                @topology.dup,
                nil,
                nil
              )
            when :fast
              try_normalized_input_fast_path(entity)
            when :raise
              raise 'inner failure'
            end

            if @mutate_topology_after_capture
              @current_topology = @topology.merge(edges: @topology[:edges] + 1)
            end
            @current_residual = 5.0e-7 if @mutate_residual_after_capture

            @selected_baseline = snapshot_final_coplanar_baseline(entities)
            { completed: true }
          end

          def final_normalized_mesh_state(*_arguments)
            reuse = @role == :post_coplanar_cleanup
            [
              @triangles,
              {},
              { valid: true },
              { equivalent: true },
              { reused: reuse }
            ]
          end

          def try_normalized_input_fast_path(entity)
            entities = entity.definition.entities
            @normalized_input_fast_path_baseline = {
              entities_object_id: entities.object_id,
              topology: @topology.dup,
              triangles: @triangles
            }
            { fast_path: true }
          end

          def snapshot_final_coplanar_baseline(_entities)
            @fallback_calls += 1
            @fallback
          end

          def geometry_counts(_entities)
            @current_topology.dup
          end

          def geometry_vertices(_entities)
            []
          end

          def max_grid_residual_mm(_vertices)
            @current_residual
          end

          def closed_topology?(topology)
            topology[:boundary_edges].zero? &&
              topology[:wire_edges].zero? &&
              topology[:overused_edges].zero? &&
              topology[:orientation_conflicts].zero?
          end

          def closed_topology
            {
              faces: 8,
              edges: 18,
              vertices: 12,
              boundary_edges: 0,
              wire_edges: 0,
              overused_edges: 0,
              orientation_conflicts: 0
            }
          end
        end

        def test_full_pipeline_reuses_current_validated_snapshot
          subject = ProbeNormalizer.new
          report = subject.send(:normalize_entity, entity)

          assert_equal 0, subject.fallback_calls
          assert_equal [{ points: [1, 2, 3] }], subject.selected_baseline
          handoff = report.fetch(:final_coplanar_baseline_handoff)
          assert handoff[:reused]
          assert_equal :post_coplanar_cleanup, handoff[:role]
          assert handoff[:exact_hard_gate_preserved]
          assert handoff[:fallback_snapshot_preserved]
        end

        def test_final_fallback_snapshot_is_also_reused
          subject = ProbeNormalizer.new(role: :final_fallback)
          report = subject.send(:normalize_entity, entity)

          assert_equal 0, subject.fallback_calls
          assert report.dig(:final_coplanar_baseline_handoff, :reused)
          assert_equal :final_fallback,
                       report.dig(:final_coplanar_baseline_handoff, :role)
        end

        def test_normalized_input_fast_path_snapshot_is_reused
          subject = ProbeNormalizer.new(mode: :fast)
          report = subject.send(:normalize_entity, entity)

          assert_equal 0, subject.fallback_calls
          assert report.dig(:final_coplanar_baseline_handoff, :reused)
          assert_equal :normalized_input_fast_path,
                       report.dig(:final_coplanar_baseline_handoff, :role)
        end

        def test_topology_change_forces_existing_snapshot_fallback
          subject = ProbeNormalizer.new
          subject.mutate_topology_after_capture!
          report = subject.send(:normalize_entity, entity)

          assert_equal 1, subject.fallback_calls
          assert_equal [{ points: [7, 8, 9] }], subject.selected_baseline
          handoff = report.fetch(:final_coplanar_baseline_handoff)
          refute handoff[:reused]
          assert_includes handoff[:rejection_reasons], :topology_changed
          assert handoff[:fallback_snapshot_available]
        end

        def test_grid_residual_change_forces_existing_snapshot_fallback
          subject = ProbeNormalizer.new
          subject.mutate_residual_after_capture!
          report = subject.send(:normalize_entity, entity)

          assert_equal 1, subject.fallback_calls
          handoff = report.fetch(:final_coplanar_baseline_handoff)
          refute handoff[:reused]
          assert_includes handoff[:rejection_reasons], :grid_residual_changed
        end

        def test_missing_candidate_forces_existing_snapshot_fallback
          subject = ProbeNormalizer.new(mode: :none)
          report = subject.send(:normalize_entity, entity)

          assert_equal 1, subject.fallback_calls
          handoff = report.fetch(:final_coplanar_baseline_handoff)
          refute handoff[:reused]
          assert_equal [:handoff_missing], handoff[:rejection_reasons]
        end

        def test_handoff_summary_is_written_to_diagnostic_profile
          subject = ProbeNormalizer.new
          subject.enable_diagnostic_profile!
          subject.send(:normalize_entity, entity)

          summary = subject.local_vertex_normalizer_diagnostic_profile.fetch(
            :final_coplanar_baseline_handoff
          )
          assert summary[:reused]
          assert_equal :post_coplanar_cleanup, summary[:role]
        end

        def test_context_is_restored_when_inner_pipeline_raises
          subject = ProbeNormalizer.new
          previous = { sentinel: true }
          subject.instance_variable_set(
            :@final_coplanar_baseline_handoff_context,
            previous
          )
          subject.fail_inner!

          assert_raises(RuntimeError) do
            subject.send(:normalize_entity, entity)
          end
          assert_same previous,
                      subject.instance_variable_get(
                        :@final_coplanar_baseline_handoff_context
                      )
        end

        def test_module_is_installed_once_on_production_class
          count = LocalVertexNormalizer.ancestors.count do |ancestor|
            ancestor.equal?(
              LocalVertexNormalizerFinalCoplanarBaselineHandoff
            )
          end
          assert_equal 1, count
        end

        private

        def entity
          @entity ||= FakeEntity.new(Object.new)
        end
      end
    end
  end
end
