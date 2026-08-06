# frozen_string_literal: true

require_relative 'lvn_stage_detail_profile_benchmark_guarded'

# Records production handoff use per target without changing geometry decisions.
module LvnFinalCoplanarBaselineHandoffProductionBenchmarkIntegration
  PROFILE_KEY = :final_coplanar_baseline_handoff

  def profile_target(entity, target)
    sample = super
    return sample unless sample[:profile_available]

    profile = lvn_class.last_diagnostic_profile if
      lvn_class.respond_to?(:last_diagnostic_profile)
    handoff = profile && profile[PROFILE_KEY]
    sample[PROFILE_KEY] = handoff.dup if handoff.is_a?(Hash)
    sample
  end

  def aggregate_samples(samples)
    aggregate = super
    entries = samples.filter_map do |sample|
      handoff = sample[PROFILE_KEY]
      [sample, handoff] if handoff.is_a?(Hash)
    end

    role_counts = Hash.new(0)
    rejection_reason_counts = Hash.new(0)
    entries.each do |_sample, handoff|
      role_counts[handoff[:role]] += 1 if handoff[:role]
      Array(handoff[:rejection_reasons]).each do |reason|
        rejection_reason_counts[reason] += 1
      end
    end

    reused = entries.select { |_sample, handoff| handoff[:reused] == true }
    fallback = entries.reject { |_sample, handoff| handoff[:reused] == true }
    aggregate[PROFILE_KEY] = {
      profiled_entity_count: entries.length,
      reused_count: reused.length,
      fallback_count: fallback.length,
      capture_error_count: entries.count do |_sample, handoff|
        !handoff[:capture_error].nil?
      end,
      role_counts: role_counts,
      rejection_reason_counts: rejection_reason_counts,
      fallback_pids: fallback.map { |sample, _handoff| sample[:pid] },
      all_reused: !entries.empty? && fallback.empty?,
      exact_hard_gate_preserved: entries.all? do |_sample, handoff|
        handoff[:exact_hard_gate_preserved] == true
      end,
      fallback_snapshot_preserved: entries.all? do |_sample, handoff|
        handoff[:fallback_snapshot_preserved] == true
      end
    }
    aggregate
  end

  def print_summary(payload, output_path)
    super
    handoff = payload.dig(:aggregate, PROFILE_KEY)
    return unless handoff

    puts '-' * 104
    puts 'FINAL COPLANAR BASELINE HANDOFF PRODUCTION'
    puts format(
      'entities=%d reused=%d fallback=%d capture_errors=%d',
      handoff[:profiled_entity_count],
      handoff[:reused_count],
      handoff[:fallback_count],
      handoff[:capture_error_count]
    )
    roles = handoff[:role_counts].sort_by do |role, _count|
      role.to_s
    end.map do |role, count|
      "#{role}=#{count}"
    end.join(' ')
    puts "roles #{roles}"
    unless handoff[:rejection_reason_counts].empty?
      puts "rejections #{handoff[:rejection_reason_counts].inspect}"
      puts "fallback_pids=#{handoff[:fallback_pids].inspect}"
    end
    puts '=' * 104
  end
end

benchmark_singleton = LvnStageDetailProfileBenchmark.singleton_class
unless benchmark_singleton.ancestors.include?(
  LvnFinalCoplanarBaselineHandoffProductionBenchmarkIntegration
)
  benchmark_singleton.prepend(
    LvnFinalCoplanarBaselineHandoffProductionBenchmarkIntegration
  )
end

nil
