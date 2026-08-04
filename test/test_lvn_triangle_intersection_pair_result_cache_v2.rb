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
      class LocalVertexNormalizerTriangleIntersectionPairResultCacheV2Test < Minitest::Test
        class Harness
          prepend LocalVertexNormalizerTriangleIntersectionPairResultCacheV2

          attr_reader :predicate_calls
          attr_accessor :resolver

          def initialize
            @predicate_calls = 0
            @resolver = ->(_triangle_a, _triangle_b) { true }
          end

          private

          def normalize_entity(_entity)
            yield if block_given?
            :ok
          end

          def validate_normalized_triangle_mesh!(pairs)
            pairs.map do |triangle_a, triangle_b|
              exact_triangle_intersection_allowed?(triangle_a, triangle_b)
            end
          end

          def exact_triangle_intersection_allowed?(triangle_a, triangle_b)
            @predicate_calls += 1
            @resolver.call(triangle_a, triangle_b)
          end

          def canonical_triangle_key(triangle)
            triangle.sort
          end
        end

        def test_repeated_pair_is_cached_inside_normalized_mesh_hard_gate
          subject = Harness.new
          triangle_a, triangle_b = pair

          results = within_normalize(subject) do
            subject.send(
              :validate_normalized_triangle_mesh!,
              [[triangle_a, triangle_b], [triangle_a, triangle_b]]
            )
          end

          assert_equal [true, true], results
          assert_equal 1, subject.predicate_calls
        end

        def test_reversed_pair_order_uses_the_same_cache_entry
          subject = Harness.new
          triangle_a, triangle_b = pair

          results = within_normalize(subject) do
            subject.send(
              :validate_normalized_triangle_mesh!,
              [[triangle_a, triangle_b], [triangle_b, triangle_a]]
            )
          end

          assert_equal [true, true], results
          assert_equal 1, subject.predicate_calls
        end

        def test_equal_geometry_in_different_triangle_objects_reuses_entry
          subject = Harness.new
          triangle_a, triangle_b = pair
          cloned_a = deep_copy_triangle(triangle_a)
          cloned_b = deep_copy_triangle(triangle_b)

          within_normalize(subject) do
            subject.send(
              :validate_normalized_triangle_mesh!,
              [[triangle_a, triangle_b], [cloned_a, cloned_b]]
            )
          end

          assert_equal 1, subject.predicate_calls
        end

        def test_rejected_result_is_cached
          subject = Harness.new
          subject.resolver = ->(_triangle_a, _triangle_b) { false }
          triangle_a, triangle_b = pair

          results = within_normalize(subject) do
            subject.send(
              :validate_normalized_triangle_mesh!,
              [[triangle_a, triangle_b], [triangle_a, triangle_b]]
            )
          end

          assert_equal [false, false], results
          assert_equal 1, subject.predicate_calls
        end

        def test_predicate_exception_is_not_cached
          subject = Harness.new
          attempts = 0
          subject.resolver = lambda do |_triangle_a, _triangle_b|
            attempts += 1
            raise 'probe failure' if attempts == 1

            true
          end
          triangle_a, triangle_b = pair

          within_normalize(subject) do
            assert_raises(RuntimeError) do
              subject.send(
                :validate_normalized_triangle_mesh!,
                [[triangle_a, triangle_b]]
              )
            end
            result = subject.send(
              :validate_normalized_triangle_mesh!,
              [[triangle_a, triangle_b]]
            )
            assert_equal [true], result
          end

          assert_equal 2, subject.predicate_calls
        end

        def test_calls_outside_hard_gate_are_not_cached
          subject = Harness.new
          triangle_a, triangle_b = pair

          within_normalize(subject) do
            subject.send(:exact_triangle_intersection_allowed?, triangle_a, triangle_b)
            subject.send(:exact_triangle_intersection_allowed?, triangle_a, triangle_b)
          end

          assert_equal 2, subject.predicate_calls
        end

        def test_cache_is_reset_between_normalize_entity_calls
          subject = Harness.new
          triangle_a, triangle_b = pair

          2.times do
            within_normalize(subject) do
              subject.send(
                :validate_normalized_triangle_mesh!,
                [[triangle_a, triangle_b], [triangle_a, triangle_b]]
              )
            end
          end

          assert_equal 2, subject.predicate_calls
        end

        def test_loader_installs_pair_cache_outside_clean_set_cache
          ancestors = LocalVertexNormalizer.ancestors
          pair_cache_index = ancestors.index(
            LocalVertexNormalizerTriangleIntersectionPairResultCacheV2
          )
          clean_cache_index = ancestors.index(
            LocalVertexNormalizerTriangleIntersectionCleanCacheV2
          )

          refute_nil pair_cache_index
          refute_nil clean_cache_index
          assert_operator pair_cache_index, :<, clean_cache_index
        end

        private

        def within_normalize(subject, &block)
          result = nil
          subject.send(:normalize_entity, :entity) do
            result = block.call
          end
          result
        end

        def pair
          [
            [[0, 0, 0], [4, 0, 0], [0, 4, 0]],
            [[0, 0, 0], [4, 0, 0], [0, 0, 4]]
          ]
        end

        def deep_copy_triangle(triangle)
          triangle.map(&:dup)
        end
      end
    end
  end
end
