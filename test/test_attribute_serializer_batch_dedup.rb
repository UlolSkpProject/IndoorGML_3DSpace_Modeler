# frozen_string_literal: true

require 'minitest/autorun'

require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/infrastructure/persistence/attribute_serializer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class AttributeSerializerBatchDedupTest < Minitest::Test
        FakeState = Struct.new(:id)

        class FakeGroup
          attr_reader :mutation_count

          def initialize
            @attributes = {}
            @mutation_count = 0
          end

          def valid?
            true
          end

          def set_attribute(dictionary, key, value)
            @mutation_count += 1
            (@attributes[dictionary] ||= {})[key] = value
          end

          def delete_attribute(dictionary, key)
            @mutation_count += 1
            (@attributes[dictionary] ||= {}).delete(key)
          end

          def get_attribute(dictionary, key, default = nil)
            @attributes.fetch(dictionary, {}).fetch(key, default)
          end
        end

        class FakeCellSpace
          attr_accessor :storey,
                        :navigation_class,
                        :navigation_class_code_space,
                        :navigation_function,
                        :navigation_function_code_space,
                        :navigation_usage,
                        :navigation_usage_code_space
          attr_reader :id, :cell_type, :category_code, :duality_state

          def initialize(group, id: 'cell-1', storey: 'F01')
            @group = group
            @id = id
            @cell_type = CellSpaceType::GENERAL
            @category_code = 'Room'
            @storey = storey
            @duality_state = FakeState.new("state-#{id}")
          end

          def valid_sketchup_group
            @group
          end

          def navigable?
            false
          end
        end

        def setup
          @serializer = AttributeSerializer.new
          @group = FakeGroup.new
          @cell_space = FakeCellSpace.new(@group)
        end

        def test_identical_cell_space_write_is_deduplicated_only_inside_scope
          @serializer.with_cell_space_write_dedup do
            assert @serializer.write_cell_space(@cell_space)
            first_write_count = @group.mutation_count
            assert_operator first_write_count, :>, 0

            assert @serializer.write_cell_space(@cell_space)
            assert_equal first_write_count, @group.mutation_count
          end

          count_after_scope = @group.mutation_count
          assert @serializer.write_cell_space(@cell_space)
          assert_operator @group.mutation_count, :>, count_after_scope
        end

        def test_changed_serialized_value_forces_write_inside_scope
          @serializer.with_cell_space_write_dedup do
            assert @serializer.write_cell_space(@cell_space)
            first_write_count = @group.mutation_count

            @cell_space.storey = 'F02'
            assert @serializer.write_cell_space(@cell_space)

            assert_operator @group.mutation_count, :>, first_write_count
            assert_equal 'F02', @group.get_attribute(AttributeSerializer::ATTRIBUTE_DICTIONARY_NAME, 'storey')
          end
        end

        def test_identical_values_on_different_groups_are_not_deduplicated_together
          other_group = FakeGroup.new
          other_cell_space = FakeCellSpace.new(other_group, id: 'cell-2')

          @serializer.with_cell_space_write_dedup do
            assert @serializer.write_cell_space(@cell_space)
            assert @serializer.write_cell_space(other_cell_space)
          end

          assert_operator @group.mutation_count, :>, 0
          assert_operator other_group.mutation_count, :>, 0
        end
      end
    end
  end
end
