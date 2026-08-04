# frozen_string_literal: true

require 'digest'

# Development-only profiler for repeated
# validate_source_boundary_retriangulation! inputs.
#
# The probe never bypasses validation and never changes its result. It computes
# stable fingerprints, records the original validation outcome/time, and reports
# an upper bound for safe success-only reuse within one normalize_entity call.
module LvnSourceBoundaryValidationReuseProbe
  CLOCK = Process::CLOCK_MONOTONIC
  PROFILE_KEY = :source_boundary_validation_reuse_probe
  TOP_GROUP_LIMIT = 24

  module Extensions
    private

    def normalize_entity(entity)
      profile = @local_vertex_normalizer_debug_profile
      return super unless profile

      previous_context = @lvn_source_boundary_validation_reuse_probe
      context = LvnSourceBoundaryValidationReuseProbe.new_context
      @lvn_source_boundary_validation_reuse_probe = context

      super
    ensure
      if profile && context
        profile[PROFILE_KEY] =
          LvnSourceBoundaryValidationReuseProbe.summarize(context)
        @lvn_source_boundary_validation_reuse_probe = previous_context
      end
    end

    def validate_source_boundary_retriangulation!(
      records,
      loops,
      triangle_keys: nil
    )
      context = @lvn_source_boundary_validation_reuse_probe
      return super unless context

      fingerprint_started = Process.clock_gettime(CLOCK)
      input = nil
      fingerprint_error = nil
      begin
        input = LvnSourceBoundaryValidationReuseProbe.fingerprint_input(
          records,
          loops,
          triangle_keys: triangle_keys,
          point_key_builder: method(:source_precision_indices)
        )
      rescue StandardError => error
        fingerprint_error = error
      ensure
        fingerprint_finished = Process.clock_gettime(CLOCK)
      end

      validation_started = Process.clock_gettime(CLOCK)
      outcome = nil
      result = nil

      begin
        result = super
        outcome = ['success']
        result
      rescue StandardError => error
        outcome = [error.class.name.to_s, error.message.to_s]
        raise
      ensure
        validation_finished = Process.clock_gettime(CLOCK)
        begin
          LvnSourceBoundaryValidationReuseProbe.record_call(
            context,
            input: input,
            fingerprint_error: fingerprint_error,
            fingerprint_seconds: fingerprint_finished - fingerprint_started,
            validation_seconds: validation_finished - validation_started,
            outcome: outcome || ['unknown'],
            role: @local_vertex_normalizer_debug_snapshot_role || :unscoped,
            face_key: @local_vertex_normalizer_exact_polygon_face_key_v2,
            triangle_keys_provided: !triangle_keys.nil?
          )
        rescue StandardError
          context[:recording_failures] += 1
        end
      end
    end
  end

  module_function

  def install!(klass)
    return false if klass.ancestors.include?(Extensions)

    klass.prepend(Extensions)
    true
  end

  def new_context
    {
      calls: 0,
      fingerprint_seconds: 0.0,
      max_fingerprint_seconds: 0.0,
      validation_seconds: 0.0,
      input_construction_failures: 0,
      recording_failures: 0,
      groups: {},
      by_role: {}
    }
  end

  def fingerprint_input(
    records,
    loops,
    triangle_keys: nil,
    point_key_builder: nil
  )
    triangles = if triangle_keys
                  Array(triangle_keys).map do |triangle|
                    canonical_point_sequence(triangle)
                  end
                else
                  raise ArgumentError, 'point_key_builder is required' unless
                    point_key_builder

                  Array(records).map do |record|
                    Array(record[:points]).map do |point|
                      canonical_point(point_key_builder.call(point))
                    end
                  end
                end

    canonical_triangles = triangles.map do |triangle|
      triangle.sort
    end.sort
    ordered_triangles = triangles.map(&:dup)

    ordered_loops = Array(loops).map do |loop|
      canonical_point_sequence(loop)
    end
    boundary_edges = ordered_loops.flat_map do |loop|
      loop.each_index.map do |index|
        canonical_edge(loop[index], loop[(index + 1) % loop.length])
      end
    end.sort

    semantic_payload = [canonical_triangles, boundary_edges]
    ordered_payload = [ordered_triangles, ordered_loops]

    {
      semantic_fingerprint: digest_payload(semantic_payload),
      ordered_fingerprint: digest_payload(ordered_payload),
      triangle_count: triangles.length,
      loop_count: ordered_loops.length,
      boundary_edge_count: boundary_edges.length
    }
  end

  def canonical_point_sequence(points)
    Array(points).map { |point| canonical_point(point) }
  end

  def canonical_point(point)
    values = point.respond_to?(:to_a) ? point.to_a : Array(point)
    values.map do |value|
      integer = Integer(value)
      raise ArgumentError, "non-integral exact coordinate: #{value.inspect}" unless
        integer == value

      integer
    rescue TypeError, ArgumentError
      raise ArgumentError, "invalid exact coordinate: #{value.inspect}"
    end
  end

  def canonical_edge(point_a, point_b)
    (point_a <=> point_b) <= 0 ? [point_a, point_b] : [point_b, point_a]
  end

  def digest_payload(payload)
    Digest::SHA256.hexdigest(Marshal.dump(payload))
  end

  def record_call(
    context,
    input:,
    fingerprint_error:,
    fingerprint_seconds:,
    validation_seconds:,
    outcome:,
    role:,
    face_key:,
    triangle_keys_provided:
  )
    context[:calls] += 1
    context[:fingerprint_seconds] += fingerprint_seconds.to_f
    context[:max_fingerprint_seconds] = [
      context[:max_fingerprint_seconds],
      fingerprint_seconds.to_f
    ].max
    context[:validation_seconds] += validation_seconds.to_f

    role_key = role.to_s
    role_stats = context[:by_role][role_key] ||= {
      calls: 0,
      validation_seconds: 0.0,
      fingerprint_seconds: 0.0
    }
    role_stats[:calls] += 1
    role_stats[:validation_seconds] += validation_seconds.to_f
    role_stats[:fingerprint_seconds] += fingerprint_seconds.to_f

    if fingerprint_error || !input
      context[:input_construction_failures] += 1
      return
    end

    key = input.fetch(:semantic_fingerprint)
    group = context[:groups][key] ||= {
      semantic_fingerprint: key,
      calls: 0,
      validation_seconds: 0.0,
      first_validation_seconds: nil,
      repeat_validation_seconds: 0.0,
      outcomes: {},
      roles: {},
      face_keys: {},
      ordered_fingerprints: {},
      triangle_keys_provided_calls: 0,
      triangle_count: input[:triangle_count],
      loop_count: input[:loop_count],
      boundary_edge_count: input[:boundary_edge_count]
    }

    group[:calls] += 1
    group[:validation_seconds] += validation_seconds.to_f
    if group[:first_validation_seconds]
      group[:repeat_validation_seconds] += validation_seconds.to_f
    else
      group[:first_validation_seconds] = validation_seconds.to_f
    end
    outcome_key = Array(outcome).join("\u0000")
    group[:outcomes][outcome_key] = group[:outcomes].fetch(outcome_key, 0) + 1
    group[:roles][role_key] = group[:roles].fetch(role_key, 0) + 1
    group[:face_keys][face_key.to_s] = true unless face_key.nil?
    ordered_key = input.fetch(:ordered_fingerprint)
    group[:ordered_fingerprints][ordered_key] =
      group[:ordered_fingerprints].fetch(ordered_key, 0) + 1
    group[:triangle_keys_provided_calls] += 1 if triangle_keys_provided
  end

  def summarize(context)
    groups = context[:groups].values
    repeated = groups.select { |group| group[:calls] > 1 }
    successful_repeats = repeated.select do |group|
      group[:outcomes].keys == ['success']
    end
    mixed_outcomes = repeated.select { |group| group[:outcomes].length > 1 }
    failure_repeats = repeated.select do |group|
      group[:outcomes].keys.none? { |outcome| outcome == 'success' }
    end

    semantic_repeat_calls = repeated.sum { |group| group[:calls] - 1 }
    ordered_repeat_calls = groups.sum do |group|
      group[:ordered_fingerprints].values.sum do |count|
        [count - 1, 0].max
      end
    end
    safe_repeat_seconds = successful_repeats.sum do |group|
      group[:repeat_validation_seconds]
    end

    {
      probe_overhead_included: true,
      reuse_scope: 'one normalize_entity invocation',
      failures_are_never_reuse_candidates: true,
      calls: context[:calls],
      unique_semantic_inputs: groups.length,
      repeated_semantic_input_groups: repeated.length,
      semantic_repeat_calls: semantic_repeat_calls,
      ordered_repeat_calls: ordered_repeat_calls,
      representation_only_repeat_calls:
        [semantic_repeat_calls - ordered_repeat_calls, 0].max,
      safe_success_repeat_groups: successful_repeats.length,
      safe_success_repeat_calls: successful_repeats.sum do |group|
        group[:calls] - 1
      end,
      safe_success_repeat_validation_seconds: safe_repeat_seconds,
      mixed_outcome_groups: mixed_outcomes.length,
      failure_only_repeat_groups: failure_repeats.length,
      cross_role_repeat_groups: repeated.count do |group|
        group[:roles].length > 1
      end,
      cross_face_repeat_groups: repeated.count do |group|
        group[:face_keys].length > 1
      end,
      validation_seconds: context[:validation_seconds],
      fingerprint_seconds: context[:fingerprint_seconds],
      max_fingerprint_seconds: context[:max_fingerprint_seconds],
      estimated_net_upper_bound_seconds:
        safe_repeat_seconds - context[:fingerprint_seconds],
      input_construction_failures: context[:input_construction_failures],
      recording_failures: context[:recording_failures],
      by_role: sorted_role_stats(context[:by_role]),
      top_repeated_groups: repeated.sort_by do |group|
        [-group[:repeat_validation_seconds], -group[:calls]]
      end.first(TOP_GROUP_LIMIT).map do |group|
        summarize_group(group)
      end
    }
  end

  def sorted_role_stats(by_role)
    by_role.sort_by do |_role, stats|
      -stats[:validation_seconds]
    end.to_h
  end

  def summarize_group(group)
    {
      fingerprint: group[:semantic_fingerprint][0, 16],
      calls: group[:calls],
      repeat_calls: group[:calls] - 1,
      validation_seconds: group[:validation_seconds],
      repeat_validation_seconds: group[:repeat_validation_seconds],
      outcomes: group[:outcomes].transform_keys do |key|
        key.split("\u0000").join(': ')
      end,
      roles: group[:roles],
      face_key_count: group[:face_keys].length,
      ordered_fingerprint_count: group[:ordered_fingerprints].length,
      triangle_keys_provided_calls: group[:triangle_keys_provided_calls],
      triangle_count: group[:triangle_count],
      loop_count: group[:loop_count],
      boundary_edge_count: group[:boundary_edge_count]
    }
  end

  def aggregate_summaries(samples)
    summaries = Array(samples).filter_map do |sample|
      summary = sample[:source_boundary_validation_reuse_probe]
      [sample, summary] if summary.is_a?(Hash)
    end

    top_groups = summaries.flat_map do |sample, summary|
      Array(summary[:top_repeated_groups]).map do |group|
        group.merge(
          pid: sample[:pid],
          label: sample[:label]
        )
      end
    end.sort_by do |group|
      [-group[:repeat_validation_seconds].to_f, -group[:repeat_calls].to_i]
    end.first(TOP_GROUP_LIMIT)

    numeric_keys = [
      :calls,
      :unique_semantic_inputs,
      :repeated_semantic_input_groups,
      :semantic_repeat_calls,
      :ordered_repeat_calls,
      :representation_only_repeat_calls,
      :safe_success_repeat_groups,
      :safe_success_repeat_calls,
      :safe_success_repeat_validation_seconds,
      :mixed_outcome_groups,
      :failure_only_repeat_groups,
      :cross_role_repeat_groups,
      :cross_face_repeat_groups,
      :validation_seconds,
      :fingerprint_seconds,
      :input_construction_failures,
      :recording_failures
    ]
    result = numeric_keys.to_h do |key|
      [key, summaries.sum { |_sample, summary| summary[key].to_f }]
    end
    integer_keys = numeric_keys - [
      :safe_success_repeat_validation_seconds,
      :validation_seconds,
      :fingerprint_seconds
    ]
    integer_keys.each { |key| result[key] = result[key].to_i }

    result.merge!(
      probe_overhead_included: true,
      reuse_scope: 'one normalize_entity invocation',
      profiled_entity_count: summaries.length,
      max_fingerprint_seconds: summaries.map do |_sample, summary|
        summary[:max_fingerprint_seconds].to_f
      end.max || 0.0,
      estimated_net_upper_bound_seconds:
        result[:safe_success_repeat_validation_seconds] -
        result[:fingerprint_seconds],
      by_role: aggregate_roles(summaries.map(&:last)),
      top_repeated_groups: top_groups
    )
    result
  end

  def aggregate_roles(summaries)
    totals = {}
    summaries.each do |summary|
      Hash(summary[:by_role]).each do |role, stats|
        target = totals[role.to_s] ||= {
          calls: 0,
          validation_seconds: 0.0,
          fingerprint_seconds: 0.0
        }
        target[:calls] += stats[:calls].to_i
        target[:validation_seconds] += stats[:validation_seconds].to_f
        target[:fingerprint_seconds] += stats[:fingerprint_seconds].to_f
      end
    end
    sorted_role_stats(totals)
  end
end

nil
