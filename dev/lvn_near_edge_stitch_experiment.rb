# frozen_string_literal: true

# Experimental, selection-based LVN near-edge stitch.
#
# This does NOT modify production LocalVertexNormalizer. It subclasses LVN and
# inserts a guarded stitch after the existing short-edge stage. Selected
# manifold solids are copied, made unique, and normalized only on the copies.
#
# SketchUp Ruby Console:
# load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_near_edge_stitch_experiment.rb'
# LvnNearEdgeStitchExperiment.run

root = File.expand_path('..', __dir__)
require File.join(root, 'indoor3d', 'application', 'local_vertex_normalizer') unless
  defined?(ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer)

Object.send(:remove_const, :LvnNearEdgeStitchExperiment) if
  defined?(LvnNearEdgeStitchExperiment)

module LvnNearEdgeStitchExperiment
  LVN = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer

  DICT = 'ULOL_LVN_NEAR_EDGE_STITCH_EXPERIMENT'
  COPY_OFFSET_MM = 3_000.0
  MAX_ACCEPTED_STITCHES = 30

  class StitchNormalizer < LVN
    attr_reader :near_edge_stitch_report

    private

    def collapse_short_edge_sliver_triangles(records, plan, baseline_inventory)
      collapsed, short_edge_report = super
      stitched, @near_edge_stitch_report =
        stitch_exact_intersection_near_edges(collapsed)
      [stitched, short_edge_report]
    end

    def stitch_exact_intersection_near_edges(records)
      working = records.dup
      initial_invalid = invalid_pair_signatures(working)
      initial_low = low_altitude_signatures(working)
      accepted = []
      attempts = []

      if initial_invalid.empty?
        return [
          working,
          stitch_report(
            working.length,
            initial_invalid,
            initial_invalid,
            initial_low,
            initial_low,
            accepted,
            attempts,
            :no_invalid_intersections
          )
        ]
      end

      MAX_ACCEPTED_STITCHES.times do
        current_invalid = invalid_pair_signatures(working)
        break if current_invalid.empty?

        candidates = stitch_host_edge_candidates(working)
        break if candidates.empty?

        best = nil

        candidates.each_value do |candidate|
          begin
            tentative, detail = stitch_one_host_edge(working, candidate)

            validate_normalized_triangle_shapes!(tentative)
            validate_normalized_triangle_topology!(tentative)

            tentative_invalid = invalid_pair_signatures(tentative)
            new_invalid = tentative_invalid - current_invalid
            removed_invalid = current_invalid - tentative_invalid

            unless new_invalid.empty?
              attempts << detail.merge(
                accepted: false,
                reason: :new_invalid_pairs,
                before_invalid_pair_count: current_invalid.length,
                after_invalid_pair_count: tentative_invalid.length,
                new_invalid_pair_count: new_invalid.length,
                removed_invalid_pair_count: removed_invalid.length
              )
              next
            end

            if removed_invalid.empty?
              attempts << detail.merge(
                accepted: false,
                reason: :intersection_not_improved,
                before_invalid_pair_count: current_invalid.length,
                after_invalid_pair_count: tentative_invalid.length
              )
              next
            end

            before_low = low_altitude_signatures(working)
            after_low = low_altitude_signatures(tentative)
            new_low = after_low - before_low

            unless new_low.empty?
              attempts << detail.merge(
                accepted: false,
                reason: :new_low_altitude_triangles,
                before_low_altitude_count: before_low.length,
                after_low_altitude_count: after_low.length,
                new_low_altitude_count: new_low.length
              )
              next
            end

            score = [
              removed_invalid.length,
              candidate[:points].length,
              before_low.length - after_low.length
            ]

            entry = {
              records: tentative,
              invalid: tentative_invalid,
              score: score,
              detail: detail.merge(
                accepted: true,
                before_invalid_pair_count: current_invalid.length,
                after_invalid_pair_count: tentative_invalid.length,
                removed_invalid_pair_count: removed_invalid.length,
                before_low_altitude_count: before_low.length,
                after_low_altitude_count: after_low.length
              )
            }

            best = entry if best.nil? || (score <=> best[:score]) == 1
          rescue Error, ArgumentError => error
            attempts << candidate_summary(candidate).merge(
              accepted: false,
              reason: :stitch_rejected,
              error: "#{error.class}: #{error.message}"
            )
          end
        end

        break unless best

        working = best[:records]
        accepted << best[:detail]
        attempts << best[:detail]
      end

      final_invalid = invalid_pair_signatures(working)
      final_low = low_altitude_signatures(working)
      reason = if accepted.empty?
                 :no_safe_improving_stitch
               elsif final_invalid.empty?
                 nil
               else
                 :remaining_invalid_intersections
               end

      [
        working,
        stitch_report(
          records.length,
          initial_invalid,
          final_invalid,
          initial_low,
          final_low,
          accepted,
          attempts,
          reason
        )
      ]
    end

    def stitch_host_edge_candidates(records)
      indexed = nondegenerate_indexed_triangles(records)
      valid_indices = indexed.map(&:first)
      triangles = indexed.map(&:last)
      failures = collect_triangle_intersection_failures(triangles)
      invalid_pairs = failures[:pairs].map do |first, second|
        [valid_indices[first], valid_indices[second]]
      end

      edge_owners = build_edge_owners(records)
      point_by_key = {}
      records.each do |record|
        record[:points].each do |point|
          point_by_key[grid_indices(point)] ||= point
        end
      end

      candidates = {}

      invalid_pairs.each do |first_index, second_index|
        [
          [first_index, second_index],
          [second_index, first_index]
        ].each do |vertex_index, host_index|
          vertex_record = records[vertex_index]
          host_record = records[host_index]
          host_triangle = host_record[:points].map { |point| grid_indices(point) }

          vertex_record[:points].each do |vertex_point|
            vertex_key = grid_indices(vertex_point)

            3.times do |edge_index|
              edge_a = host_triangle[edge_index]
              edge_b = host_triangle[(edge_index + 1) % 3]
              relation = near_edge_relation(vertex_key, edge_a, edge_b)
              next unless relation

              edge = canonical_edge_key(edge_a, edge_b)
              owners = edge_owners.fetch(edge, []).uniq.sort
              next unless owners.length == 2

              owner_records = owners.map { |index| records[index] }
              next unless owner_records.map { |record| record[:source_face_key] }.uniq.length == 1

              patch_keys = owner_records.map { |record| exact_coplanar_patch_key(record) }
              next unless patch_keys.uniq.length == 1

              plane_key = exact_integer_plane_key(
                owner_records.first[:points].map { |point| grid_indices(point) }
              )
              next unless exact_point_on_plane?(vertex_key, plane_key)

              entry = (candidates[edge] ||= {
                edge: edge,
                owners: owners,
                source_face_key: owner_records.first[:source_face_key],
                exact_patch_key: patch_keys.first,
                points: {}
              })

              existing = entry[:points][vertex_key]
              point_entry = {
                key: vertex_key,
                point: point_by_key.fetch(vertex_key),
                t: relation[:t],
                distance_mm: relation[:distance_mm],
                trigger_pairs: [[first_index, second_index]]
              }

              if existing
                existing[:distance_mm] = [existing[:distance_mm], relation[:distance_mm]].min
                existing[:trigger_pairs] |= point_entry[:trigger_pairs]
              else
                entry[:points][vertex_key] = point_entry
              end
            end
          end
        end
      end

      candidates.delete_if do |_edge, candidate|
        candidate[:points].empty?
      end

      candidates
    end

    def stitch_one_host_edge(records, candidate)
      edge = candidate[:edge]
      owner_indices = candidate[:owners]
      owner_records = owner_indices.map { |index| records[index] }

      current_owners = build_edge_owners(records).fetch(edge, []).uniq.sort
      unless current_owners == owner_indices
        raise TopologyChangedError,
              "Near-edge stitch host ownership changed: #{owner_indices.inspect}->#{current_owners.inspect}"
      end

      point_by_key = {}
      records.each do |record|
        record[:points].each do |point|
          point_by_key[grid_indices(point)] ||= point
        end
      end

      edge_a, edge_b = edge
      sorted_points = candidate[:points].values.sort_by { |entry| entry[:t] }
      chain_keys = [edge_a] + sorted_points.map { |entry| entry[:key] } + [edge_b]
      chain_keys = chain_keys.each_with_object([]) do |key, unique|
        unique << key unless unique.last == key
      end
      if chain_keys.length < 3
        raise ReconstructionError, 'Near-edge stitch has no interior chain vertex'
      end

      old_local_edge_owners = Hash.new { |hash, key| hash[key] = [] }
      owner_records.each_with_index do |record, local_index|
        exact_triangle_edge_keys(
          record[:points].map { |point| grid_indices(point) }
        ).each do |local_edge|
          old_local_edge_owners[local_edge] << local_index
        end
      end
      boundary_edges = old_local_edge_owners.filter_map do |local_edge, owners|
        local_edge if owners.length == 1
      end

      plane_key = exact_integer_plane_key(
        owner_records.first[:points].map { |point| grid_indices(point) }
      )
      drop_axis = plane_key.first(3).each_index.max_by do |axis|
        plane_key[axis].abs
      end
      expected_area2 = owner_records.sum do |record|
        integer_orientation_2d(
          *record[:points].map do |point|
            integer_project_2d(grid_indices(point), drop_axis)
          end
        ).abs
      end

      replacements = []
      owner_records.each do |owner|
        owner_keys = owner[:points].map { |point| grid_indices(point) }
        apex_key = owner_keys.find { |key| key != edge_a && key != edge_b }
        unless apex_key
          raise ReconstructionError,
                "Near-edge stitch could not find owner apex: edge=#{edge.inspect}"
        end
        apex = point_by_key.fetch(apex_key)

        chain_keys.each_cons(2) do |first_key, second_key|
          points = [
            apex,
            point_by_key.fetch(first_key),
            point_by_key.fetch(second_key)
          ]
          points = orient_patch_triangle(points, owner[:source_normal])
          replacements << owner.merge(points: points)
        end
      end

      validate_exact_patch_replacement!(
        replacements,
        boundary_edges,
        1,
        drop_axis,
        expected_area2
      )

      owner_lookup = owner_indices.to_h { |index| [index, true] }
      tentative = records.each_with_index.filter_map do |record, index|
        record unless owner_lookup[index]
      end
      tentative.concat(replacements)

      [
        tentative,
        candidate_summary(candidate).merge(
          owner_triangle_count: owner_records.length,
          replacement_triangle_count: replacements.length,
          boundary_edge_count: boundary_edges.length,
          expected_area2: expected_area2
        )
      ]
    end

    def near_edge_relation(point, edge_a, edge_b)
      direction = integer_subtract(edge_b, edge_a)
      offset = integer_subtract(point, edge_a)
      length_squared = integer_dot(direction, direction)
      return nil if length_squared.zero?

      numerator = integer_dot(offset, direction)
      return nil unless numerator.positive? && numerator < length_squared

      cross = integer_cross(offset, direction)
      cross_squared = integer_dot(cross, cross)
      return nil if cross_squared.zero?

      distance_grid = Math.sqrt(cross_squared.to_f / length_squared.to_f)
      distance_mm = distance_grid * @tolerance_mm
      return nil unless distance_mm < @tolerance_mm

      {
        t: Rational(numerator, length_squared),
        distance_mm: distance_mm
      }
    end

    def exact_point_on_plane?(point, plane_key)
      normal = plane_key.first(3)
      integer_dot(normal, point) == plane_key[3]
    end

    def build_edge_owners(records)
      owners = Hash.new { |hash, key| hash[key] = [] }
      records.each_with_index do |record, index|
        next if degenerate_triangle_record?(record)

        exact_triangle_edge_keys(
          record[:points].map { |point| grid_indices(point) }
        ).each do |edge|
          owners[edge] << index
        end
      end
      owners
    end

    def nondegenerate_indexed_triangles(records)
      records.each_index.filter_map do |index|
        record = records[index]
        next if degenerate_triangle_record?(record)

        [index, record[:points].map { |point| grid_indices(point) }]
      end
    end

    def invalid_pair_signatures(records)
      indexed = nondegenerate_indexed_triangles(records)
      triangles = indexed.map(&:last)
      failures = collect_triangle_intersection_failures(triangles)
      failures[:pairs].map do |first, second|
        first_key = canonical_triangle_key(triangles[first])
        second_key = canonical_triangle_key(triangles[second])
        [first_key, second_key].sort
      end.uniq.sort
    end

    def low_altitude_signatures(records)
      records.filter_map do |record|
        next if degenerate_triangle_record?(record)

        triangle = record[:points].map { |point| grid_indices(point) }
        next unless exact_triangle_minimum_altitude_mm(triangle) < @tolerance_mm

        canonical_triangle_key(triangle)
      end.uniq.sort
    end

    def candidate_summary(candidate)
      {
        host_edge: candidate[:edge],
        owner_triangles: candidate[:owners],
        source_face_key: candidate[:source_face_key],
        stitch_vertex_count: candidate[:points].length,
        stitch_vertices: candidate[:points].values.sort_by { |entry| entry[:t] }.map do |entry|
          {
            point: entry[:key],
            t: entry[:t].to_f,
            distance_mm: entry[:distance_mm],
            trigger_pairs: entry[:trigger_pairs]
          }
        end
      }
    end

    def stitch_report(
      input_triangle_count,
      initial_invalid,
      final_invalid,
      initial_low,
      final_low,
      accepted,
      attempts,
      skip_reason
    )
      {
        policy: :intersection_triggered_near_edge_conforming_stitch,
        threshold_mm: @tolerance_mm,
        input_triangle_count: input_triangle_count,
        output_triangle_count: input_triangle_count + accepted.sum do |entry|
          entry[:replacement_triangle_count].to_i - entry[:owner_triangle_count].to_i
        end,
        initial_invalid_pair_count: initial_invalid.length,
        final_invalid_pair_count: final_invalid.length,
        invalid_pair_reduction: initial_invalid.length - final_invalid.length,
        initial_low_altitude_count: initial_low.length,
        final_low_altitude_count: final_low.length,
        accepted_stitch_count: accepted.length,
        accepted_stitches: accepted.first(20),
        attempts: attempts.first(50),
        skipped: accepted.empty?,
        skip_reason: skip_reason
      }
    end
  end

  module_function

  def run(
    tolerance_mm: LVN::DEFAULT_TOLERANCE_MM,
    offset_mm: COPY_OFFSET_MM
  )
    model = Sketchup.active_model
    selected = model.selection.to_a
    solids = selected.select { |entity| manifold_solid?(entity) }

    if solids.empty?
      puts '[LVN NEAR EDGE STITCH] selected manifold solids=0'
      return nil
    end

    cleanup
    copies = create_copies(model, solids, offset_mm.to_f)
    results = []

    copies.each_with_index do |entry, index|
      copy = entry[:copy]
      source = entry[:source]
      normalizer = StitchNormalizer.new(tolerance_mm, model: model)
      error = nil

      begin
        normalizer.normalize(copy, manage_operation: true)
      rescue StandardError => caught
        error = caught
      end

      report = normalizer.near_edge_stitch_report || {}
      result = {
        source_pid: safe_pid(source),
        source_name: entity_name(source),
        copy_pid: safe_pid(copy),
        success: error.nil?,
        manifold_after: (copy.manifold? rescue nil),
        stitch_report: report,
        error_class: error&.class&.to_s,
        error_message: error&.message
      }
      results << result

      puts '-' * 100
      puts format(
        '[LVN NEAR EDGE STITCH] %d/%d %s %s',
        index + 1,
        copies.length,
        error ? 'FAIL' : 'OK  ',
        entity_name(source)
      )
      puts format(
        '  invalid: %s -> %s  reduction=%s',
        report[:initial_invalid_pair_count],
        report[:final_invalid_pair_count],
        report[:invalid_pair_reduction]
      )
      puts format(
        '  stitches=%s low_altitude=%s->%s manifold_after=%s',
        report[:accepted_stitch_count],
        report[:initial_low_altitude_count],
        report[:final_low_altitude_count],
        result[:manifold_after]
      )
      puts "  error=#{error.class}: #{error.message}" if error
    end

    $lvn_near_edge_stitch_experiment = results
    @copies = copies.map { |entry| entry[:copy] }

    puts '=' * 100
    puts "[LVN NEAR EDGE STITCH] copies=#{copies.length} success=#{results.count { |r| r[:success] }} failure=#{results.count { |r| !r[:success] }}"
    puts '=' * 100

    nil
  end

  def create_copies(model, solids, offset_mm)
    started = model.start_operation('Create LVN near-edge stitch copies', true)
    raise 'Could not start copy operation' unless started

    begin
      copies = solids.each_with_index.map do |source, index|
        copy = source.respond_to?(:copy) ? source.copy : nil
        raise "Could not copy #{entity_name(source)}" unless copy&.valid?

        copy.make_unique if copy.respond_to?(:make_unique)
        copy.name = "#{entity_name(source)} [NEAR EDGE STITCH TEST]"
        copy.set_attribute(DICT, 'generated', true)
        copy.set_attribute(DICT, 'source_pid', safe_pid(source))
        copy.transformation = Geom::Transformation.translation(
          [(index + 1) * offset_mm.mm, 0, 0]
        ) * copy.transformation

        { source: source, copy: copy }
      end

      model.commit_operation
      started = false
      copies
    rescue StandardError
      model.abort_operation if started
      raise
    end
  end

  def cleanup
    copies = Array(@copies).select { |entity| entity&.valid? }
    return nil if copies.empty?

    model = Sketchup.active_model
    started = model.start_operation('Remove LVN near-edge stitch copies', true)
    begin
      model.entities.erase_entities(copies)
      model.commit_operation
      started = false
    rescue StandardError
      model.abort_operation if started
      raise
    ensure
      @copies = []
    end

    nil
  end

  def manifold_solid?(entity)
    entity&.valid? &&
      entity.respond_to?(:definition) &&
      entity.respond_to?(:manifold?) &&
      entity.manifold? == true
  rescue StandardError
    false
  end

  def entity_name(entity)
    name = entity.respond_to?(:name) ? entity.name.to_s : ''
    return name unless name.empty?

    definition_name = entity.respond_to?(:definition) ? entity.definition.name.to_s : ''
    return definition_name unless definition_name.empty?

    entity.class.to_s
  rescue StandardError
    entity.class.to_s
  end

  def safe_pid(entity)
    entity.persistent_id
  rescue StandardError
    nil
  end
end

nil
