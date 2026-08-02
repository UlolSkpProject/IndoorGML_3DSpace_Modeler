# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class NullProgressRenderer
          def show(_snapshot)
            true
          end

          def update(_snapshot)
            true
          end

          def hide(_snapshot = nil)
            true
          end

          def close
            true
          end
        end
      end
    end
  end
end
