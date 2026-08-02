# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class WriteUndoFaultPlan
          attr_reader :item_count,
                      :cancel_after_prepared_items,
                      :fail_after_created_items

          def initialize(
            item_count:,
            cancel_after_prepared_items: nil,
            fail_after_created_items: nil
          )
            @item_count = [item_count.to_i, 1].max
            @cancel_after_prepared_items = normalize_cancel_threshold(
              cancel_after_prepared_items
            )
            @fail_after_created_items = normalize_failure_threshold(
              fail_after_created_items
            )
          end

          def cancellation_enabled?
            !@cancel_after_prepared_items.nil?
          end

          def failure_enabled?
            !@fail_after_created_items.nil?
          end

          def cancel_after_prepare?(prepared_items)
            return false unless cancellation_enabled?

            prepared_items.to_i >= @cancel_after_prepared_items
          end

          def fail_before_next_create?(created_items)
            return false unless failure_enabled?

            created_items.to_i >= @fail_after_created_items
          end

          private

          def normalize_cancel_threshold(value)
            return nil if value.nil?

            threshold = value.to_i
            unless threshold.between?(1, @item_count)
              raise ArgumentError,
                    "cancel_after_prepared_items must be within 1..#{@item_count}"
            end
            threshold
          end

          def normalize_failure_threshold(value)
            return nil if value.nil?

            threshold = value.to_i
            unless threshold.between?(1, @item_count - 1)
              raise ArgumentError,
                    "fail_after_created_items must be within 1...#{@item_count}"
            end
            threshold
          end
        end
      end
    end
  end
end
