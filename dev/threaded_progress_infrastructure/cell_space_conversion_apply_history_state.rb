# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class CellSpaceConversionApplyHistoryState
          POSITIONS = %i[
            not_applied
            applied
            undo_requested
            undone
            redo_requested
            redone
          ].freeze

          attr_reader :position

          def initialize
            reset!
          end

          def reset!
            @position = :not_applied
            true
          end

          def mark_applied!
            @position = :applied
            true
          end

          def mark_not_applied!
            @position = :not_applied
            true
          end

          def apply_recorded?
            @position != :not_applied
          end

          def undo_allowed?
            @position == :applied || @position == :redone
          end

          def redo_allowed?
            @position == :undone
          end

          def request_undo!
            return false unless undo_allowed?

            @position = :undo_requested
            true
          end

          def confirm_undone!(matches:)
            return matches == true if @position == :undone
            return false unless @position == :undo_requested

            if matches == true
              @position = :undone
              true
            else
              @position = :applied
              false
            end
          end

          def request_redo!
            return false unless redo_allowed?

            @position = :redo_requested
            true
          end

          def confirm_redone!(matches:)
            return matches == true if @position == :redone
            return false unless @position == :redo_requested

            if matches == true
              @position = :redone
              true
            else
              @position = :undone
              false
            end
          end

          def reject_undo_request!
            return false unless @position == :undo_requested

            @position = :applied
            true
          end

          def reject_redo_request!
            return false unless @position == :redo_requested

            @position = :undone
            true
          end
        end
      end
    end
  end
end
