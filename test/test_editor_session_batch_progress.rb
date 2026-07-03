# frozen_string_literal: true

require 'minitest/autorun'

module UI
  class << self
    attr_accessor :timers
  end

  def self.start_timer(interval, repeat, &block)
    self.timers ||= []
    timers << { interval: interval, repeat: repeat, block: block }
    true
  end
end

module Sketchup
  class << self
    attr_accessor :test_active_model
  end

  def self.active_model
    @test_active_model
  end
end

require_relative '../indoor3d/infrastructure/scene/editor_session/batch_progress'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSessionBatchProgressTest < Minitest::Test
        def setup
          UI.timers = []
          Sketchup.test_active_model = fake_model
        end

        def teardown
          Sketchup.test_active_model = nil
        end

        def test_rejects_nested_batch_while_progress_is_active
          session = FakeSession.new

          first_started = session.run_batched([1], message: 'First') { |_item, _index| }
          second_started = session.run_batched([2], message: 'Second') { |_item, _index| }

          assert first_started
          refute second_started

          assert_equal 1, UI.timers.length
          assert session.progress_active?
        end

        def test_model_change_fails_batch_and_clears_progress
          session = FakeSession.new
          errors = []

          started = session.run_batched([1, 2], message: 'Batch', failure: proc { |error| errors << error.message }) do |_item, _index|
          end
          assert started
          Sketchup.test_active_model = fake_model
          UI.timers.shift.fetch(:block).call

          assert_equal ['Batched operation model changed or closed'], errors
          refute session.progress_active?
        end

        def test_batch_completes_when_model_is_unchanged
          session = FakeSession.new
          processed = []
          completed = false

          started = session.run_batched([:a, :b], message: 'Batch', batch_size: 1, complete: proc { completed = true }) do |item, _index|
            processed << item
          end
          assert started
          UI.timers.shift.fetch(:block).call
          UI.timers.shift.fetch(:block).call

          assert_equal [:a, :b], processed
          assert_equal true, completed
          refute session.progress_active?
        end

        private

        def fake_model
          Object.new
        end

        class FakeSession
          include EditorSession::BatchProgress

          def ensure_overlay_registered(_model); end

          def update_overlay_enabled; end

          def invalidate_view(_model); end
        end
      end
    end
  end
end
