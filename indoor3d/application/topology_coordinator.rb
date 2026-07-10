# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class DirtyTopologyQueue
        def initialize
          @persistent_ids = {}
          @scheduled = false
          @generation = 0
        end

        def mark(persistent_id)
          @persistent_ids[persistent_id] = true
        end

        def persistent_ids
          @persistent_ids.keys
        end

        def empty?
          @persistent_ids.empty?
        end

        def clear
          @persistent_ids.clear
        end

        def scheduled?
          @scheduled == true
        end

        def schedule!
          @scheduled = true
        end

        def unschedule!
          @scheduled = false
        end

        def generation
          @generation ||= 0
        end

        def invalidate!
          @generation = generation + 1
          clear
          unschedule!
          true
        end

        def requeue_from(persistent_ids, failed_index)
          remaining = failed_index ? persistent_ids[failed_index..] : persistent_ids
          Array(remaining).each { |persistent_id| mark(persistent_id) }
        end

        def snapshot
          {
            persistent_ids: @persistent_ids.dup,
            scheduled: @scheduled,
            generation: generation
          }
        end

        def restore!(snapshot)
          @persistent_ids = Hash(snapshot[:persistent_ids]).dup
          @scheduled = snapshot[:scheduled] == true
          @generation = snapshot[:generation].to_i
          true
        end
      end

      class TopologyCoordinator
        attr_reader :dirty_queue

        def initialize(adjacency_service: nil, dirty_queue: DirtyTopologyQueue.new)
          @adjacency_service = adjacency_service
          @dirty_queue = dirty_queue
        end

        def synchronize_for(cell_space)
          @adjacency_service.synchronize_for(cell_space)
        end

        def synchronize_all(**kwargs)
          @adjacency_service.synchronize_all(**kwargs)
        end

        def erase_for(cell_space)
          @adjacency_service.erase_for(cell_space)
        end

        def cell_pair_key(cell1, cell2)
          @adjacency_service.cell_pair_key(cell1, cell2)
        end

        def last_metrics
          @adjacency_service&.last_metrics || {}
        end

        def snapshot
          { dirty_queue: @dirty_queue.snapshot }
        end

        def restore!(snapshot)
          @dirty_queue.restore!(Hash(snapshot[:dirty_queue]))
          true
        end
      end
    end
  end
end
