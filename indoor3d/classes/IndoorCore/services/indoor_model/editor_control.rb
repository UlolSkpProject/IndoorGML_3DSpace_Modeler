# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class IndoorModel
        module EditorControl
          def begin_editing
            @editor_session.begin_editing()
          end

          def finish_editing
            @editor_session.finish()
          end

          def editing?
            @editor_session.editing?()
          end

          def state_radius
            State.display_radius
          end

          def set_state_radius(radius)
            radius = radius.to_f
            return false unless radius.positive?

            model = Sketchup.active_model()
            model.start_operation('Set IndoorGML State Radius', true)
            begin
              State.display_radius = radius
              @states.each do |state|
                next unless state&.valid?

                with_unlocked(state.sketchup_component_instance) { state.apply_radius(radius) }
                write_state_attributes(state)
              end
              @transitions.each do |transition|
                next unless transition&.valid?

                write_transition_attributes(transition) if update_transition(transition)
              end
              model.active_view.invalidate if model&.active_view
              model.commit_operation
              true
            rescue StandardError => e
              model.abort_operation
              puts "[IndoorGML] State radius update failed: #{e.class}: #{e.message}"
              false
            end
          end

          def active_path_changed(model)
            @editor_session.active_path_changed(model)
          end

          def cleanup_before_quit
            @editor_session.cleanup_before_quit()
          end

          private

          def apply_indoor_lock_policy
            @editor_session.apply_lock_policy()
          end
        end
      end
    end
  end
end
