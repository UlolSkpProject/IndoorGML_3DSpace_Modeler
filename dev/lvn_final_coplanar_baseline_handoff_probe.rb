# frozen_string_literal: true

# Development-only probe for reusing the already validated final triangle
# snapshot as final_coplanar_face_merge_v2's rollback baseline.
#
# The existing baseline snapshot, validation, and rollback behavior are never
# bypassed. This probe only captures the inner pipeline candidate, compares it
# with the independently rebuilt baseline, and records the removable-time upper
# bound when every geometry, orientation, metadata, topology, and grid check
# agrees.
module LvnFinalCoplanarBaselineHandoffProbe
  CLOCK = Process::CLOCK_MONOTONIC
  PROFILE_KEY = :final_coplanar_baseline_handoff_probe
  SAMPLE_LIMIT = 12

  module Extensions
    private

    def normalize_entity(entity)
      profile = @local_vertex_normalizer_debug_profile
      return super unless profile

      previous_context = @lvn_final_coplanar_baseline_handoff_probe
      context = LvnFinalCoplanarBaselineHandoffProbe.new_context(entity)
      @lvn_final_coplanar_baseline_handoff_probe = context

      super
    ensure
      if profile && context
        profile[PROFILE_KEY] =
          LvnFinalCoplanarBaselineHandoffProbe.summarize(context)
        @lvn_final_coplanar_baseline_handoff_probe = previous_context
      end
    end

    def max_grid_residual_mm(vertices)
      result = super
      context = @lvn_final_coplanar_baseline_handoff_probe
      if context && !context[:measuring_baseline_grid_residual]
        context[:last_grid_residual_mm] = result
      end
      result
    end

    def final_normalized_mesh_state(
      entities,
      expected_triangles,
      final_repair,
      topology_after,
      post_cleanup_snapshot,
      duplicate_diagnostics
    )
      result = super
      context = @lvn_final_coplanar_baseline_handoff_probe
      return result unless context && result.is_a?(Array)

      reuse_decision = result[4]
      role = if reuse_decision.is_a?(Hash) && reuse_decision[:reused]
               :post_coplanar_cleanup
             else
               :final_fallback
             end
      capture_final_coplanar_handoff_candidate_v2(
        context,
        result[0],
        role: role,
        entities: entities,
        topology: topology_after,
        mesh_validation: result[2]
      )
      result
    end

    def snapshot_final_coplanar_baseline(entities)
      context = @lvn_final_coplanar_baseline_handoff_probe
      return super unless context

      candidate = context[:candidate]
      candidate ||= normalized_input_fast_path_handoff_candidate_v2(
        context,
        entities
      )

      started_at = Process.clock_gettime(CLOCK)
      baseline = super
      baseline_seconds = Process.clock_gettime(CLOCK) - started_at

      comparison_started_at = Process.clock_gettime(CLOCK)
      baseline_topology = geometry_counts(entities)
      context[:measuring_baseline_grid_residual] = true
      baseline_grid_residual_mm = max_grid_residual_mm(
        geometry_vertices(entities)
      )
      context[:measuring_baseline_grid_residual] = false
      baseline_inventory = if baseline
                             final_coplanar_handoff_inventory_v2(baseline)
                           end
      comparison = LvnFinalCoplanarBaselineHandoffProbe.compare(
        candidate,
        baseline_inventory: baseline_inventory,
        baseline_topology: baseline_topology,
        baseline_grid_residual_mm: baseline_grid_residual_mm,
        baseline_snapshot_seconds: baseline_seconds
      )
      comparison_seconds =
        Process.clock_gettime(CLOCK) - comparison_started_at

      comparison[:comparison_seconds] = comparison_seconds
      context[:baseline_snapshot_seconds] += baseline_seconds
      context[:comparison_seconds] += comparison_seconds
      context[:comparisons] << comparison
      baseline
    ensure
      context[:measuring_baseline_grid_residual] = false if context
    end

    def normalized_input_fast_path_handoff_candidate_v2(context, entities)
      baseline = @normalized_input_fast_path_baseline_v2
      return nil unless baseline.is_a?(Hash)
      return nil unless baseline[:entities_object_id] == entities.object_id

      current_topology = geometry_counts(entities)
      return nil unless baseline[:topology] == current_topology

      capture_final_coplanar_handoff_candidate_v2(
        context,
        baseline[:triangles],
        role: :normalized_input_fast_path,
        entities: entities,
        topology: baseline[:topology],
        mesh_validation: nil
      )
      context[:candidate]
    rescue StandardError => error
      context[:candidate_capture_error] =
        "#{error.class}: #{error.message}"
      nil
    end

    def capture_final_coplanar_handoff_candidate_v2(
      context,
      triangles,
      role:,
      entities:,
      topology:,
      mesh_validation:
    )
      started_at = Process.clock_gettime(CLOCK)
      inventory = final_coplanar_handoff_inventory_v2(triangles)
      context[:candidate] = {
        available: true,
        role: role,
        entities_object_id: entities.object_id,
        topology: topology && topology.dup,
        grid_residual_mm: context[:last_grid_residual_mm],
        mesh_validation: mesh_validation && mesh_validation.dup,
        inventory: inventory
      }
      context[:candidate_capture_seconds] +=
        Process.clock_gettime(CLOCK) - started_at
      context[:candidate]
    rescue StandardError => error
      context[:candidate_capture_error] =
        "#{error.class}: #{error.message}"
      nil
    end

    def final_coplanar_handoff_inventory_v2(records)
      LvnFinalCoplanarBaselineHandoffProbe.build_inventory(
        records,
        point_key_builder: method(:grid_indices),
        metadata_identity_builder: method(:metadata_identity)
      )
    end
  end

  module_function

  def install!(klass)
    return false if klass.ancestors.include?(Extensions)

    klass.prepend(Extensions)
    true
  end

  def new_context(entity = nil)
    {
      entity_object_id: entity&.object_id,
      candidate: nil,
      candidate_capture_error: nil,
      candidate_capture_seconds: 0.0,
      baseline_snapshot_seconds: 0.0,
      comparison_seconds: 0.0,
      last_grid_residual_mm: nil,
      measuring_baseline_grid_residual: false,
      comparisons: []
    }
  end

  def build_inventory(
    records,
    point_key_builder:,
    metadata_identity_builder:
  )
    entries = Array(records).map do |record|
      points = Array(record[:points]).map do |point|
        Array(point_key_builder.call(point)).map { |value| Integer(value) }
      end
      raise ArgumentError, 'Triangle record must contain three points' unless
        points.length == 3

      oriented = oriented_triangle_key(points)
      canonical = canonical_triangle_key(points)
      source_normal = normal_key(record[:source_normal])
      metadata = [
        metadata_key(metadata_identity_builder.call(record[:material])),
        metadata_key(metadata_identity_builder.call(record[:back_material])),
        metadata_key(metadata_identity_builder.call(record[:layer]))
      ].join('|')
      {
        canonical: canonical,
        oriented: oriented,
        normal: "#{oriented}|#{source_normal}",
        metadata: "#{oriented}|#{metadata}"
      }
    end

    {
      triangle_count: entries.length,
      canonical_triangles: entries.map { |entry| entry[:canonical] }.sort,
      oriented_triangles: entries.map { |entry| entry[:oriented] }.sort,
      source_normals: entries.map { |entry| entry[:normal] }.sort,
      metadata: entries.map { |entry| entry[:metadata] }.sort
    }
  end

  def point_key(point)
    Array(point).map { |value| Integer(value) }.join(',')
  end

  def canonical_triangle_key(points)
    points.map { |point| point_key(point) }.sort.join(';')
  end

  def oriented_triangle_key(points)
    keys = points.map { |point| point_key(point) }
    [
      keys,
      [keys[1], keys[2], keys[0]],
      [keys[2], keys[0], keys[1]]
    ].map { |rotation| rotation.join(';') }.min
  end

  def normal_key(normal)
    Array(normal).map do |value|
      format('%.15g', Float(value))
    end.join(',')
  end

  def metadata_key(identity)
    identity.nil? ? 'nil' : identity.inspect
  end

  def compare(
    candidate,
    baseline_inventory:,
    baseline_topology:,
    baseline_grid_residual_mm:,
    baseline_snapshot_seconds:
  )
    result = {
      candidate_available: candidate.is_a?(Hash) &&
        candidate[:available] == true,
      candidate_role: candidate && candidate[:role],
      baseline_available: !baseline_inventory.nil?,
      baseline_snapshot_seconds: baseline_snapshot_seconds.to_f,
      triangle_count_match: false,
      canonical_triangle_set_match: false,
      orientation_match: false,
      source_normal_match: false,
      metadata_match: false,
      topology_match: false,
      grid_residual_match: false,
      fully_equivalent: false,
      mismatch_samples: {}
    }
    return result unless result[:candidate_available] &&
                         result[:baseline_available]

    candidate_inventory = candidate.fetch(:inventory)
    result[:triangle_count_match] =
      candidate_inventory[:triangle_count] ==
      baseline_inventory[:triangle_count]
    result[:canonical_triangle_set_match] = compare_inventory_field(
      result,
      :canonical_triangles,
      candidate_inventory,
      baseline_inventory
    )
    result[:orientation_match] = compare_inventory_field(
      result,
      :oriented_triangles,
      candidate_inventory,
      baseline_inventory
    )
    result[:source_normal_match] = compare_inventory_field(
      result,
      :source_normals,
      candidate_inventory,
      baseline_inventory
    )
    result[:metadata_match] = compare_inventory_field(
      result,
      :metadata,
      candidate_inventory,
      baseline_inventory
    )
    result[:topology_match] = candidate[:topology] == baseline_topology
    result[:grid_residual_match] = residuals_equal?(
      candidate[:grid_residual_mm],
      baseline_grid_residual_mm
    )
    result[:candidate_triangle_count] = candidate_inventory[:triangle_count]
    result[:baseline_triangle_count] = baseline_inventory[:triangle_count]
    result[:candidate_topology] = candidate[:topology]
    result[:baseline_topology] = baseline_topology
    result[:candidate_grid_residual_mm] = candidate[:grid_residual_mm]
    result[:baseline_grid_residual_mm] = baseline_grid_residual_mm
    result[:fully_equivalent] = [
      :triangle_count_match,
      :canonical_triangle_set_match,
      :orientation_match,
      :source_normal_match,
      :metadata_match,
      :topology_match,
      :grid_residual_match
    ].all? { |key| result[key] == true }
    result
  end

  def compare_inventory_field(
    result,
    field,
    candidate_inventory,
    baseline_inventory
  )
    candidate_values = candidate_inventory.fetch(field)
    baseline_values = baseline_inventory.fetch(field)
    return true if candidate_values == baseline_values

    result[:mismatch_samples][field] = {
      missing_from_baseline: (candidate_values - baseline_values).first(SAMPLE_LIMIT),
      added_in_baseline: (baseline_values - candidate_values).first(SAMPLE_LIMIT)
    }
    false
  end

  def residuals_equal?(candidate, baseline)
    return false if candidate.nil? || baseline.nil?

    (candidate.to_f - baseline.to_f).abs <= 1.0e-12
  end

  def summarize(context)
    comparison = context[:comparisons].last || {
      candidate_available: !context[:candidate].nil?,
      candidate_role: context.dig(:candidate, :role),
      baseline_available: false,
      baseline_snapshot_seconds: 0.0,
      fully_equivalent: false,
      mismatch_samples: {}
    }
    comparison.merge(
      comparison_count: context[:comparisons].length,
      candidate_capture_seconds: context[:candidate_capture_seconds],
      comparison_seconds: context[:comparison_seconds],
      candidate_capture_error: context[:candidate_capture_error],
      probe_overhead_included: true,
      existing_baseline_was_not_bypassed: true
    )
  end

  def aggregate_summaries(samples)
    entries = Array(samples).filter_map do |sample|
      probe = sample[:final_coplanar_baseline_handoff_probe] ||
        sample['final_coplanar_baseline_handoff_probe']
      next unless probe

      [sample, symbolize_keys(probe)]
    end

    role_counts = Hash.new(0)
    mismatch_pids = []
    mismatch_details = []
    entries.each do |sample, probe|
      role_counts[probe[:candidate_role]] += 1 if probe[:candidate_role]
      next if probe[:fully_equivalent]

      pid = sample[:pid] || sample['pid']
      mismatch_pids << pid
      mismatch_details << {
        pid: pid,
        label: sample[:label] || sample['label'],
        candidate_role: probe[:candidate_role],
        candidate_available: probe[:candidate_available],
        baseline_available: probe[:baseline_available],
        mismatch_samples: probe[:mismatch_samples],
        candidate_capture_error: probe[:candidate_capture_error]
      }
    end

    equivalent = entries.select { |_sample, probe| probe[:fully_equivalent] }
    {
      profiled_entity_count: entries.length,
      candidate_available_count: entries.count do |_sample, probe|
        probe[:candidate_available]
      end,
      baseline_available_count: entries.count do |_sample, probe|
        probe[:baseline_available]
      end,
      fully_equivalent_count: equivalent.length,
      mismatch_count: mismatch_pids.length,
      mismatch_pids: mismatch_pids,
      mismatch_details: mismatch_details.first(SAMPLE_LIMIT),
      candidate_role_counts: role_counts,
      baseline_snapshot_seconds: entries.sum do |_sample, probe|
        probe[:baseline_snapshot_seconds].to_f
      end,
      removable_baseline_snapshot_seconds: equivalent.sum do |_sample, probe|
        probe[:baseline_snapshot_seconds].to_f
      end,
      candidate_capture_seconds: entries.sum do |_sample, probe|
        probe[:candidate_capture_seconds].to_f
      end,
      comparison_seconds: entries.sum do |_sample, probe|
        probe[:comparison_seconds].to_f
      end,
      candidate_capture_error_count: entries.count do |_sample, probe|
        !probe[:candidate_capture_error].nil?
      end,
      all_equivalent: !entries.empty? && mismatch_pids.empty?,
      probe_overhead_included: true,
      existing_baseline_was_not_bypassed: true
    }
  end

  def symbolize_keys(value)
    return value unless value.is_a?(Hash)

    value.each_with_object({}) do |(key, nested), result|
      symbol = key.respond_to?(:to_sym) ? key.to_sym : key
      result[symbol] = nested.is_a?(Hash) ? symbolize_keys(nested) : nested
    end
  end
end

nil
