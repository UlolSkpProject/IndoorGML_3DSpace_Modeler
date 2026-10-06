# frozen_string_literal: true

require_relative 'native_bridge'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class AdjacencyService
        module NativeAdjacencyIntegration
          private

          def reset_run_metrics
            super
            @last_native_adjacency_used = false
            @last_native_fallback_count = 0
            @last_native_fallback_reason = nil
            @last_native_serialization_duration = 0.0
            @last_native_parse_duration = 0.0
            @last_native_result_decode_duration = 0.0
            @last_native_input_bytes = 0
            @last_native_output_bytes = 0
          end

          def compute_pair_results(entries, tolerance:, progress: nil)
            return super unless NativeAdjacencyBridge.available?

            prepare_snapshot_waypoint_contexts(entries)
            snapshots = entries.map { |entry| entry[:snapshot] }.freeze
            theoretical_pair_count = snapshots.length * (snapshots.length - 1) / 2
            native_candidate_count = 0
            detailed_started = false
            candidate_finished = false
            last_detailed_progress = 0

            emit_stage_start(
              progress,
              stage: :candidate_generation,
              name: 'Adjacency 후보 생성',
              total: theoretical_pair_count,
              message: "Adjacency 후보 pair 생성: 0 / #{theoretical_pair_count}"
            )

            native_result = NativeAdjacencyBridge.compute(snapshots, tolerance: tolerance) do |event, payload|
              case event
              when :candidate_complete
                native_candidate_count = payload[:candidate_count].to_i
                @last_candidate_generation_duration =
                  payload[:candidate_generation_duration].to_f if payload.key?(:candidate_generation_duration)
                emit_stage_finish(
                  progress,
                  stage: :candidate_generation,
                  name: 'Adjacency 후보 생성',
                  total: theoretical_pair_count,
                  completed: theoretical_pair_count,
                  message: "Adjacency 후보 생성 완료: #{native_candidate_count}개",
                  telemetry: {
                    evaluated_pair_count: theoretical_pair_count,
                    candidate_pair_count: native_candidate_count,
                    broad_phase: :native_z_sweep
                  }
                )
                candidate_finished = true

                emit_stage_start(
                  progress,
                  stage: :detailed_computation,
                  name: 'Adjacency 상세 판정',
                  total: native_candidate_count,
                  message: "Adjacency 상세 판정: 0 / #{native_candidate_count}"
                )
                detailed_started = true
              when :detailed_progress
                current = payload[:current].to_i
                total = payload[:total].to_i
                next unless native_progress_checkpoint?(current, total, last_detailed_progress)

                last_detailed_progress = current
                emit_stage_progress(
                  progress,
                  stage: :detailed_computation,
                  name: 'Adjacency 상세 판정',
                  total: total,
                  completed: current,
                  message: "Adjacency 상세 판정: #{current} / #{total}"
                )
              end
            end

            metrics = Hash(native_result[:metrics])
            native_candidate_count = metrics[:candidate_count].to_i if metrics.key?(:candidate_count)
            @last_pair_comparison_count = native_candidate_count
            @last_candidate_generation_duration = metrics[:candidate_generation_duration].to_f
            @last_detailed_computation_duration = metrics[:narrow_phase_duration].to_f
            @last_native_serialization_duration = metrics[:serialization_duration].to_f
            @last_native_parse_duration = metrics[:parse_duration].to_f
            @last_native_result_decode_duration = metrics[:result_decode_duration].to_f
            @last_native_input_bytes = metrics[:input_bytes].to_i
            @last_native_output_bytes = metrics[:output_bytes].to_i

            unless candidate_finished
              emit_stage_finish(
                progress,
                stage: :candidate_generation,
                name: 'Adjacency 후보 생성',
                total: theoretical_pair_count,
                completed: theoretical_pair_count,
                message: "Adjacency 후보 생성 완료: #{native_candidate_count}개",
                telemetry: {
                  evaluated_pair_count: theoretical_pair_count,
                  candidate_pair_count: native_candidate_count,
                  broad_phase: :native_z_sweep
                }
              )
            end
            unless detailed_started
              emit_stage_start(
                progress,
                stage: :detailed_computation,
                name: 'Adjacency 상세 판정',
                total: native_candidate_count,
                message: "Adjacency 상세 판정: 0 / #{native_candidate_count}"
              )
            end

            native_result[:contexts].each do |index1, index2, context|
              store_snapshot_waypoint_context(index1, index2, context)
            end
            pair_results = Array(native_result[:pair_results])

            emit_stage_finish(
              progress,
              stage: :detailed_computation,
              name: 'Adjacency 상세 판정',
              total: native_candidate_count,
              completed: native_candidate_count,
              message: "Adjacency 상세 판정 완료: #{pair_results.length}개 인접",
              telemetry: {
                candidate_pair_count: native_candidate_count,
                adjacent_pair_count: pair_results.length,
                engine: :native
              }
            )

            @snapshot_waypoint_pair_analysis_count = native_candidate_count
            @snapshot_waypoint_pair_analysis_duration = @last_detailed_computation_duration
            @last_native_adjacency_used = true
            pair_results
          rescue StandardError => e
            @last_native_fallback_count = @last_native_fallback_count.to_i + 1
            @last_native_fallback_reason = "#{e.class}: #{e.message}"
            @last_native_adjacency_used = false
            clear_snapshot_waypoint_contexts
            IndoorCore::Logger.puts(
              "[IndoorGML] Native adjacency failed; falling back to Ruby: #{@last_native_fallback_reason}"
            ) if defined?(IndoorCore::Logger)
            super
          end

          def build_metrics(started_at)
            metrics = super
            metrics[:native_adjacency_used] = @last_native_adjacency_used == true
            metrics[:native_fallback_count] = @last_native_fallback_count.to_i
            metrics[:native_fallback_reason] = @last_native_fallback_reason if @last_native_fallback_reason
            metrics[:native_serialization_duration] = @last_native_serialization_duration.to_f
            metrics[:native_parse_duration] = @last_native_parse_duration.to_f
            metrics[:native_result_decode_duration] = @last_native_result_decode_duration.to_f
            metrics[:native_input_bytes] = @last_native_input_bytes.to_i
            metrics[:native_output_bytes] = @last_native_output_bytes.to_i
            metrics
          end

          def native_progress_checkpoint?(current, total, last_emitted)
            return true if current == total
            return true if current == 1
            return true if current - last_emitted >= PROGRESS_UPDATE_STEP

            false
          end
        end

        prepend NativeAdjacencyIntegration unless ancestors.include?(NativeAdjacencyIntegration)
      end
    end
  end
end
