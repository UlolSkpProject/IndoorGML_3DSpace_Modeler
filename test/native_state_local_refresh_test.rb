# frozen_string_literal: true

require 'minitest/autorun'

class Numeric
  def mm
    to_f / 25.4
  end unless method_defined?(:mm)
end

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x
      @y = y
      @z = z
    end

    def transform(_transformation)
      self
    end
  end
end unless defined?(Geom::Point3d)

require_relative '../indoor3d/application/indoor_model/scene_groups'

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module Geometry
        class << self
          attr_accessor :test_snapshot

          def adjacency_snapshot(_entity)
            @test_snapshot
          end
        end
      end
    end
  end
end

class NativeStateLocalRefreshTest < Minitest::Test
  IndoorCore = ULOL::Indoor3DGmlModeler::IndoorCore
  Bridge = IndoorCore::NativeAdjacencyBridge

  FakeTransform = Struct.new(:unused) do
    def inverse
      self
    end
  end
  FakeEntity = Struct.new(:persistent_id, :transformation) do
    def valid?
      true
    end
  end
  FakeCell = Struct.new(:id, :category_code)

  class Harness
    include IndoorCore::IndoorModel::SceneGroups

    def initialize(cell)
      @cell = cell
    end

    def find_cell_space_for_entity(_entity)
      @cell
    end

    def native_state_fixed_parent_z_for_entity(_entity, _offset)
      nil
    end
  end

  def setup
    @original_methods = {}
    %i[
      shared_session_supported? shared_session_active? open_geometry_session
      compute_reference_from_open_session commit_reference_graph_batch
      close_geometry_session
    ].each do |name|
      @original_methods[name] = Bridge.method(name)
    end
    ULOL::Indoor3DGmlModeler::Utils::Geometry.test_snapshot = { faces: [] }
    @opened = nil
    @commits = 0
    @closes = 0
    test = self
    Bridge.define_singleton_method(:shared_session_supported?) { true }
    Bridge.define_singleton_method(:shared_session_active?) { false }
    Bridge.define_singleton_method(:open_geometry_session) do |snapshots, keys:, state_options:|
      test.instance_variable_set(:@opened, [snapshots, keys, state_options])
      true
    end
    Bridge.define_singleton_method(:commit_reference_graph_batch) do
      test.instance_variable_set(:@commits, test.instance_variable_get(:@commits) + 1)
      true
    end
    Bridge.define_singleton_method(:close_geometry_session) do
      test.instance_variable_set(:@closes, test.instance_variable_get(:@closes) + 1)
      true
    end
  end

  def teardown
    @original_methods.each do |name, implementation|
      Bridge.define_singleton_method(name, implementation)
    end
  end

  def test_registered_cell_uses_v13_result_and_commits_graph_under_cell_id
    Bridge.define_singleton_method(:compute_reference_from_open_session) do
      {
        results: {
          0 => { exit_code: 0, state_point: [1.0, 2.0, 3.0], diagnostics: {} }
        }
      }
    end
    cell = FakeCell.new('cell-1', 'Door')
    entity = FakeEntity.new(42, FakeTransform.new)

    point = Harness.new(cell).send(:native_state_local_point_for_entity, entity)

    assert_equal [1.0, 2.0, 3.0], [point.x, point.y, point.z]
    assert_equal ['cell-1'], @opened[1]
    assert_equal 'Door', @opened[2][0][:category_code]
    assert_equal 1, @commits
    assert_equal 1, @closes
  end

  def test_failed_state_closes_session_without_replacing_existing_graph
    Bridge.define_singleton_method(:compute_reference_from_open_session) do
      {
        results: {
          0 => {
            exit_code: 61,
            state_point: nil,
            diagnostics: { rejected_clearance: 1 }
          }
        }
      }
    end
    cell = FakeCell.new('cell-2', 'Room')
    entity = FakeEntity.new(43, FakeTransform.new)

    error = assert_raises(Bridge::StateUnavailableError) do
      Harness.new(cell).send(:native_state_local_point_for_entity, entity)
    end

    assert_equal 61, error.exit_code
    assert_equal 0, @commits
    assert_equal 1, @closes
  end
end
