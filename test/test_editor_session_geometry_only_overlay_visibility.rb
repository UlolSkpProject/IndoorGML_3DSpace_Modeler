# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class << self
    attr_accessor :test_active_model
  end

  def self.active_model
    @test_active_model
  end
end

module UI
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)
    end
  end
end

require_relative '../indoor3d/domain/cell_space_type'
require_relative '../indoor3d/infrastructure/scene/editor_session'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSessionGeometryOnlyOverlayVisibilityTest < Minitest::Test
        def test_dual_overlay_state_visibility_excludes_geometry_only_state
          session = EditorSession.allocate
          visibility_service = FakeEditVisibilityService.new
          session.instance_variable_set(:@edit_visibility_service, visibility_service)

          geometry_only_cell = FakeCell.new(CellSpaceType::GEOMETRY_ONLY)
          general_cell = FakeCell.new(CellSpaceType::GENERAL)

          refute session.dual_overlay_state_visible?(FakeState.new(geometry_only_cell))
          assert session.dual_overlay_state_visible?(FakeState.new(general_cell))
          assert_equal [general_cell], visibility_service.checked_cells
        end

        private

        class FakeEditVisibilityService
          attr_reader :checked_cells

          def initialize
            @checked_cells = []
          end

          def edit_mode_visible_cell_space?(cell_space)
            @checked_cells << cell_space
            true
          end
        end

        class FakeCell
          attr_reader :cell_type

          def initialize(cell_type)
            @cell_type = cell_type
          end

          def valid?
            true
          end

          def navigable?
            CellSpaceType.navigable?(@cell_type)
          end
        end

        class FakeState
          attr_reader :duality_cell

          def initialize(cell)
            @duality_cell = cell
          end

          def valid?
            true
          end
        end
      end
    end
  end
end
