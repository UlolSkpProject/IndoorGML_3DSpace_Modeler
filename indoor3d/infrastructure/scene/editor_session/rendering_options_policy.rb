# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        module RenderingOptionsPolicy
          INACTIVE_HIDDEN_KEY = 'InactiveHidden'
          RENDER_MODE_KEY = 'RenderMode'
          TEXTURE_KEY = 'Texture'
          SHADED_RENDER_MODE = 2
          MONOCHROME_RENDER_MODE = 5

          module_function

          def apply_shaded(model)
            apply_values(
              model,
              RENDER_MODE_KEY => SHADED_RENDER_MODE,
              TEXTURE_KEY => false
            )
          end

          def apply_monochrome(model)
            apply_values(
              model,
              RENDER_MODE_KEY => MONOCHROME_RENDER_MODE,
              TEXTURE_KEY => false
            )
          end

          def apply_inactive_hidden(model, hidden)
            apply_values(model, INACTIVE_HIDDEN_KEY => hidden == true)
          end

          def apply_values(model, values)
            options = model&.rendering_options
            return false unless options

            changed = false
            values.each do |key, value|
              next unless rendering_option_key?(options, key)
              next if options[key] == value

              options[key] = value
              changed = true
            end
            model&.active_view&.invalidate if changed
            changed
          end

          def rendering_option_key?(options, key)
            return options.key?(key) if options.respond_to?(:key?)
            return options.keys.include?(key) if options.respond_to?(:keys)

            found = false
            if options.respond_to?(:each_key)
              options.each_key do |candidate|
                if candidate == key
                  found = true
                  break
                end
              end
            end
            found
          rescue StandardError
            false
          end
        end

        if const_defined?(:ValidationFocusController, false)
          class ValidationFocusController
            remove_const(:MULTI_FOCUS_RENDERING_OPTION_KEYS) if
              const_defined?(:MULTI_FOCUS_RENDERING_OPTION_KEYS, false)
            MULTI_FOCUS_RENDERING_OPTION_KEYS = [
              RenderingOptionsPolicy::INACTIVE_HIDDEN_KEY
            ].freeze

            RENDERING_POLICY_OPTION_KEYS = (
              HIDDEN_RENDERING_OPTION_KEYS +
              MULTI_FOCUS_RENDERING_OPTION_KEYS +
              [
                RenderingOptionsPolicy::RENDER_MODE_KEY,
                RenderingOptionsPolicy::TEXTURE_KEY
              ]
            ).freeze unless const_defined?(:RENDERING_POLICY_OPTION_KEYS, false)

            unless method_defined?(:set_highlight_before_rendering_options_policy)
              alias_method :set_highlight_before_rendering_options_policy, :set_highlight
            end

            def set_highlight(cell_gml_ids, code = nil, row_id: nil, row_cells: nil,
                              states: nil, transitions: nil, geometry_refs: nil)
              result = set_highlight_before_rendering_options_policy(
                cell_gml_ids,
                code,
                row_id: row_id,
                row_cells: row_cells,
                states: states,
                transitions: transitions,
                geometry_refs: geometry_refs
              )
              RenderingOptionsPolicy.apply_inactive_hidden(
                Sketchup.active_model,
                !@highlight_row_id.nil?
              )
              result
            end

            def capture_and_apply_rendering_options(model, _focus_cell_count)
              capture_rendering_policy_options(model)
              apply_base_edit_rendering_options(model)
            end

            def capture_and_apply_hidden_rendering_options(model)
              capture_rendering_policy_options(model)
              apply_base_edit_rendering_options(model)
            end

            private

            def capture_rendering_policy_options(model)
              options = model&.rendering_options
              return unless options

              @rendering_option_snapshots ||= {}
              RENDERING_POLICY_OPTION_KEYS.each do |key|
                next unless rendering_option_key?(options, key)
                next if @rendering_option_snapshots.key?(key)

                @rendering_option_snapshots[key] = options[key]
              end
            end

            def apply_base_edit_rendering_options(model)
              hidden_values = HIDDEN_RENDERING_OPTION_KEYS.each_with_object({}) do |key, values|
                values[key] = false
              end
              RenderingOptionsPolicy.apply_values(model, hidden_values)
              RenderingOptionsPolicy.apply_inactive_hidden(model, false)
              RenderingOptionsPolicy.apply_shaded(model)
            end
          end
        end

        class EditActivePathController
          unless method_defined?(:set_before_rendering_options_policy)
            alias_method :set_before_rendering_options_policy, :set
          end
          unless method_defined?(:active_path_changed_before_rendering_options_policy)
            alias_method :active_path_changed_before_rendering_options_policy,
                         :active_path_changed
          end

          def set(model, target_path)
            result = set_before_rendering_options_policy(model, target_path)
            apply_rendering_style_for_path(model, target_path)
            result
          end

          def active_path_changed(model, editing:, reenter:)
            result = active_path_changed_before_rendering_options_policy(
              model,
              editing: editing,
              reenter: reenter
            )
            apply_rendering_style_for_path(model, model&.active_path) if editing
            result
          end

          private

          def apply_rendering_style_for_path(model, path)
            fix_mode = @indoor_model.respond_to?(:validation_focus_active?) &&
                       @indoor_model.validation_focus_active?
            primal_group = @indoor_model.primal_group
            cell_space_editing = editing_cell_space_path?(Array(path), primal_group)

            if fix_mode && cell_space_editing
              RenderingOptionsPolicy.apply_monochrome(model)
            else
              RenderingOptionsPolicy.apply_shaded(model)
            end
          rescue StandardError => e
            log("Rendering option update failed: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
