# frozen_string_literal: true

require_relative 'overlay_prototype'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressOverlayPrototype
        class ProgressOverlay
          private

          def detail_text(snapshot)
            percent = normalized_percent(snapshot[:percent])
            elapsed = format('%.2fs', snapshot[:elapsed].to_f)
            total = snapshot[:total].to_i
            return format('%6.2f%%   %s   %s', percent, snapshot[:type], elapsed) unless total.positive?

            completed = snapshot[:completed].to_i
            count_label = snapshot[:count_label].to_s.strip
            count_label = '완료' if count_label.empty?
            show_current = snapshot.fetch(:show_current_item_progress, true) == true

            if snapshot[:terminal] || !show_current
              return format(
                '%6.2f%%   %s %d / %d   %s',
                percent,
                count_label,
                completed,
                total,
                elapsed
              )
            end

            current_item = [[snapshot[:current_item].to_i, 1].max, total].min
            current_item_percent = normalized_percent(snapshot[:current_item_percent])
            format(
              '%6.2f%%   %s %d / %d   현재 %d번 %.1f%%   %s',
              percent,
              count_label,
              completed,
              total,
              current_item,
              current_item_percent,
              elapsed
            )
          end
        end
      end
    end
  end
end

puts '[THREADED PROGRESS OVERLAY SEMANTICS PATCH] installed'
