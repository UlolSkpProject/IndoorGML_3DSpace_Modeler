# frozen_string_literal: true

require 'json'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditModeDialog
        include Utils::HtmlHelpers
        
        DIALOG_WIDTH = 560
        INITIAL_DIALOG_HEIGHT = 360
        MIN_DIALOG_HEIGHT = 260
        MAX_DIALOG_HEIGHT = 760
        CONTENT_PADDING_HEIGHT = 8
        DIALOG_WINDOW_CHROME_HEIGHT = 44
        def initialize(indoor_model)
          @indoor_model = indoor_model
          @dialog = nil
          @dialog_height = INITIAL_DIALOG_HEIGHT
          @suppress_close_callback = false
        end

        def show
          dialog.set_file(File.join(__dir__, 'html', 'edit_mode', 'index.html'))
          dialog.show
        end

        def update_selection(snapshot)
          begin
            return unless @dialog&.visible?

            @dialog.execute_script(selection_script(snapshot))
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode dialog selection update failed: #{e.class}: #{e.message}"
          end
        end

        def close
          begin
            @dialog&.close if @dialog&.visible?
            @dialog = nil
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode dialog close failed: #{e.class}: #{e.message}"
          end
        end

        def close_without_finish
          begin
            @suppress_close_callback = true
            @dialog&.close if @dialog&.visible?
            @dialog = nil
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode dialog dispose failed: #{e.class}: #{e.message}"
          end
        end

        private

        def dialog
          @dialog ||= build_dialog
        end

        def build_dialog
          @suppress_close_callback = false
          dialog = UI::HtmlDialog.new(
            dialog_title: @indoor_model.validation_focus_active? ? 'IndoorGML Fix Mode' : 'IndoorGML Edit Mode',
            preferences_key: 'ULOL.Indoor3DGmlModeler.EditMode',
            scrollable: false,
            resizable: false,
            width: DIALOG_WIDTH,
            height: INITIAL_DIALOG_HEIGHT,
            style: UI::HtmlDialog::STYLE_UTILITY
          )
          dialog.add_action_callback('fitContentHeight') do |_context, content_height|
            fit_content_height(content_height)
          end
          dialog.add_action_callback('domReady') do |_context|
            dialog.execute_script(init_script)
          end
          dialog.add_action_callback('setSelectedCellSpaceClassification') do |_context, selection_value|
            IndoorCore::Logger.puts "[IndoorGML] EditModeDialog#setSelectedCellSpaceClassification value=#{selection_value}"
            UI.start_timer(0, false) do
              @indoor_model.set_selected_cell_space_classification(selection_value)
            end
          end
          dialog.add_action_callback('setSelectedCellSpaceNavigationSemantics') do |_context, navigation_class, navigation_function, navigation_usage|
            IndoorCore::Logger.puts '[IndoorGML] EditModeDialog#setSelectedCellSpaceNavigationSemantics'
            UI.start_timer(0, false) do
              @indoor_model.set_selected_cell_space_navigation_semantics(
                navigation_class,
                navigation_function,
                navigation_usage
              )
            end
          end
          dialog.add_action_callback('setSelectedCellSpaceStorey') do |_context, storey|
            IndoorCore::Logger.puts "[IndoorGML] EditModeDialog#setSelectedCellSpaceStorey value=#{storey}"
            UI.start_timer(0, false) do
              @indoor_model.set_selected_cell_space_storey(storey)
            end
          end
          dialog.add_action_callback('setEditModeVisibilityFilter') do |_context, storeys_json, cell_types_json|
            IndoorCore::Logger.puts '[IndoorGML] EditModeDialog#setEditModeVisibilityFilter'
            UI.start_timer(0, false) do
              @indoor_model.set_edit_mode_visibility_filter(storeys_json, cell_types_json)
            end
          end
          dialog.add_action_callback('convertSelectedSolidGroups') do |_context, selection_value|
            IndoorCore::Logger.puts "[IndoorGML] EditModeDialog#convertSelectedSolidGroups value=#{selection_value}"
            UI.start_timer(0, false) do
              @indoor_model.convert_selected_solid_groups_to_cell_spaces(selection_value)
            end
          end
          dialog.add_action_callback('finishEditing') do |_context|
            UI.start_timer(0, false) do
              @indoor_model.request_finish_editing()
            end
          end
          dialog.add_action_callback('clearAllIndoorGmlElements') do |_context|
            IndoorCore::Logger.puts '[IndoorGML] EditModeDialog#clearAllIndoorGmlElements'
            UI.start_timer(0, false) do
              @indoor_model.clear_all_indoor_gml_elements()
            end
          end
          dialog.add_action_callback('recheckFixModeErrors') do |_context|
            IndoorCore::Logger.puts '[IndoorGML] EditModeDialog#recheckFixModeErrors'
            UI.start_timer(0, false) do
              @indoor_model.recheck_validation_focus_errors()
            end
          end
          dialog.set_on_closed do
            IndoorCore::Logger.puts "[IndoorGML] set_on_closed called, editing=#{@indoor_model.editing?}"
            if @suppress_close_callback
              @suppress_close_callback = false
            else
              @indoor_model.finish_editing()
            end
            @dialog = nil
          end if dialog.respond_to?(:set_on_closed)

          return dialog
        end

        def fit_content_height(content_height)
          begin
            return unless @dialog

            requested_height = content_height.to_i + CONTENT_PADDING_HEIGHT + DIALOG_WINDOW_CHROME_HEIGHT
            height = [[requested_height, MIN_DIALOG_HEIGHT].max, MAX_DIALOG_HEIGHT].min
            set_dialog_height(height)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Edit mode dialog resize failed: #{e.class}: #{e.message}"
          end
        end

        def set_dialog_height(height)
          @dialog.set_size(DIALOG_WIDTH, height)
          @dialog_height = height
        end

        def init_script
          asset_root = File.expand_path('..', __dir__).tr('\\', '/')
          options = CellSpaceCategory.selection_options.map do |option|
            "{value: #{js_string(option[:value])}, label: #{js_string(option[:label])}}"
          end.join(', ')

          "init({classificationOptions: [#{options}], assetRoot: #{js_string(asset_root)}, overlayColors: #{overlay_colors_script}, fixMode: #{@indoor_model.validation_focus_active? ? 'true' : 'false'}, visibilityFilter: #{visibility_filter_script(@indoor_model.edit_mode_visibility_filter_snapshot)}});"
        end

        def overlay_colors_script
          state_color = EditModeOverlay::DUAL_STATE_COLOR
          "{state: #{js_string(css_rgba(state_color))}, stateSoft: #{js_string(css_rgba(state_color, alpha: 0.36))}}"
        end

        def css_rgba(color, alpha: nil)
          opacity = alpha || (color.alpha.to_f / 255.0)
          "rgba(#{color.red}, #{color.green}, #{color.blue}, #{format('%.3f', opacity)})"
        end

        def selection_script(snapshot)
          if snapshot.nil?
            'updateSelectionAndFit(null);'
          else
            <<~JS
              updateSelectionAndFit({
                mode: #{js_string(snapshot[:mode])},
                feature: #{js_string(snapshot[:feature])},
                id: #{js_string(snapshot[:id])},
                name: #{js_string(snapshot[:name])},
                cellType: #{js_string(snapshot[:cell_type])},
                categoryCode: #{js_string(snapshot[:category_code])},
                classification: #{snapshot[:classification].nil? ? 'null' : js_string(snapshot[:classification])},
                classificationLocked: #{snapshot[:classification_locked] ? 'true' : 'false'},
                storey: #{js_string(snapshot[:storey])},
                storeyEditable: #{snapshot[:storey_editable] ? 'true' : 'false'},
                storeyRangeAllowed: #{snapshot[:storey_range_allowed] ? 'true' : 'false'},
                navigationSemanticsEnabled: #{snapshot[:navigation_semantics_enabled] ? 'true' : 'false'},
                navigationClass: #{js_string(snapshot[:navigation_class])},
                navigationFunction: #{js_string(snapshot[:navigation_function])},
                navigationUsage: #{js_string(snapshot[:navigation_usage])},
                transitionCount: #{snapshot[:transition_count].to_i},
                cellSpaceCount: #{snapshot[:cell_space_count].to_i},
                solidGroupCount: #{snapshot[:solid_group_count].to_i},
                stateCount: #{snapshot[:state_count].to_i},
                totalTransitionCount: #{snapshot[:total_transition_count].to_i},
                cellTypeCounts: #{cell_type_counts_script(snapshot[:cell_type_counts])},
                visibilityFilter: #{visibility_filter_script(snapshot[:visibility_filter])},
                cellGeometryEditing: #{snapshot[:cell_geometry_editing] ? 'true' : 'false'}
              });
            JS
          end
        end

        def cell_type_counts_script(counts)
          Array(counts).map do |entry|
            "{label: #{js_string(entry[:label])}, count: #{entry[:count].to_i}}"
          end.then { |items| "[#{items.join(', ')}]" }
        end

        def visibility_filter_script(filter)
          filter ||= {}
          <<~JS.strip
            {
              storeyOptions: #{option_list_script(filter[:storey_options])},
              selectedStoreys: #{string_list_script(filter[:selected_storeys])},
              cellTypeOptions: #{option_list_script(filter[:cell_type_options])},
              selectedCellTypes: #{string_list_script(filter[:selected_cell_types])}
            }
          JS
        end

        def option_list_script(options)
          Array(options).map do |entry|
            "{value: #{js_string(entry[:value])}, label: #{js_string(entry[:label])}}"
          end.then { |items| "[#{items.join(', ')}]" }
        end

        def string_list_script(values)
          Array(values).map { |value| js_string(value) }.then { |items| "[#{items.join(', ')}]" }
        end

        def js_string(value)
          value.to_s.inspect
        end
      end
    end
  end
end
