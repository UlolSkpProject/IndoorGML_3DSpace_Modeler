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
