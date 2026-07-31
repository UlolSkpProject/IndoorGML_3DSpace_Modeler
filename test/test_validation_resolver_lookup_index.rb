# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/validity/validation_error_geometry_resolver'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ValidationResolverLookupIndexTest < Minitest::Test
          def test_uses_indexed_lookup_without_scanning_cell_spaces
            cell = Object.new
            indoor_model = Class.new do
              attr_reader :lookup_calls

              def initialize(cell)
                @cell = cell
                @lookup_calls = []
              end

              def model
                nil
              end

              def find_cell_space_by_normalized_id(value)
                @lookup_calls << value
                value == 'target' ? @cell : nil
              end

              def cell_spaces
                raise 'linear scan should not run when indexed lookup is available'
              end
            end.new(cell)

            resolver = ValidationErrorGeometryResolver.new(indoor_model: indoor_model)

            assert_same cell, resolver.send(:cell_space_for, 'cell_target')
            assert_nil resolver.send(:cell_space_for, 'solid_missing')
            assert_equal %w[target missing], indoor_model.lookup_calls
          end

          def test_fallback_preserves_legacy_normalized_first_match_semantics
            first = Struct.new(:id).new('room:A')
            second = Struct.new(:id).new('room_A')
            indoor_model = Struct.new(:cell_spaces, :model).new([first, second], nil)
            resolver = ValidationErrorGeometryResolver.new(indoor_model: indoor_model)

            assert_same first, resolver.send(:cell_space_for, 'room_A')
            assert_same first, resolver.send(:cell_space_for, 'cell_room_A')
            assert_nil resolver.send(:cell_space_for, 'missing')
          end
        end
      end
    end
  end
end
