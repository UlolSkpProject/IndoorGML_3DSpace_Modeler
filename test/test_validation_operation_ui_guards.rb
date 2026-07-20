# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module HtmlDialogMetrics
        WINDOW_CHROME_HEIGHT = 0 unless const_defined?(:WINDOW_CHROME_HEIGHT)
      end unless const_defined?(:HtmlDialogMetrics)
    end
  end
end

require_relative '../indoor3d/ui/edit_mode_dialog'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ValidationOperationUiGuardsTest < Minitest::Test
        def test_selection_updates_carry_current_validation_busy_state
          indoor_model = FakeIndoorModel.new(true)
          dialog = EditModeDialog.allocate
          dialog.instance_variable_set(:@indoor_model, indoor_model)

          busy_script = dialog.send(:selection_script, selection_snapshot)
          assert_includes busy_script, 'validationBusy: true'

          indoor_model.validation_busy = false
          idle_script = dialog.send(:selection_script, selection_snapshot)
          assert_includes idle_script, 'validationBusy: false'
        end

        def test_fix_mode_controls_combine_existing_locks_with_validation_busy
          html = File.read(File.expand_path('../indoor3d/ui/html/edit_mode/index.html', __dir__))
          script = File.read(File.expand_path('../indoor3d/ui/html/edit_mode/app.js', __dir__))

          assert_includes html, 'id="removeIndoorGmlAttributes"'
          assert_includes script, 'validationBusy || snapshot.classificationLocked'
          assert_includes script, 'validationBusy || !currentStoreyRangeAllowed'
          assert_includes script, 'setControlLocked([storeyFromKind, storeyFromLevel], validationBusy)'
          assert_includes script, 'setControlLocked([solidStoreyFromKind, solidStoreyFromLevel], validationBusy)'
          assert_includes script, 'setVisible(removeIndoorGmlAttributesButton, !fixMode)'
          assert_includes script, "invokeSketchup('removeSelectedCellSpacesIndoorGmlAttributes')"
          assert_includes script, '[finishButton, recheckErrorsButton, removeIndoorGmlAttributesButton]'
          assert_includes script, "snapshot.validationBusy ? 'validation-busy' : 'validation-idle'"
        end

        def test_solid_conversion_ui_passes_selected_storey
          html = File.read(File.expand_path('../indoor3d/ui/html/edit_mode/index.html', __dir__))
          script = File.read(File.expand_path('../indoor3d/ui/html/edit_mode/app.js', __dir__))

          assert_includes html, 'id="solidStoreyFields"'
          assert_includes html, 'id="solidStoreyFromLevel"'
          assert_includes html, 'id="solidStoreyToLevel"'
          assert_includes script, "invokeSketchup('convertSelectedSolidGroups', [solidClassification.value, composeSolidStorey()])"
          assert_includes script, 'classificationAllowsStoreyRange(solidClassification.value)'
        end

        def test_change_type_toolbar_checks_validation_busy_before_selection_state
          source = File.read(File.expand_path('../indoor3d/core.rb', __dir__))
          validation_proc = source[/change_type_command\.set_validation_proc do.*?^      end/m]

          refute_nil validation_proc
          assert_operator validation_proc.index('dispatcher.validation_operation_running?'), :<,
                          validation_proc.index('IndoorCore::IndoorModel.current')
          assert_includes validation_proc, 'next MF_GRAYED if dispatcher.validation_operation_running?'
        end

        private

        def selection_snapshot
          {
            mode: :cell_space,
            id: 'cell-1',
            name: 'Cell 1',
            classification: 'GeneralSpace|Room',
            classification_locked: false,
            storey: 'F01',
            storey_editable: true,
            storey_range_allowed: false,
            transition_count: 0,
            cell_space_count: 1,
            selected_cell_type_counts: [],
            solid_group_count: 0,
            state_count: 1,
            total_transition_count: 0,
            cell_type_counts: [],
            visibility_filter: {}
          }
        end

        class FakeIndoorModel
          attr_accessor :validation_busy

          def initialize(validation_busy)
            @validation_busy = validation_busy
          end

          def validation_focus_recheck_running?
            @validation_busy
          end
        end
      end
    end
  end
end
