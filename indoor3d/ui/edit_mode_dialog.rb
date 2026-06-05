# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditModeDialog
        include Utils::HtmlHelpers
        
        DIALOG_WIDTH = 280
        INITIAL_DIALOG_HEIGHT = 260
        MIN_DIALOG_HEIGHT = 280
        MAX_DIALOG_HEIGHT = 620
        CONTENT_PADDING_HEIGHT = 24
        DIALOG_WINDOW_CHROME_HEIGHT = 96

        def initialize(indoor_model)
          @indoor_model = indoor_model
          @dialog = nil
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
            puts "[IndoorGML] Edit mode dialog selection update failed: #{e.class}: #{e.message}"
          end
        end

        def close
          begin
            @dialog&.close if @dialog&.visible?
            @dialog = nil
          rescue StandardError => e
            puts "[IndoorGML] Edit mode dialog close failed: #{e.class}: #{e.message}"
          end
        end

        private

        def dialog
          @dialog ||= build_dialog
        end

        def build_dialog
          dialog = UI::HtmlDialog.new(
            dialog_title: 'IndoorGML Edit Mode',
            preferences_key: 'ULOL.Indoor3DGmlModeler.EditMode',
            scrollable: true,
            resizable: false,
            width: DIALOG_WIDTH,
            height: INITIAL_DIALOG_HEIGHT,
            style: UI::HtmlDialog::STYLE_DIALOG
          )
          dialog.add_action_callback('fitContentHeight') do |_context, content_height|
            fit_content_height(content_height)
          end
          dialog.add_action_callback('domReady') do |_context|
            dialog.execute_script(init_script)
          end
          dialog.add_action_callback('setOverlayMinRadius') do |_context, radius_pixels|
            UI.start_timer(0, false) do
              @indoor_model.set_overlay_min_radius_pixels(radius_pixels)
            end
          end
          dialog.add_action_callback('setOverlayRadiusRange') do |_context, min_radius_pixels, max_radius_pixels|
            UI.start_timer(0, false) do
              @indoor_model.set_overlay_radius_pixel_range(min_radius_pixels, max_radius_pixels)
            end
          end
          dialog.add_action_callback('setSelectedCellSpaceClassification') do |_context, selection_value|
            puts "[IndoorGML] EditModeDialog#setSelectedCellSpaceClassification value=#{selection_value}"
            UI.start_timer(0, false) do
              @indoor_model.set_selected_cell_space_classification(selection_value)
            end
          end
          dialog.add_action_callback('finishEditing') do |_context|
            UI.start_timer(0, false) do
              @indoor_model.request_finish_editing()
            end
          end
          dialog.add_action_callback('clearAllIndoorGmlElements') do |_context|
            puts '[IndoorGML] EditModeDialog#clearAllIndoorGmlElements'
            UI.start_timer(0, false) do
              @indoor_model.clear_all_indoor_gml_elements()
            end
          end
          dialog.set_on_closed do
            puts "[IndoorGML] set_on_closed called, editing=#{@indoor_model.editing?}"
            @indoor_model.finish_editing()
            @dialog = nil
          end if dialog.respond_to?(:set_on_closed)

          return dialog
        end

        def fit_content_height(content_height)
          begin
            return unless @dialog

            requested_height = content_height.to_i + CONTENT_PADDING_HEIGHT + DIALOG_WINDOW_CHROME_HEIGHT
            height = [[requested_height, MIN_DIALOG_HEIGHT].max, MAX_DIALOG_HEIGHT].min
            @dialog.set_size(DIALOG_WIDTH, height)
          rescue StandardError => e
            puts "[IndoorGML] Edit mode dialog resize failed: #{e.class}: #{e.message}"
          end
        end

        def init_script
          overlay_min_radius = @indoor_model.overlay_min_radius_pixels.round
          overlay_max_radius = @indoor_model.overlay_max_radius_pixels.round
          options = CellSpaceCategory.selection_options.map do |option|
            "{value: #{js_string(option[:value])}, label: #{js_string(option[:label])}}"
          end.join(', ')

          "init(#{overlay_min_radius}, #{overlay_max_radius}, [#{options}]);"
        end

        def selection_script(snapshot)
          if snapshot.nil?
            'updateSelectedCellSpace(null);'
          else
            <<~JS
              updateSelectedCellSpace({
                feature: #{js_string(snapshot[:feature])},
                id: #{js_string(snapshot[:id])},
                name: #{js_string(snapshot[:name])},
                cellType: #{js_string(snapshot[:cell_type])},
                categoryCode: #{js_string(snapshot[:category_code])},
                classification: #{js_string(snapshot[:classification])},
                cellGeometryEditing: #{snapshot[:cell_geometry_editing] ? 'true' : 'false'}
              });
            JS
          end
        end

        def js_string(value)
          value.to_s.inspect
        end
      end
    end
  end
end
