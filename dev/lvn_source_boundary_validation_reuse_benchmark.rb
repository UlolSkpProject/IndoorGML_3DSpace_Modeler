# frozen_string_literal: true

require_relative 'lvn_stage_detail_profile_benchmark_guarded'
require_relative 'lvn_source_boundary_validation_reuse_probe'

core = ULOL::Indoor3DGmlModeler::IndoorCore
LvnRuntimePreflight.verify!(
  target_class: core::LocalVertexNormalizer,
  constant_root: core
)
LvnSourceBoundaryValidationReuseProbe.install!(core::LocalVertexNormalizer)

# Adds the development-only reuse probe to each stage-detail sample and to the
# aggregate JSON. The underlying validator is always executed; measured timing
# includes fingerprint overhead and is not a production performance baseline.
module LvnSourceBoundaryValidationReuseBenchmarkIntegration
  def profile_target(entity, target)
    sample = super
    profile = lvn_class.last_debug_profile if
      lvn_class.respond_to?(:last_debug_profile)
    probe = profile && profile[
      LvnSourceBoundaryValidationReuseProbe::PROFILE_KEY
    ]
    sample[:source_boundary_validation_reuse_probe] = probe if probe
    sample
  end

  def aggregate_samples(samples)
    aggregate = super
    aggregate[:source_boundary_validation_reuse_probe] =
      LvnSourceBoundaryValidationReuseProbe.aggregate_summaries(samples)
    aggregate
  end

  def print_summary(payload, output_path)
    super
    probe = payload.dig(
      :aggregate,
      :source_boundary_validation_reuse_probe
    )
    return unless probe

    puts '-' * 104
    puts 'SOURCE-BOUNDARY VALIDATION REUSE PROBE'
    puts format(
      'calls=%d unique=%d repeats=%d safe_repeats=%d mixed=%d',
      probe[:calls],
      probe[:unique_semantic_inputs],
      probe[:semantic_repeat_calls],
      probe[:safe_success_repeat_calls],
      probe[:mixed_outcome_groups]
    )
    puts format(
      'validation=%10.6fs fingerprint=%10.6fs safe_repeat=%10.6fs net_upper_bound=%10.6fs',
      probe[:validation_seconds],
      probe[:fingerprint_seconds],
      probe[:safe_success_repeat_validation_seconds],
      probe[:estimated_net_upper_bound_seconds]
    )
    puts format(
      'ordered_repeats=%d representation_only=%d cross_role_groups=%d cross_face_groups=%d',
      probe[:ordered_repeat_calls],
      probe[:representation_only_repeat_calls],
      probe[:cross_role_repeat_groups],
      probe[:cross_face_repeat_groups]
    )
    puts '=' * 104
  end
end

benchmark_singleton = LvnStageDetailProfileBenchmark.singleton_class
unless benchmark_singleton.ancestors.include?(
  LvnSourceBoundaryValidationReuseBenchmarkIntegration
)
  benchmark_singleton.prepend(
    LvnSourceBoundaryValidationReuseBenchmarkIntegration
  )
end

nil
