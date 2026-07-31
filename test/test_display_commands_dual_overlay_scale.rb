# frozen_string_literal: true

require 'minitest/autorun'

module UI
  class << self
    attr_accessor :messages
  end

  def self.messagebox(message)
    messages << message
  end
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

require_relative '../indoor3d/ui/commands/display_commands'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class DisplayCommandsDualOverlayScaleTest < Minitest::Test
        def setup
          UI.messages = []
          @previous_dialog_defined = IndoorCore.const_defined?(:DualOverlayScaleDialog, false)
          @previous_dialog = IndoorCore.const_get(:DualOverlayScaleDialog) if @previous_dialog_defined
          IndoorCore.send(:remove_const, :DualOverlayScaleDialog) if @previous_dialog_defined
          IndoorCore.const_set(:DualOverlayScaleDialog, fake_dialog_class)
        end

        def teardown
          IndoorCore.send(:remove_const, :DualOverlayScaleDialog) if IndoorCore.const_defined?(:DualOverlayScaleDialog, false)
          IndoorCore.const_set(:DualOverlayScaleDialog, @previous_dialog) if @previous_dialog_defined
        end

        def test_open_dual_overlay_scale_dialog_creates_and_shows_dialog
          dispatcher = Class.new { include DisplayCommands }.new

          dispatcher.open_dual_overlay_scale_dialog

          dialog = dispatcher.instance_variable_get(:@dual_overlay_scale_dialog)
          assert_instance_of DualOverlayScaleDialog, dialog
          assert_equal true, dialog.shown
        end

        def test_open_dual_overlay_scale_dialog_during_validation
          dispatcher = Class.new do
            include DisplayCommands

            def validation_operation_running?
              true
            end
          end.new

          dispatcher.open_dual_overlay_scale_dialog

          dialog = dispatcher.instance_variable_get(:@dual_overlay_scale_dialog)
          assert_instance_of DualOverlayScaleDialog, dialog
          assert_equal true, dialog.shown
        end

        def test_open_dual_overlay_scale_dialog_reports_failures
          IndoorCore.send(:remove_const, :DualOverlayScaleDialog)
          IndoorCore.const_set(:DualOverlayScaleDialog, failing_dialog_class)
          dispatcher = Class.new { include DisplayCommands }.new

          dispatcher.open_dual_overlay_scale_dialog

          assert_match(/State\/Link overlay scale dialog failed/, UI.messages.last)
        end

        private

        def fake_dialog_class
          Class.new do
            attr_reader :shown

            def show
              @shown = true
            end
          end
        end

        def failing_dialog_class
          Class.new do
            def show
              raise 'show failed'
            end
          end
        end
      end
    end
  end
end
