# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class BulkCellSpaceConversionService
        private

        # CellSpace timing output is diagnostic only. Runtime metrics stay
        # available on Result#metrics for UI/result reporting.
        def log_timing_metrics(metrics)
          @logger.debug do
            [
              '----------------------------------------',
              'Create CellSpace 시간 요약',
              format('  전체 시간                  : %.3f sec', metrics[:total_duration].to_f),
              format('  시작 전 검사               : %.3f sec', metrics[:preflight_duration].to_f),
              format('  CellSpace/State 생성       : %.3f sec', metrics[:cell_space_state_duration].to_f),
              format('  Adjacency/Transition 생성  : %.3f sec', metrics[:adjacency_transition_duration].to_f),
              '----------------------------------------'
            ].join("\n")
          end
        end
      end
    end
  end
end
