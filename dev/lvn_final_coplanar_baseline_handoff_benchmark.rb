# frozen_string_literal: true

require_relative 'lvn_stage_detail_profile_benchmark_guarded'
require_relative 'lvn_final_coplanar_baseline_handoff_probe'

core = ULOL::Indoor3DGmlModeler::IndoorCore
LvnRuntimePreflight.verify!(
  target_class: core::LocalVertexNormalizer,
  constant_root: core
)
LvnFinalCoplanarBaselineHandoffProbe.install!(core::LocalVertexNormalizer)

# Adds final-coplanar baseline handoff equivalence results to each stage-detail
# sample and to the aggregate JSON. The current baseline snapshot is always
# executed, so this run measures equivalence and an upper bound rather than an
# optimized production path.
module LvnFinalCoplanarBaselineHandoffBenchmarkIntegration
  def profile_target(entity, target)
    sample = super
    profile = lvn_class.last_debug_profile if
      lvn_class.respond_to?(:last_debug_profile)
    probe = profile && profile[
      LvnFinalCoplanarBaselineHandoffProbe::PROFILE_KEY
    ]
    sample[:final_coplanar_baseline_handoff_probe] = probe if probe
    sample
  end

  def aggregate_samples(samples)
    aggregate = super
    aggregate[:final_coplanar_baseline_handoff_probe] =
      LvnFinalCoplanarBaselineHandoffProbe.aggregate_summaries(samples)
    aggregate
  end

  def print_summary(payload, output_path)
    super
    probe = payload.dig(
      :aggregate,
      :final_coplanar_baseline_handoff_probe
    )
    return unless probe

    puts '-' * 104
    puts 'FINAL COPLANAR BASELINE HANDOFF EQUIVALENCE PROBE'
    puts format(
      'entities=%d candidates=%d baselines=%d equivalent=%d mismatches=%d',
      probe[:profiled_entity_count],
      probe[:candidate_available_count],
      probe[:baseline_available_count],
      probe[:fully_equivalent_count],
      probe[:mismatch_count]
    )
    puts format(
      'baseline=%10.6fs removable=%10.6fs capture=%10.6fs compare=%10.6fs',
      probe[:baseline_snapshot_seconds],
      probe[:removable_baseline_snapshot_seconds],
      probe[:candidate_capture_seconds],
      probe[:comparison_seconds]
    )
    roles = probe[:candidate_role_counts].sort_by do |role, _count|
      role.to_s
    end.map do |role, count|
      "#{role}=#{count}"
    end.join(' ')
    puts "roles #{roles}"
    puts "mismatch_pids=#{probe[:mismatch_pids].inspect}" unless
      probe[:mismatch_pids].empty?
    puts '=' * 104
  end
end

benchmark_singleton = LvnStageDetailProfileBenchmark.singleton_class
unless benchmark_singleton.ancestors.include?(
  LvnFinalCoplanarBaselineHandoffBenchmarkIntegration
)
  benchmark_singleton.prepend(
    LvnFinalCoplanarBaselineHandoffBenchmarkIntegration
  )
end

nil
