# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        # Key policy and transactional snapshots. Entity Hidden/Tag changes belong
        # to ValidationFocusVisibilityService; Camera and Overlay are separate.
        module RenderingOptionsPolicy
          INACTIVE_HIDDEN_KEY = 'InactiveHidden'
          MODEL_TRANSPARENCY_KEY = 'ModelTransparency'
          RENDER_MODE_KEY = 'RenderMode'
          TEXTURE_KEY = 'Texture'
          SHADED_RENDER_MODE = 2
          MONOCHROME_RENDER_MODE = 5
          HIDDEN_RENDERING_OPTION_KEYS = %w[
            ROPDrawHiddenObjects ROPDrawHiddenGeometry
            DrawHiddenObjects DrawHiddenGeometry DrawHidden
          ].freeze

          module_function

          def base_edit
            HIDDEN_RENDERING_OPTION_KEYS.each_with_object({}) { |key, values| values[key] = false }.merge(
              INACTIVE_HIDDEN_KEY => false,
              RENDER_MODE_KEY => SHADED_RENDER_MODE,
              TEXTURE_KEY => false
            )
          end

          def validation_session
            base_edit.merge(MODEL_TRANSPARENCY_KEY => false)
          end

          # The existing ISO/focus camera and error geometry are not involved.
          # A direct Primal child edit uses transparency, but only a genuine
          # CellSpace edit uses the monochrome style.
          def current_context(validation:, path:, primal_group:, cell_space_editing:, row_selected:)
            group_editing = validation && Array(path).length > 1 && Array(path).first == primal_group
            {
              validation: validation == true,
              group_editing: group_editing,
              cell_space_editing: validation && cell_space_editing == true,
              row_selected: validation && row_selected == true
            }
          end

          def context_values(context)
            return {
              RENDER_MODE_KEY => SHADED_RENDER_MODE,
              TEXTURE_KEY => false
            } unless context[:validation]

            {
              INACTIVE_HIDDEN_KEY => context[:row_selected] && !context[:group_editing],
              MODEL_TRANSPARENCY_KEY => context[:group_editing],
              RENDER_MODE_KEY => context[:cell_space_editing] ? MONOCHROME_RENDER_MODE : SHADED_RENDER_MODE,
              TEXTURE_KEY => false
            }
          end

          def rendering_option_key?(options, key)
            return options.key?(key) if options.respond_to?(:key?)
            return options.keys.include?(key) if options.respond_to?(:keys)

            return false unless options.respond_to?(:each_key)

            found = false
            options.each_key { |candidate| found = true if candidate == key }
            found
          end

          # Only one owner modifies RenderingOptions. Scope precedence:
          # edit < session < row (the row scope also covers geometry context).
          class Manager
            SCOPES = %i[edit session row].freeze

            def initialize
              clear
            end

            def capture(model, scope:)
              validate_scope!(scope)
              ensure_model!(model)
              @snapshots[scope] ||= {}
              result
            rescue StandardError => e
              failure(scope, e.message)
            end

            def apply(model, scope:, values:)
              validate_scope!(scope)
              ensure_model!(model)
              options = model.rendering_options
              raise 'RenderingOptions unavailable' unless options

              scope_snapshot = (@snapshots[scope] ||= {})
              applied = []
              new_keys = []
              errors = {}
              Array(values.to_a).each do |key, value|
                begin
                  next unless RenderingOptionsPolicy.rendering_option_key?(options, key)

                  current = options[key]
                  ensure_unmodified!(key, current)
                  next if current == value

                  unless scope_snapshot.key?(key)
                    scope_snapshot[key] = current
                    new_keys << key
                  end
                  # Register undo before the setter; SketchUp may mutate and raise.
                  applied << [key, current]
                  options[key] = value
                  raise "RenderingOptions[#{key}] did not accept value" unless options[key] == value

                  @last_written[key] = value
                rescue StandardError => e
                  errors[key] = e.message
                  break
                end
              end

              unless errors.empty?
                rollback_errors = rollback(options, applied)
                new_keys.each do |key|
                  scope_snapshot.delete(key) unless rollback_errors.key?("rollback:#{key}")
                end
                errors.merge!(rollback_errors)
                invalidate(model) unless applied.empty?
                return { ok: false, changed_keys: [], errors: errors }
              end
              invalidate(model) unless applied.empty?
              { ok: true, changed_keys: applied.map(&:first), errors: {} }
            rescue StandardError => e
              failure(scope, e.message)
            end

            def restore(model, scope:)
              validate_scope!(scope)
              return result(restored: false) unless @snapshots[scope]&.any?

              ensure_model!(model)
              options = model.rendering_options
              raise 'RenderingOptions unavailable' unless options

              changed = []
              errors = {}
              @snapshots[scope].to_a.reverse_each do |key, original|
                begin
                  raise "RenderingOptions key missing: #{key}" unless RenderingOptionsPolicy.rendering_option_key?(options, key)

                  current = options[key]
                  ensure_unmodified!(key, current)
                  if current != original
                    options[key] = original
                    raise "RenderingOptions[#{key}] restore did not take effect" unless options[key] == original

                    changed << key
                  end
                  @last_written[key] = original
                  @snapshots[scope].delete(key)
                rescue StandardError => e
                  errors[key] = e.message
                end
              end
              invalidate(model) unless changed.empty?
              { ok: errors.empty?, restored: errors.empty?, changed_keys: changed, errors: errors }
            rescue StandardError => e
              failure(scope, e.message)
            end

            def restore_all(model)
              errors = {}
              changed = []
              %i[row session edit].each do |scope|
                scope_result = restore(model, scope: scope)
                changed.concat(Array(scope_result[:changed_keys]))
                errors[scope] = scope_result[:errors] unless scope_result[:ok]
                break unless scope_result[:ok] # Do not overwrite an unresolved higher scope.
              end
              clear if errors.empty?
              { ok: errors.empty?, changed_keys: changed, errors: errors }
            end

            def clear
              @model = nil
              @snapshots = {}
              @last_written = {}
              result(discarded: true)
            end

            def captured?(scope)
              @snapshots[scope]&.any? == true
            end

            private

            def validate_scope!(scope)
              raise ArgumentError, "Unsupported RenderingOptions scope: #{scope}" unless SCOPES.include?(scope)
            end

            def ensure_model!(model)
              raise 'RenderingOptions Model is unavailable' unless model
              raise 'RenderingOptions Model is invalid' if model.respond_to?(:valid?) && !model.valid?
              if defined?(Sketchup) && Sketchup.respond_to?(:active_model)
                active_model = Sketchup.active_model
                raise 'RenderingOptions active Model mismatch' if active_model && !active_model.equal?(model)
              end
              raise 'RenderingOptions Model mismatch' if @model && !@model.equal?(model)

              @model ||= model
            end

            def ensure_unmodified!(key, current)
              return unless @last_written.key?(key)
              return if current == @last_written[key]

              raise "RenderingOptions[#{key}] changed outside policy manager"
            end

            def rollback(options, applied)
              errors = {}
              applied.reverse_each do |key, original|
                begin
                  options[key] = original unless options[key] == original
                  @last_written[key] = original
                rescue StandardError => e
                  errors["rollback:#{key}"] = e.message
                end
              end
              errors
            end

            def invalidate(model)
              model.active_view.invalidate if model.respond_to?(:active_view) && model.active_view&.respond_to?(:invalidate)
            rescue StandardError => e
              RenderingOptionsPolicy.log_failure('view invalidate', e)
            end

            def result(**extra)
              { ok: true, changed_keys: [], errors: {} }.merge(extra)
            end

            def failure(scope, message)
              { ok: false, changed_keys: [], errors: { scope => message } }
            end
          end

          def log_failure(context, error)
            return unless defined?(IndoorCore::Logger) && IndoorCore::Logger.respond_to?(:puts)

            IndoorCore::Logger.puts("[IndoorGML] RenderingOptions #{context}: #{error.class}: #{error.message}")
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
