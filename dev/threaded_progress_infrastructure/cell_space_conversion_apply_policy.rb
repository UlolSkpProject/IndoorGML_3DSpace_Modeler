# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class CellSpaceConversionApplyPolicy
          DEFAULT_MAX_APPLY_JOBS = 5

          Decision = Struct.new(:allowed, :reason, keyword_init: true) do
            def allowed?
              allowed == true
            end
          end

          def initialize(max_apply_jobs: DEFAULT_MAX_APPLY_JOBS)
            @max_apply_jobs = [max_apply_jobs.to_i, 1].max
          end

          def evaluate(preflight_type:, job_count:, plan_count:, error_count:)
            return denied(:preflight_not_completed) unless preflight_type.to_sym == :completed
            return denied(:no_jobs) unless job_count.to_i.positive?
            return denied(:job_limit_exceeded) if job_count.to_i > @max_apply_jobs
            return denied(:preflight_errors) if error_count.to_i.positive?
            return denied(:empty_plan) unless plan_count.to_i.positive?
            return denied(:plan_count_mismatch) unless plan_count.to_i == job_count.to_i

            Decision.new(allowed: true, reason: :allowed).freeze
          end

          attr_reader :max_apply_jobs

          private

          def denied(reason)
            Decision.new(allowed: false, reason: reason).freeze
          end
        end
      end
    end
  end
end
