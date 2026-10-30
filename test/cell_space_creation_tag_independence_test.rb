# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/cell_space_lifecycle_service'
require_relative '../indoor3d/application/cell_space_conversion'

module Sketchup
end unless defined?(Sketchup)
Sketchup.const_set(:Group, Class.new) unless Sketchup.const_defined?(:Group)
Sketchup.const_set(:ComponentInstance, Class.new) unless Sketchup.const_defined?(:ComponentInstance)

class CellSpaceCreationTagIndependenceTest < Minitest::Test
  Core = ULOL::Indoor3DGmlModeler::IndoorCore

  FakeEntity = Struct.new(:layer)
  FakeDefinition = Struct.new(:entities)
  FakeGroup = Struct.new(:model, :layer, :definition)
  FakeModel = Struct.new(:layers)
  TaggedSolid = Class.new(Sketchup::Group) do
    def valid?
      true
    end

    def manifold?
      true
    end

    def name
      'Tagged source'
    end

    def get_attribute(*_args)
      nil
    end
  end

  def test_source_preparer_uses_only_explicit_type_and_storey
    preparer = Core::CellSpaceLifecycleSourcePreparer.new(
      converted_group: proc { false },
      geometry_preparer: proc { { valid: true } },
      storey_value_resolver: proc { |value, _type, _category, _default| value }
    )
    source = Object.new

    assert_equal [:general, 'Room'], preparer.resolve_type_and_category(source, :general, 'Room')
    assert_equal 'F03', preparer.resolve_storey(source, :general, 'Room', 'F01', 'F03')
    assert_equal 'F01', preparer.resolve_storey(source, :general, 'Room', 'F01')
  end

  def test_created_cell_space_group_is_reset_to_untagged
    untagged = Object.new
    assigned_tag = Object.new
    face = FakeEntity.new(assigned_tag)
    edge = FakeEntity.new(assigned_tag)
    group = FakeGroup.new(FakeModel.new([untagged]), assigned_tag, FakeDefinition.new([face, edge]))
    service = Core::CellSpaceLifecycleService.allocate

    service.send(:clear_cell_space_tag!, group)

    assert_same untagged, group.layer
    assert_same untagged, face.layer
    assert_same untagged, edge.layer
  end

  def test_conversion_copy_does_not_copy_source_entity_attributes
    assert_empty Core::CellSpaceConversionExecutor::COPY_ATTRIBUTES
  end

  def test_conversion_job_contains_geometry_context_but_no_tag_target_or_storey
    builder = Core::CellSpaceConversionJobBuilder.allocate
    jobs = []

    builder.send(:collect, TaggedSolid.new, Object.new, [], jobs, [])

    assert_equal 1, jobs.length
    refute jobs.first.key?(:target)
    refute jobs.first.key?(:storey)
  end
end
