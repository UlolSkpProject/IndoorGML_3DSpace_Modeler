# frozen_string_literal: true

require 'minitest/autorun'

GL_QUADS = 7 unless defined?(GL_QUADS)

module Geom
  class BoundingBox; end
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x
      @y = y
      @z = z
    end
  end
end

module Sketchup
  class Overlay
    attr_accessor :enabled
    attr_reader :overlay_id

    def initialize(overlay_id, _name, description: nil)
      @overlay_id = overlay_id
      @description = description
      @valid = true
      @enabled = false
    end

    def valid?
      @valid
    end

    def invalidate!
      @valid = false
    end
  end

  class Color
    def initialize(*values)
      @values = values
    end
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end
    end
  end
end

require_relative '../indoor3d/ui/overlays/production_progress_overlay'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class ProductionProgressOverlayTest < Minitest::Test
          class FakeClock
            def initialize
              @value = 10.0
            end

            def call
              @value
            end

            def advance(value)
              @value += value
            end
          end

          class FakeView
            attr_reader :refresh_count, :draw_calls, :text_calls
            attr_accessor :drawing_color

            def initialize
              @refresh_count = 0
              @draw_calls = []
              @text_calls = []
            end

            def vpwidth
              1000
            end

            def vpheight
              800
            end

            def refresh
              @refresh_count += 1
            end

            def draw2d(mode, points)
              @draw_calls << [mode, points]
            end

            def draw_text(point, text, options)
              @text_calls << [point, text, options]
            end
          end

          class FakeOverlays
            include Enumerable
            attr_reader :items

            def initialize
              @items = []
            end

            def each(&block)
              @items.each(&block)
            end

            def add(overlay)
              @items << overlay
              true
            end

            def remove(overlay)
              @items.delete(overlay)
              overlay.invalidate! if overlay.respond_to?(:invalidate!)
              true
            end
          end

          FakeModel = Struct.new(:overlays, :active_view)

          def snapshot(
            stage_name: 'CellSpace/State 생성',
            stage_status: :running,
            completed: 2,
            total: 5,
            status: :running,
            terminal: false,
            operation: nil,
            session_stage_count: nil,
            stage_index: nil,
            stage_count: nil,
            archived_stage_count: 0
          )
            session_metadata = {}
            session_metadata[:operation] = operation unless operation.nil?
            session_metadata[:stage_count] = session_stage_count unless session_stage_count.nil?

            stage_metadata = {}
            stage_metadata[:stage_index] = stage_index unless stage_index.nil?
            stage_metadata[:stage_count] = stage_count unless stage_count.nil?

            {
              title: 'CellSpace 생성',
              message: 'CellSpace 생성 중',
              status: status,
              terminal: terminal,
              elapsed: 1.25,
              percent: terminal ? 100.0 : 40.0,
              metadata: session_metadata,
              stages: Array.new(archived_stage_count) { { status: :completed } },
              stage: {
                name: stage_name,
                status: stage_status,
                completed: completed,
                total: total,
                percent: total.positive? ? completed.fdiv(total) * 100.0 : 0.0,
                metadata: stage_metadata
              }
            }.freeze
          end

          def test_show_registers_draws_and_forces_initial_refresh
            clock = FakeClock.new
            view = FakeView.new
            model = FakeModel.new(FakeOverlays.new, view)
            renderer = SketchupOverlayProgressRenderer.new(model: model, clock: clock)

            assert renderer.show(snapshot)
            assert_equal 1, model.overlays.items.length
            assert renderer.overlay.visible?
            assert renderer.overlay.enabled
            assert_equal 1, view.refresh_count

            renderer.overlay.draw(view)
            refute_empty view.draw_calls
            assert_equal 2, view.text_calls.length
            assert_includes view.text_calls.first[1], 'CellSpace 생성 중'
          end

          def test_detail_shows_stage_position_from_session_metadata
            view = FakeView.new
            overlay = ProductionProgressOverlay.new
            overlay.update_snapshot(
              snapshot(
                stage_name: 'CellSpace 위치 정리',
                session_stage_count: 6,
                archived_stage_count: 2
              )
            )

            overlay.draw(view)

            detail = view.text_calls.fetch(1).fetch(1)
            assert_includes detail, '3 / 6단계'
            assert_includes detail, 'CellSpace 위치 정리'
          end

          def test_detail_prefers_explicit_zero_based_stage_index
            view = FakeView.new
            overlay = ProductionProgressOverlay.new
            overlay.update_snapshot(
              snapshot(
                stage_name: 'GML 구조 생성',
                operation: :gml_export,
                stage_index: 3,
                stage_count: 5,
                archived_stage_count: 1
              )
            )

            overlay.draw(view)

            detail = view.text_calls.fetch(1).fetch(1)
            assert_includes detail, '4 / 5단계'
            assert_includes detail, 'GML 구조 생성'
          end

          def test_create_workflow_keeps_fixed_position_when_stage_is_skipped
            view = FakeView.new
            overlay = ProductionProgressOverlay.new
            overlay.update_snapshot(
              snapshot(
                stage_name: 'Transition 반영',
                operation: :cell_space_create,
                archived_stage_count: 4
              )
            )

            overlay.draw(view)

            detail = view.text_calls.fetch(1).fetch(1)
            assert_includes detail, '7 / 7단계'
          end

          def test_update_is_throttled_but_stage_change_forces_refresh
            clock = FakeClock.new
            view = FakeView.new
            model = FakeModel.new(FakeOverlays.new, view)
            renderer = SketchupOverlayProgressRenderer.new(model: model, clock: clock, refresh_interval: 0.1)
            renderer.show(snapshot)

            renderer.update(snapshot(completed: 3))
            assert_equal 1, view.refresh_count

            clock.advance(0.11)
            renderer.update(snapshot(completed: 4))
            assert_equal 2, view.refresh_count

            renderer.update(snapshot(stage_name: 'Adjacency/Transition 생성', completed: 0, total: 1))
            assert_equal 3, view.refresh_count
          end

          def test_close_removes_overlay_and_is_idempotent
            clock = FakeClock.new
            view = FakeView.new
            model = FakeModel.new(FakeOverlays.new, view)
            renderer = SketchupOverlayProgressRenderer.new(model: model, clock: clock)
            renderer.show(snapshot)

            assert renderer.close
            assert_empty model.overlays.items
            refute renderer.close
          end

          def test_registration_removes_stale_progress_overlay
            clock = FakeClock.new
            view = FakeView.new
            overlays = FakeOverlays.new
            stale = ProductionProgressOverlay.new
            overlays.add(stale)
            model = FakeModel.new(overlays, view)
            renderer = SketchupOverlayProgressRenderer.new(model: model, clock: clock)

            renderer.show(snapshot)

            assert_equal 1, overlays.items.length
            refute_same stale, overlays.items.first
            refute stale.valid?
          end
        end
      end
    end
  end
end
