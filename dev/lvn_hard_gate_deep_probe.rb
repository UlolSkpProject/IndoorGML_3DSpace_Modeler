# frozen_string_literal: true

# SketchUp Ruby Console:
# load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_hard_gate_deep_probe.rb'

require 'json'
require 'tmpdir'
require 'time'

root = File.expand_path('..', __dir__)
require File.join(root, 'indoor3d', 'application', 'local_vertex_normalizer') unless
  defined?(ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer)

module LvnHardGateDeepProbe
  TARGETS = {
    2_239_676 => 'cerqe1nt',
    2_240_496 => 'op08xapo',
    2_262_671 => 'dud3wrh',
    2_245_192 => 'd6lrqmha'
  }.freeze
  MAX_OVERLAY_PAIRS_PER_ENTITY = 20
  OVERLAY_ID = 'ulol.lvn-hard-gate-deep-probe'
  OVERLAY_NAME = 'LVN Hard Gate Deep Probe'
  NORMALIZATION_MODES = [:normal, :axis_constraints_off].freeze

  LVN = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer

  class ProbeNormalizer < LVN
    attr_reader :probe

    def initialize(*args, normalization_mode: :normal, **kwargs)
      unless NORMALIZATION_MODES.include?(normalization_mode)
        raise ArgumentError,
              "Unknown normalization mode: #{normalization_mode.inspect}"
      end

      super(*args, **kwargs)
      @normalization_mode = normalization_mode
      @probe = {
        normalization_mode: @normalization_mode,
        trace: [],
        stages: [],
        axis_plan: nil,
        short_edge_plan: nil,
        hard_gate: nil,
        production_facts: {
          axis_constraint_order: self.class::AXIS_CONSTRAINT_PRIORITY,
          axis_constraint_semantics: 'independent coordinates; order is deterministic processing/report order',
          hard_gate_order: ['validate_normalized_triangle_topology!', 'validate_triangle_intersections!'],
          hard_gate_repairs_after_failure: false,
          grid_conforming_observed_predicate:
            'point_on_segment_parameter(..., GRID_EPSILON_MM); exact integer_point_between? is reported as a comparison'
        },
        constants: {
          tolerance_mm: instance_variable_get(:@tolerance_mm),
          default_tolerance_mm: self.class::DEFAULT_TOLERANCE_MM,
          grid_epsilon_mm: self.class::GRID_EPSILON_MM,
          short_edge_threshold_mm: self.class::SHORT_EDGE_SLIVER_THRESHOLD_MM,
          short_edge_min_aspect_ratio: self.class::SHORT_EDGE_SLIVER_MIN_ASPECT_RATIO,
          short_edge_min_patch_faces: self.class::SHORT_EDGE_SLIVER_MIN_PATCH_FACES
        }
      }
      @probe_sequence = 0
      @source_conforming_calls = 0
      @context = []
      @last_source_stage = nil
      @last_grid_stage = nil
    end

    def finish_probe
      analyze_stage_intersections!
      analyze_hard_gate!
      build_conclusions!
      @probe
    end

    private

    def axis_plane_normalization_plan(entities)
      plan = super
      @raw_axis_plan = plan
      @probe[:axis_plan] = json_safe(plan)
      trace(:axis_plane_normalization_plan, output: @probe[:axis_plan])
      plan
    end

    def short_edge_sliver_collapse_plan(entities, axis_plane_plan = nil)
      effective_axis_plan =
        @normalization_mode == :axis_constraints_off ? nil : axis_plane_plan
      plan = super(entities, effective_axis_plan)
      @probe[:short_edge_plan] = json_safe(plan)
      trace(
        :short_edge_sliver_collapse_plan,
        output: @probe[:short_edge_plan],
        normalization_mode: @normalization_mode,
        axis_constraints_applied: !effective_axis_plan.nil?
      )
      plan
    end

    def triangle_snapshot(entities)
      records = super
      snapshot = stage(:source_snapshot, records, :source)
      trace(
        :triangle_snapshot,
        input: { entities_class: entities.class.to_s },
        output: { stage_index: snapshot[:stage_index], triangle_count: records.length }
      )
      records
    end

    def conforming_triangle_snapshot(
      source_triangles,
      coordinate_space: :grid,
      duplicate_diagnostics: nil
    )
      @source_conforming_calls += 1 if coordinate_space == :source
      logical = if coordinate_space == :source
                  case @last_source_stage
                  when :source_snapshot then :source_conforming_1
                  when :post_source_natural_collapse then :source_conforming_2
                  else
                    "source_conforming_after_#{@last_source_stage || 'unknown'}".to_sym
                  end
                else
                  :grid_conforming
                end
      previous_stage =
        coordinate_space == :source ? @last_source_stage : @last_grid_stage
      input = serialize_records(source_triangles, coordinate_space)
      duplicates_before = duplicate_diagnostics &&
        duplicate_diagnostics[:duplicate_count].to_i
      records = super
      output = stage(logical, records, coordinate_space)
      details = conforming_details(
        input,
        output[:triangles],
        coordinate_space
      )
      details[:duplicate_diagnostics] = json_safe(duplicate_diagnostics)
      details[:exact_duplicate_discarded_count] =
        duplicate_diagnostics ?
          duplicate_diagnostics[:duplicate_count].to_i - duplicates_before.to_i :
          0
      details[:parent_children] =
        conforming_parent_children(input, output[:triangles], coordinate_space)
      trace(
        :conforming_triangle_snapshot,
        logical_stage: logical,
        coordinate_space: coordinate_space,
        input: { triangle_count: source_triangles.length, triangles: input },
        output: {
          stage_index: output[:stage_index],
          triangle_count: records.length,
          triangles: output[:triangles]
        },
        details: details
      )
      trace(
        :logical_stage_evidence,
        logical_stage: logical,
        previous_stage: previous_stage
      )
      @last_grid_stage = logical if coordinate_space == :grid
      records
    end

    def collapse_source_altitude_sliver_triangles(records)
      with_context(:collapse_source_altitude_sliver_triangles) do
        output, report = super
        stage(:post_source_natural_collapse, output, :source)
        trace(
          :collapse_source_altitude_sliver_triangles,
          input: {
            triangle_count: records.length,
            triangles: serialize_records(records, :source)
          },
          output: {
            triangle_count: output.length,
            triangles: serialize_records(output, :source)
          },
          report: json_safe(report)
        )
        [output, report]
      end
    end

    def normalize_triangle_records_allowing_collisions(
      records,
      axis_plane_plan = nil,
      duplicate_diagnostics: nil
    )
      effective_axis_plan =
        @normalization_mode == :axis_constraints_off ? nil : axis_plane_plan
      output, report = super(
        records,
        effective_axis_plan,
        duplicate_diagnostics: duplicate_diagnostics
      )
      stage(:grid_normalized, output, :grid)
      @last_grid_stage = :grid_normalized
      trace(
        :normalize_triangle_records_allowing_collisions,
        input: {
          triangle_count: records.length,
          triangles: serialize_records(records, :source)
        },
        output: {
          triangle_count: output.length,
          triangles: serialize_records(output, :grid)
        },
        report: json_safe(report),
        duplicate_diagnostics: json_safe(duplicate_diagnostics),
        normalization_mode: @normalization_mode,
        axis_constraints_applied: !effective_axis_plan.nil?
      )
      [output, report]
    end

    def discard_collapsed_triangle_records(
      records,
      coordinate_space: :grid,
      duplicate_diagnostics: nil
    )
      output, report = super
      logical = cleanup_stage_name(coordinate_space)
      stage(logical, output, coordinate_space) if logical
      @last_grid_stage = logical if coordinate_space == :grid && logical
      trace(
        :discard_collapsed_triangle_records,
        logical_stage: logical,
        coordinate_space: coordinate_space,
        input: {
          triangle_count: records.length,
          triangles: serialize_records(records, coordinate_space)
        },
        output: {
          triangle_count: output.length,
          triangles: serialize_records(output, coordinate_space)
        },
        report: json_safe(report)
      )
      [output, report]
    end

    def collapse_short_edge_sliver_triangles(records, plan, baseline_validation)
      with_context(:collapse_short_edge_sliver_triangles) do
        output, report = super
        stage(:post_short_edge, output, :grid)
        @last_grid_stage = :post_short_edge
        @probe[:short_edge_collapse_report] = json_safe(report)
        trace(
          :collapse_short_edge_sliver_triangles,
          input: {
            triangle_count: records.length,
            triangles: serialize_records(records, :grid)
          },
          output: {
            triangle_count: output.length,
            triangles: serialize_records(output, :grid)
          },
          report: @probe[:short_edge_collapse_report]
        )
        [output, report]
      end
    end

    def validate_normalized_triangle_mesh!(records)
      hard_stage = stage(:hard_gate, records, :grid)
      triangles = records.map { |record| record[:points].map { |point| grid_indices(point) } }
      topology = topology_summary(triangles)
      failures = collect_triangle_intersection_failures(triangles)
      @probe[:hard_gate] = {
        stage_index: hard_stage[:stage_index],
        topology: topology,
        geometry: {
          status: failures[:pairs].empty? ? 'PASS' : 'FAIL',
          tested_pairs: failures[:tested_pairs],
          invalid_pair_count: failures[:pairs].length,
          invalid_pairs: failures[:pairs]
        }
      }
      trace(
        :validate_normalized_triangle_mesh!,
        logical_stage: :hard_gate,
        input: {
          triangle_count: records.length,
          triangles: serialize_records(records, :grid)
        },
        output: { raised_if_invalid: true },
        hard_gate: @probe[:hard_gate]
      )
      super
    end

    def cleanup_stage_name(space)
      return :source_natural_collapse_cleanup if
        @context.include?(:collapse_source_altitude_sliver_triangles)
      return :source_cleanup if space == :source
      return nil if @context.include?(:collapse_short_edge_sliver_triangles)

      case @last_grid_stage
      when :grid_normalized then :grid_normalized_cleanup
      when :grid_conforming then :grid_conforming_cleanup
      when :post_short_edge then :post_sliver_cleanup
      else :"grid_cleanup_after_#{@last_grid_stage || 'unknown'}"
      end
    end

    def stage(name, records, space)
      data = {
        stage_index: @probe[:stages].length,
        name: name,
        coordinate_space: space,
        triangle_count: records.length,
        triangles: serialize_records(records, space)
      }
      @probe[:stages] << data
      @last_source_stage = name if space == :source
      data
    end

    def trace(method, data = {})
      @probe_sequence += 1
      @probe[:trace] << {
        sequence: @probe_sequence,
        method: method,
        context: @context.dup
      }.merge(data)
    end

    def with_context(name)
      @context << name
      yield
    ensure
      @context.pop
    end

    def serialize_records(records, space)
      records.each_with_index.map do |record, index|
        points = record[:points]
        keys = points.map { |point| triangle_point_key(point, space) }
        {
          triangle_index: index,
          record_object_id: record.object_id,
          points_source_or_grid: keys,
          points_mm: points.map { |point| point_components_mm(point) },
          source_precision_indices:
            (points.map { |point| source_precision_indices(point) } if space == :source),
          signature: triangle_signature_for_space(points, space),
          source_face_key: record[:source_face_key],
          source_polygon_index: record[:source_polygon_index],
          source_normal: json_safe(record[:source_normal]),
          material: metadata_label(record[:material]),
          back_material: metadata_label(record[:back_material]),
          layer: metadata_label(record[:layer])
        }
      end
    end

    def metadata_label(value)
      return nil if value.nil?

      {
        name: (value.name.to_s if value.respond_to?(:name)),
        persistent_id: (value.persistent_id if value.respond_to?(:persistent_id)),
        object_id: value.object_id
      }
    rescue StandardError => error
      { error: "#{error.class}: #{error.message}" }
    end

    def conforming_details(input, output, space)
      candidates = input.flat_map { |record| record[:points_source_or_grid] }.uniq
      input_edges = edge_inventory(input)
      output_edges = edge_inventory(output)
      split_edges = input_edges.keys.count { |edge| !output_edges.key?(edge) }
      {
        vertex_candidate_count: candidates.length,
        split_edge_count: split_edges,
        input_edge_count: input_edges.length,
        output_edge_count: output_edges.length
      }
    end

    def conforming_parent_children(input, output, space)
      input.filter_map do |parent|
        children = output.select do |child|
          same_face = parent[:source_face_key] == child[:source_face_key]
          same_polygon =
            parent[:source_polygon_index] == child[:source_polygon_index]
          (same_face || same_polygon) &&
            triangle_contains_record?(parent, child, space)
        end
        next if children.empty?
        next if children.length == 1 && children[0][:signature] == parent[:signature]

        {
          parent_triangle_index: parent[:triangle_index],
          parent_boundary: parent[:points_source_or_grid],
          source_face_key: parent[:source_face_key],
          source_polygon_index: parent[:source_polygon_index],
          child_triangle_indices: children.map { |child| child[:triangle_index] },
          child_triangles:
            children.map { |child| child[:points_source_or_grid] }
        }
      end
    end

    def analyze_stage_intersections!
      first = nil
      @probe[:stage_intersections] = @probe[:stages].map do |snapshot|
        if snapshot[:coordinate_space] != :grid
          next {
            stage: snapshot[:name],
            coordinate_space: snapshot[:coordinate_space],
            production_equivalent: false,
            reason: 'source coordinates are not forced through the grid hard-gate predicate'
          }
        end

        triangles = snapshot[:triangles].map { |record| record[:points_source_or_grid] }
        degenerate_indices = triangles.each_index.select do |index|
          triangle = triangles[index]
          triangle.uniq.length != 3 ||
            integer_zero_vector?(integer_triangle_normal(triangle))
        end
        valid_indices = triangles.each_index.reject do |index|
          degenerate_indices.include?(index)
        end
        valid_triangles = valid_indices.map { |index| triangles[index] }
        failures = collect_triangle_intersection_failures(valid_triangles)
        remapped_pairs = failures[:pairs].map do |first, second|
          [valid_indices[first], valid_indices[second]]
        end
        first ||= snapshot[:name] unless failures[:pairs].empty?
        {
          stage: snapshot[:name],
          coordinate_space: :grid,
          production_equivalent: true,
          invalid_pair_count: remapped_pairs.length,
          invalid_pairs: remapped_pairs,
          tested_pairs: failures[:tested_pairs],
          skipped_degenerate_triangle_count: degenerate_indices.length,
          skipped_degenerate_triangle_indices: degenerate_indices
        }
      rescue StandardError => error
        {
          stage: snapshot[:name],
          coordinate_space: snapshot[:coordinate_space],
          production_equivalent: false,
          analysis_error: "#{error.class}: #{error.message}"
        }
      end
      @probe[:first_invalid_intersection_stage] = first
    end

    def analyze_hard_gate!
      return unless @probe[:hard_gate]

      hard = @probe[:stages].find { |snapshot| snapshot[:name] == :hard_gate }
      pairs = @probe.dig(:hard_gate, :geometry, :invalid_pairs) || []
      @probe[:pair_analyses] = pairs.map do |index_a, index_b|
        record_a = hard[:triangles].fetch(index_a)
        record_b = hard[:triangles].fetch(index_b)
        {
          indices: [index_a, index_b],
          triangle_a: record_a,
          triangle_b: record_b,
          exact_intersection: exact_intersection_analysis(
            record_a[:points_source_or_grid],
            record_b[:points_source_or_grid]
          ),
          edge_split_analysis: edge_split_analysis(hard, index_a, index_b),
          lineage_a: lineage_for(record_a, hard[:stage_index]),
          lineage_b: lineage_for(record_b, hard[:stage_index]),
          axis_constraints_a: axis_constraints_for(record_a),
          axis_constraints_b: axis_constraints_for(record_b),
          sliver_lineage_a: sliver_lineage_for(record_a, hard[:stage_index]),
          sliver_lineage_b: sliver_lineage_for(record_b, hard[:stage_index])
        }
      end
    end

    def build_conclusions!
      pairs = Array(@probe[:pair_analyses])
      @probe[:conclusions] = {
        detected_pairs: pairs.map { |pair| pair[:indices] },
        first_invalid_intersection_stage: @probe[:first_invalid_intersection_stage],
        pair_findings: pairs.map do |pair|
          split_candidates = pair[:edge_split_analysis]
          exact_t_junctions = split_candidates.select { |entry| entry[:exact_between] }
          nearest = split_candidates.min_by { |entry| entry[:distance_to_segment_mm] }
          slivers = [
            [:a, pair[:sliver_lineage_a]],
            [:b, pair[:sliver_lineage_b]]
          ].filter_map do |side, lineage|
            hard = Array(lineage[:stages]).find { |row| row[:stage] == :hard_gate }
            next unless hard && hard[:sliver]

            {
              side: side,
              first_appeared_at: lineage[:first_appeared_at],
              short_edge_detector: lineage[:short_edge_detector]
            }
          end
          {
            indices: pair[:indices],
            source_provenance: {
              a: {
                source_face_key: pair.dig(:triangle_a, :source_face_key),
                source_polygon_index: pair.dig(:triangle_a, :source_polygon_index)
              },
              b: {
                source_face_key: pair.dig(:triangle_b, :source_face_key),
                source_polygon_index: pair.dig(:triangle_b, :source_polygon_index)
              }
            },
            plane_relation: pair.dig(:exact_intersection, :plane_relation),
            exact_intersection_conclusion:
              pair.dig(:exact_intersection, :conclusion),
            axis_constraint_mapping_counts: {
              a: pair[:axis_constraints_a].length,
              b: pair[:axis_constraints_b].length
            },
            exact_t_junction_count: exact_t_junctions.length,
            edge_split_classifications:
              (exact_t_junctions.empty? ? [nearest] : exact_t_junctions)
                .compact.map { |entry| entry[:classification] }.uniq,
            nearest_cross_triangle_vertex_to_edge: nearest,
            slivers: slivers
          }
        end
      }
    end

    def exact_intersection_analysis(a, b)
      shared = a & b
      normal_a = integer_triangle_normal(a)
      normal_b = integer_triangle_normal(b)
      direction = integer_cross(normal_a, normal_b)
      base = {
        shared_vertex_count: shared.length,
        shared_vertices: shared,
        normal_a: normal_a,
        normal_b: normal_b,
        aabb_a: integer_triangle_aabb(a),
        aabb_b: integer_triangle_aabb(b),
        production_allowed: exact_triangle_intersection_allowed?(a, b)
      }

      if integer_zero_vector?(direction)
        coplanar = integer_dot(normal_a, integer_subtract(b[0], a[0])).zero?
        return base.merge(plane_relation: 'PARALLEL_NON_COPLANAR') unless coplanar

        drop_axis = normal_a.each_index.max_by { |axis| normal_a[axis].abs }
        projected_a = a.map { |point| project_integer_point(point, drop_axis) }
        projected_b = b.map { |point| project_integer_point(point, drop_axis) }
        intersection = unique_rational_points(
          convex_polygon_intersection(projected_a, projected_b)
        )
        area2 = intersection.length >= 3 ? rational_polygon_area_twice(intersection).abs : 0
        type = if intersection.empty?
                 'none'
               elsif intersection.length == 1
                 'point'
               elsif area2.zero?
                 'segment'
               else
                 'area'
               end
        base.merge(
          plane_relation: 'COPLANAR',
          drop_axis: drop_axis,
          projected_a: projected_a,
          projected_b: projected_b,
          intersection_points: json_safe(intersection),
          intersection_area2: json_safe(area2),
          intersection_type: type,
          expected_shared_simplex: shared_simplex_name(shared.length),
          conclusion:
            "actual=#{type}, expected=#{shared_simplex_name(shared.length)}; overlap extends beyond shared simplex"
        )
      else
        interval_a = triangle_plane_parameter_interval(a, b[0], normal_b, direction)
        interval_b = triangle_plane_parameter_interval(b, a[0], normal_a, direction)
        overlap = if interval_a && interval_b
                    [[interval_a[0], interval_b[0]].max,
                     [interval_a[1], interval_b[1]].min]
                  end
        expected = shared.map { |point| integer_dot(direction, point) }.minmax
        base.merge(
          plane_relation: 'NON_COPLANAR',
          line_direction: direction,
          interval_a: json_safe(interval_a),
          interval_b: json_safe(interval_b),
          actual_overlap_interval: json_safe(overlap),
          shared_simplex_interval: json_safe(expected),
          expected_shared_simplex: shared_simplex_name(shared.length),
          conclusion:
            "actual interval #{format_exact(overlap)} exceeds expected #{format_exact(expected)}"
        )
      end
    end

    def edge_split_analysis(hard, index_a, index_b)
      records = hard[:triangles]
      inventory = edge_inventory(records)
      directions = [[index_a, index_b], [index_b, index_a]]
      directions.flat_map do |owner_index, candidate_index|
        owner = records.fetch(owner_index)
        candidate = records.fetch(candidate_index)
        owner[:points_source_or_grid].each_index.flat_map do |edge_index|
          edge = canonical_edge_key(
            owner[:points_source_or_grid][edge_index],
            owner[:points_source_or_grid][(edge_index + 1) % 3]
          )
          candidate[:points_source_or_grid].each_with_index.map do |point, vertex_index|
            exact_collinear = integer_zero_vector?(
              integer_cross(
                integer_subtract(edge[1], edge[0]),
                integer_subtract(point, edge[0])
              )
            )
            exact_between = integer_point_between?(point, edge[0], edge[1])
            split_a = canonical_edge_key(edge[0], point)
            split_b = canonical_edge_key(point, edge[1])
            timeline = split_timeline(edge, point)
            {
              owner_triangle: owner_index,
              edge_index: edge_index,
              edge: edge,
              candidate_triangle: candidate_index,
              candidate_vertex_index: vertex_index,
              candidate_vertex: point,
              exact_collinear: exact_collinear,
              exact_between: exact_between,
              distance_to_infinite_line_mm: point_line_distance_mm(point, edge),
              distance_to_segment_mm: point_segment_distance_mm(point, edge),
              edge_present: inventory.key?(edge),
              split_edges_present:
                [inventory.key?(split_a), inventory.key?(split_b)],
              stage_timeline: timeline,
              classification: split_classification(exact_collinear, exact_between, timeline)
            }
          end
        end
      end
    end

    def split_timeline(edge, point)
      @probe[:stages].filter_map do |snapshot|
        next unless snapshot[:coordinate_space] == :grid

        inventory = edge_inventory(snapshot[:triangles])
        vertices = snapshot[:triangles].flat_map do |record|
          record[:points_source_or_grid]
        end.uniq
        {
          stage: snapshot[:name],
          long_edge_present: inventory.key?(edge),
          candidate_present: vertices.include?(point),
          split_edges_present: [
            inventory.key?(canonical_edge_key(edge[0], point)),
            inventory.key?(canonical_edge_key(point, edge[1]))
          ]
        }
      end
    end

    def split_classification(collinear, between, timeline)
      conforming = timeline.find { |entry| entry[:stage] == :grid_conforming }
      hard = timeline.find { |entry| entry[:stage] == :hard_gate }
      return 'C: candidate exists but is not exact-collinear/between' unless collinear && between
      if conforming && conforming[:long_edge_present] && conforming[:candidate_present]
        return 'A: candidate and long edge coexist after grid conforming; conforming bug possible'
      end
      if conforming && !conforming[:candidate_present] && hard&.dig(:candidate_present)
        return 'B: candidate appeared after grid conforming; post-conforming T-junction'
      end
      if hard && !hard[:long_edge_present] && hard[:split_edges_present].all?
        return 'D: edge is already split; visualization/index impression'
      end

      'E: exact T-junction; inspect stage timeline'
    end

    def lineage_for(child, child_stage_index)
      current = child
      (child_stage_index - 1).downto(0).filter_map do |stage_index|
        snapshot = @probe[:stages][stage_index]
        candidates = snapshot[:triangles].map do |parent|
          confidence, reason = lineage_match(parent, current, snapshot[:coordinate_space])
          [parent, confidence, reason] if confidence
        end.compact
        next if candidates.empty?

        selected = candidates.max_by { |_record, confidence, _reason| confidence }
        current = selected[0]
        {
          stage: snapshot[:name],
          triangle_index: current[:triangle_index],
          source_face_key: current[:source_face_key],
          source_polygon_index: current[:source_polygon_index],
          confidence: selected[1] >= 90 ? 'confirmed' : 'estimated',
          reason: selected[2]
        }
      end
    end

    def lineage_match(parent, child, space)
      return [100, 'same record object'] if parent[:record_object_id] == child[:record_object_id]
      return [95, 'exact canonical signature'] if parent[:signature] == child[:signature]
      provenance = parent[:source_face_key] == child[:source_face_key]
      polygon = parent[:source_polygon_index] == child[:source_polygon_index]
      return [85, 'same source face/polygon'] if provenance && polygon
      return [70, 'same source face and child contained in parent'] if
        provenance && triangle_contains_record?(parent, child, space)
      return [55, 'same source face'] if provenance
      return [45, 'same source polygon index'] if polygon

      nil
    end

    def triangle_contains_record?(parent, child, space)
      parent_points = lineage_integer_points(parent, space)
      child_points = lineage_integer_points(child, space)
      normal = integer_triangle_normal(parent_points)
      return false if integer_zero_vector?(normal)
      return false unless child_points.all? do |point|
        integer_dot(normal, integer_subtract(point, parent_points[0])).zero?
      end

      drop_axis = normal.each_index.max_by { |axis| normal[axis].abs }
      projected_parent = parent_points.map { |point| project_integer_point(point, drop_axis) }
      child_points.all? do |point|
        projected = project_integer_point(point, drop_axis)
        integer_point_in_triangle_2d?(projected, *projected_parent)
      end
    rescue StandardError
      false
    end

    def lineage_integer_points(record, space)
      if space == :source
        record[:source_precision_indices] || record[:points_source_or_grid]
      else
        record[:points_source_or_grid]
      end
    end

    def axis_constraints_for(record)
      plan = @probe[:axis_plan]
      source = @probe[:stages].find { |snapshot| snapshot[:name] == :source_snapshot }
      return [] unless plan && source

      target = record[:points_source_or_grid]
      source[:triangles].flat_map do |candidate|
        candidate[:points_mm].each_with_index.filter_map do |point_mm, point_index|
          source_key = candidate[:points_source_or_grid][point_index]
          point = @point_factory.call(*source_key)
          normalized = normalized_target(point, @raw_axis_plan || rebuild_axis_plan(plan))
          grid = grid_indices(normalized)
          next unless target.include?(grid)

          constraints = axis_constraints_lookup(plan, source_key)
          {
            final_vertex: grid,
            source_point_mm: point_mm,
            source_point_key: source_key,
            constraints: constraints,
            processing_order: self.class::AXIS_CONSTRAINT_PRIORITY,
            displacement_mm: 3.times.map { |axis| (grid[axis] * @tolerance_mm) - point_mm[axis] },
            unconstrained_axes: [0, 1, 2] - constraints.keys.map(&:to_i),
            source_face_key: candidate[:source_face_key],
            source_polygon_index: candidate[:source_polygon_index],
            source_normal: candidate[:source_normal],
            resolved_conflicts: conflicts_for(plan, source_key),
            topology_repairs:
              repairs_for(plan, source_key, source_precision_indices(point))
          }
        end
      end
    rescue StandardError => error
      [{ error: "#{error.class}: #{error.message}" }]
    end

    def rebuild_axis_plan(_safe_plan)
      @raw_axis_plan || {}
    end

    def axis_constraints_lookup(plan, source_key)
      constraints = plan['constraints'] || plan[:constraints] || {}
      constraints[source_key.to_s] || constraints[source_key] || {}
    end

    def conflicts_for(plan, source_key)
      Array(plan['resolved_constraint_conflicts'] || plan[:resolved_constraint_conflicts])
        .select { |entry| (entry['point'] || entry[:point]) == source_key }
        .map do |entry|
          entry.merge('selection_reason' => conflict_selection_reason(entry))
        end
    end

    def conflict_selection_reason(entry)
      selected_displacement =
        entry['selected_displacement_mm'] || entry[:selected_displacement_mm]
      selected_spread =
        entry['selected_source_spread_mm'] || entry[:selected_source_spread_mm]
      discarded = Array(entry['discarded'] || entry[:discarded])
      return 'minimum displacement_mm' if discarded.any? do |candidate|
        (candidate['displacement_mm'] || candidate[:displacement_mm]).to_f >
          selected_displacement.to_f
      end
      return 'equal displacement; minimum source_spread_mm' if discarded.any? do |candidate|
        (candidate['source_spread_mm'] || candidate[:source_spread_mm]).to_f >
          selected_spread.to_f
      end

      'equal displacement/spread; deterministic target_index order'
    end

    def repairs_for(plan, source_key, precision_key)
      Array(plan['topology_preserving_target_repairs'] || plan[:topology_preserving_target_repairs])
        .select do |entry|
          changed = Array(entry['changed_source_points'] || entry[:changed_source_points])
          changed.include?(source_key) || changed.include?(precision_key)
        end
    end

    def sliver_lineage_for(record, child_stage_index)
      lineage = lineage_for(record, child_stage_index)
      rows = lineage.filter_map do |entry|
        snapshot = @probe[:stages].find { |stage| stage[:name] == entry[:stage] }
        next unless snapshot

        parent = snapshot[:triangles].find do |triangle|
          triangle[:triangle_index] == entry[:triangle_index]
        end
        if snapshot[:coordinate_space] == :grid
          sliver_metrics(parent).merge(stage: snapshot[:name])
        else
          source_sliver_metrics(parent).merge(stage: snapshot[:name])
        end
      end
      hard_metrics = sliver_metrics(record)
      rows << hard_metrics.merge(stage: :hard_gate)
      stage_order = @probe[:stages].each_with_object({}) do |snapshot, order|
        order[snapshot[:name]] ||= snapshot[:stage_index]
      end
      rows.sort_by! { |row| stage_order.fetch(row[:stage], Float::INFINITY) }
      first = rows.find { |row| row[:sliver] }
      {
        stages: rows,
        first_appeared_at: first && first[:stage],
        short_edge_detector: short_edge_reason(record)
      }
    end

    def sliver_metrics(record)
      triangle = record[:points_source_or_grid]
      edges = 3.times.map do |index|
        vector = integer_subtract(triangle[index], triangle[(index + 1) % 3])
        Math.sqrt(integer_dot(vector, vector).to_f) * @tolerance_mm
      end
      altitude = exact_triangle_minimum_altitude_mm(triangle)
      longest = edges.max || 0.0
      {
        triangle_index: record[:triangle_index],
        edge_lengths_mm: edges,
        shortest_edge_mm: edges.min,
        longest_edge_mm: longest,
        minimum_altitude_mm: altitude,
        aspect_ratio: altitude.positive? ? longest / altitude : 'Infinity',
        zero_area: integer_zero_vector?(integer_triangle_normal(triangle)),
        sliver: grid_triangle_sliver?(points_from_grid(triangle)),
        source_face_key: record[:source_face_key],
        source_polygon_index: record[:source_polygon_index]
      }
    end

    def source_sliver_metrics(record)
      points = record[:points_mm]
      edges = 3.times.map do |index|
        Math.sqrt(3.times.sum do |axis|
          (points[index][axis] - points[(index + 1) % 3][axis])**2
        end)
      end
      ab = 3.times.map { |axis| points[1][axis] - points[0][axis] }
      ac = 3.times.map { |axis| points[2][axis] - points[0][axis] }
      cross = [
        (ab[1] * ac[2]) - (ab[2] * ac[1]),
        (ab[2] * ac[0]) - (ab[0] * ac[2]),
        (ab[0] * ac[1]) - (ab[1] * ac[0])
      ]
      cross_length = Math.sqrt(cross.sum { |value| value * value })
      longest = edges.max || 0.0
      altitude = longest.positive? ? cross_length / longest : 0.0
      threshold = if self.class.const_defined?(:SOURCE_ALTITUDE_SLIVER_THRESHOLD_MM)
                    self.class::SOURCE_ALTITUDE_SLIVER_THRESHOLD_MM
                  else
                    0.5
                  end
      {
        triangle_index: record[:triangle_index],
        edge_lengths_mm: edges,
        shortest_edge_mm: edges.min,
        longest_edge_mm: longest,
        minimum_altitude_mm: altitude,
        aspect_ratio: altitude.positive? ? longest / altitude : 'Infinity',
        zero_area: cross_length.zero?,
        sliver: altitude <= threshold,
        sliver_policy: 'source altitude diagnostic',
        source_face_key: record[:source_face_key],
        source_polygon_index: record[:source_polygon_index]
      }
    end

    def short_edge_reason(record)
      plan = @probe[:short_edge_plan] || {}
      report = @probe[:short_edge_collapse_report] || {}
      candidates = Array(plan['candidates'] || plan[:candidates])
      face_key = record[:source_face_key]
      matching = candidates.select { |entry| (entry['face_key'] || entry[:face_key]) == face_key }
      skipped = Array(report['skipped_patches'] || report[:skipped_patches]).select do |entry|
        Array(entry['face_keys'] || entry[:face_keys]).include?(face_key)
      end
      reason = if matching.empty?
                 'not detected by strict original-quad short-edge detector'
               elsif !skipped.empty?
                 "detected but skipped: #{skipped.map { |entry| entry['reason'] || entry[:reason] }.inspect}"
               elsif !(report['repairable'] || report[:repairable])
                 'detected, but no repairable patch/target was formed'
               else
                 'detected in a repairable plan; inspect collapse displacement and lineage'
               end
      {
        detected: !matching.empty?,
        matching_candidates: matching,
        skipped_patches: skipped,
        repairable: report['repairable'] || report[:repairable],
        reason: reason
      }
    end

    def topology_summary(triangles)
      edges = Hash.new { |hash, key| hash[key] = [] }
      vertices = {}
      signatures = Hash.new { |hash, key| hash[key] = [] }
      triangles.each_with_index do |triangle, index|
        signatures[canonical_triangle_key(triangle)] << index
        triangle.each { |point| vertices[point] = true }
        3.times do |edge_index|
          edges[canonical_edge_key(
            triangle[edge_index],
            triangle[(edge_index + 1) % 3]
          )] << index
        end
      end
      bad = edges.select { |_edge, owners| owners.length != 2 }
      adjacency = Array.new(triangles.length) { [] }
      edges.each_value do |owners|
        next unless owners.length == 2

        adjacency[owners[0]] << owners[1]
        adjacency[owners[1]] << owners[0]
      end
      {
        status: bad.empty? && graph_component_count(adjacency) == 1 ? 'PASS' : 'FAIL',
        triangle_count: triangles.length,
        vertex_count: vertices.length,
        edge_count: edges.length,
        duplicate_count: signatures.values.count { |owners| owners.length > 1 },
        bad_edge_count: bad.length,
        boundary_edge_count: bad.count { |_edge, owners| owners.length == 1 },
        overused_edge_count: bad.count { |_edge, owners| owners.length > 2 },
        component_count: graph_component_count(adjacency),
        closed_2_manifold: bad.empty? && graph_component_count(adjacency) == 1,
        bad_edge_samples: json_safe(bad.first(10).to_h)
      }
    end

    def edge_inventory(records)
      records.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |record, edges|
        points = record[:points_source_or_grid]
        3.times do |index|
          edges[canonical_edge_key(points[index], points[(index + 1) % 3])] <<
            record[:triangle_index]
        end
      end
    end

    def point_line_distance_mm(point, edge)
      ab = integer_subtract(edge[1], edge[0])
      ap = integer_subtract(point, edge[0])
      length = Math.sqrt(integer_dot(ab, ab).to_f)
      return 0.0 if length.zero?

      Math.sqrt(integer_dot(integer_cross(ab, ap), integer_cross(ab, ap)).to_f) /
        length * @tolerance_mm
    end

    def point_segment_distance_mm(point, edge)
      ab = integer_subtract(edge[1], edge[0])
      ap = integer_subtract(point, edge[0])
      length_squared = integer_dot(ab, ab)
      return Math.sqrt(integer_dot(ap, ap).to_f) * @tolerance_mm if length_squared.zero?

      parameter = integer_dot(ap, ab).to_f / length_squared
      parameter = [[parameter, 0.0].max, 1.0].min
      projected = 3.times.map { |axis| edge[0][axis] + (ab[axis] * parameter) }
      Math.sqrt(3.times.sum { |axis| (point[axis] - projected[axis])**2 }) * @tolerance_mm
    end

    def points_from_grid(triangle)
      triangle.map { |indices| point_from_grid_indices(indices) }
    end

    def shared_simplex_name(count)
      { 0 => 'none', 1 => 'vertex', 2 => 'edge', 3 => 'triangle' }[count] || 'unknown'
    end

    def format_exact(value)
      json_safe(value).inspect
    end

    def json_safe(value)
      case value
      when Rational
        { numerator: value.numerator, denominator: value.denominator }
      when Float
        value.finite? ? value : value.to_s
      when Symbol
        value.to_s
      when Array
        value.map { |entry| json_safe(entry) }
      when Hash
        value.each_with_object({}) do |(key, entry), result|
          result[key.to_s] = json_safe(entry)
        end
      when NilClass, TrueClass, FalseClass, Integer, String
        value
      else
        if value.respond_to?(:x) && value.respond_to?(:y) && value.respond_to?(:z)
          [value.x.to_f, value.y.to_f, value.z.to_f]
        else
          metadata_label(value)
        end
      end
    end
  end

  class Overlay < Sketchup::Overlay
    def initialize(items)
      super(OVERLAY_ID, OVERLAY_NAME)
      @items = items
    end

    def draw(view)
      @items.each do |item|
        draw_triangle(view, item[:triangle_a], Sketchup::Color.new(255, 32, 32, 110))
        draw_triangle(view, item[:triangle_b], Sketchup::Color.new(32, 96, 255, 110))
        draw_screen_label(
          view,
          item[:label_point_a],
          item[:label_a],
          Sketchup::Color.new(255, 64, 64, 255),
          -18
        )
        draw_screen_label(
          view,
          item[:label_point_b],
          item[:label_b],
          Sketchup::Color.new(80, 144, 255, 255),
          8
        )
      end
    rescue StandardError => error
      warn "[LVN PROBE] overlay draw failed: #{error.class}: #{error.message}"
    end

    def getExtents
      bounds = Geom::BoundingBox.new
      @items.each do |item|
        (item[:triangle_a] + item[:triangle_b]).each { |point| bounds.add(point) }
      end
      bounds
    end

    private

    def draw_screen_label(view, world_point, text, color, y_offset)
      return unless view.respond_to?(:draw_text)

      screen = view.screen_coords(world_point)
      anchor = Geom::Point3d.new(screen.x + 10, screen.y + y_offset, 0)
      view.drawing_color = color
      view.draw_text(
        anchor,
        text,
        color: color,
        size: 14,
        bold: true
      )
    rescue ArgumentError
      # Older SketchUp builds may not accept the option Hash.
      view.drawing_color = color
      view.draw_text(anchor || world_point, text)
    end

    def draw_triangle(view, points, color)
      view.drawing_color = color
      view.draw(GL_TRIANGLES, points)
      view.line_width = 3 if view.respond_to?(:line_width=)
      view.draw(GL_LINE_LOOP, points)
    ensure
      view.line_width = 1 if view.respond_to?(:line_width=)
    end
  end

  module_function

  def run(mode: nil)
    mode ||= if defined?($lvn_hard_gate_deep_probe_mode)
               $lvn_hard_gate_deep_probe_mode
             else
               :normal
             end
    mode = mode.to_sym
    unless NORMALIZATION_MODES.include?(mode)
      raise ArgumentError,
            "mode must be one of #{NORMALIZATION_MODES.inspect}: #{mode.inspect}"
    end

    sanity_check!
    model = Sketchup.active_model
    entities = TARGETS.map do |pid, label|
      entity = find_entity(model, pid)
      warn "[LVN PROBE] not found: #{label} PID=#{pid}" unless entity
      [pid, label, entity]
    end
    selection = model.selection
    selection.clear
    entities.each { |_pid, _label, entity| selection.add(entity) if entity }

    result = {
      schema: 'ulol.lvn_hard_gate_deep_probe.v1',
      generated_at: Time.now.iso8601(3),
      normalization_mode: mode,
      targets: TARGETS,
      entities: []
    }
    overlay_items = []
    entities.each do |pid, label, entity|
      next unless entity

      analysis = analyze_entity(model, entity, pid, label, mode)
      result[:entities] << analysis
      overlay_items.concat(overlay_items_for(entity, analysis))
      print_summary(analysis)
    rescue StandardError => error
      result[:entities] << {
        pid: pid,
        label: label,
        error: "#{error.class}: #{error.message}",
        backtrace: Array(error.backtrace).first(20)
      }
      warn "[LVN PROBE] #{label} continued after error: #{error.class}: #{error.message}"
    end

    install_overlay(model, overlay_items)
    path = File.join(
      Dir.tmpdir,
      "lvn_hard_gate_deep_probe_#{mode}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
    )
    File.open(path, 'w:UTF-8') { |file| file.write(JSON.pretty_generate(json_safe(result))) }
    result[:json_path] = path
    $lvn_hard_gate_deep_probe = result
    puts "\n[LVN PROBE] JSON: #{path}"
    puts '[LVN PROBE] Full result: $lvn_hard_gate_deep_probe'
    result
  end

  def analyze_entity(model, entity, pid, label, mode)
    normalizer = ProbeNormalizer.new(
      LVN::DEFAULT_TOLERANCE_MM,
      model: model,
      normalization_mode: mode
    )
    started = false
    aborted = false
    error = nil
    begin
      started = model.start_operation("LVN hard-gate deep probe #{label}", true)
      raise 'SketchUp refused to start diagnostic operation' unless started

      normalizer.normalize(entity, manage_operation: false)
    rescue StandardError => caught
      error = "#{caught.class}: #{caught.message}"
    ensure
      begin
        if started
          model.abort_operation
          aborted = true
        end
      rescue StandardError => abort_error
        error = [error, "ABORT FAILED: #{abort_error.class}: #{abort_error.message}"].compact.join(' | ')
      end
    end
    probe = normalizer.finish_probe
    {
      pid: pid,
      label: label,
      name: (entity.name.to_s if entity.respond_to?(:name)),
      normalization_mode: mode,
      normalization_error: error,
      operation_started: started,
      operation_aborted: aborted,
      probe: probe
    }
  end

  def find_entity(model, pid)
    if model.respond_to?(:find_entity_by_persistent_id)
      found = model.find_entity_by_persistent_id(pid)
      found = found.leaf if found.respond_to?(:leaf)
      found = found.last if found.is_a?(Array)
      return found if found&.respond_to?(:valid?) && found.valid?
    end
    recursive_find(model.entities, pid, {})
  rescue StandardError
    recursive_find(model.entities, pid, {})
  end

  def recursive_find(entities, pid, visited)
    entities.each do |entity|
      return entity if (entity.persistent_id rescue nil) == pid
      children = if entity.respond_to?(:definition)
                   definition = entity.definition
                   next if visited[definition.object_id]
                   visited[definition.object_id] = true
                   definition.entities
                 elsif entity.respond_to?(:entities)
                   entity.entities
                 end
      found = recursive_find(children, pid, visited) if children
      return found if found
    end
    nil
  end

  def overlay_items_for(entity, analysis)
    transform = entity.respond_to?(:transformation) ? entity.transformation : Geom::Transformation.new
    Array(analysis.dig(:probe, :pair_analyses))
      .first(MAX_OVERLAY_PAIRS_PER_ENTITY)
      .map do |pair|
        a = points_for_overlay(pair[:triangle_a], transform)
        b = points_for_overlay(pair[:triangle_b], transform)
        {
          triangle_a: a,
          triangle_b: b,
          label_point_a: triangle_centroid(a),
          label_point_b: triangle_centroid(b),
          label_a:
            "#{analysis[:label]} A:red T#{pair[:indices][0]} " \
            "(sf=#{pair.dig(:triangle_a, :source_face_key)} " \
            "p=#{pair.dig(:triangle_a, :source_polygon_index)})",
          label_b:
            "#{analysis[:label]} B:blue T#{pair[:indices][1]} " \
            "(sf=#{pair.dig(:triangle_b, :source_face_key)} " \
            "p=#{pair.dig(:triangle_b, :source_polygon_index)})"
        }
      end
  rescue StandardError => error
    warn "[LVN PROBE] overlay capture failed: #{error.class}: #{error.message}"
    []
  end

  def triangle_centroid(points)
    Geom::Point3d.new(
      points.sum(&:x) / points.length,
      points.sum(&:y) / points.length,
      points.sum(&:z) / points.length
    )
  end

  def points_for_overlay(record, transform)
    tolerance = LVN::DEFAULT_TOLERANCE_MM
    record[:points_source_or_grid].map do |indices|
      Geom::Point3d.new(
        indices[0] * tolerance / LVN::MM_PER_INCH,
        indices[1] * tolerance / LVN::MM_PER_INCH,
        indices[2] * tolerance / LVN::MM_PER_INCH
      ).transform(transform)
    end
  end

  def install_overlay(model, items)
    old = $lvn_hard_gate_deep_probe_overlay
    model.overlays.remove(old) if old
    overlay = Overlay.new(items)
    model.overlays.add(overlay)
    overlay.enabled = true
    $lvn_hard_gate_deep_probe_overlay = overlay
    model.active_view.invalidate
  rescue StandardError => error
    warn "[LVN PROBE] overlay install failed, analysis preserved: #{error.class}: #{error.message}"
  end

  def print_summary(analysis)
    probe = analysis[:probe]
    hard = probe[:hard_gate] || {}
    puts "\n#{'=' * 100}"
    puts "ENTITY name=#{analysis[:name].inspect} pid=#{analysis[:pid]} label=#{analysis[:label]}"
    puts "NORMALIZATION MODE=#{analysis[:normalization_mode]}"
    puts "\n[PIPELINE]"
    probe[:stages].each do |stage|
      puts "  #{stage[:stage_index]} #{stage[:name]} triangles=#{stage[:triangle_count]}"
    end
    puts "\n[HARD GATE]"
    puts "  topology=#{hard.dig(:topology, :status) || 'NOT_REACHED'}"
    puts "  intersection=#{hard.dig(:geometry, :status) || 'NOT_REACHED'}"
    puts "  invalid_pairs=#{hard.dig(:geometry, :invalid_pairs).inspect}"
    puts "  first_invalid_stage=#{probe[:first_invalid_intersection_stage].inspect}"
    Array(probe[:pair_analyses]).each do |pair|
      puts "\n[PAIR ANALYSIS] T#{pair[:indices][0]} x T#{pair[:indices][1]}"
      exact = pair[:exact_intersection]
      puts "  relation=#{exact[:plane_relation]} shared=#{exact[:expected_shared_simplex]}"
      puts "  #{exact[:conclusion]}"
      split = pair[:edge_split_analysis].select { |entry| entry[:exact_between] }
      split = [pair[:edge_split_analysis].min_by do |entry|
        entry[:distance_to_segment_mm]
      end].compact if split.empty?
      puts "\n[EDGE SPLIT / T-JUNCTION]"
      puts "  #{split.map { |entry| entry[:classification] }.uniq.inspect}"
      puts "\n[AXIS CONSTRAINTS]"
      puts "  A mappings=#{pair[:axis_constraints_a].length}, B mappings=#{pair[:axis_constraints_b].length}"
      puts "\n[SLIVER LINEAGE]"
      puts "  A first=#{pair.dig(:sliver_lineage_a, :first_appeared_at).inspect}"
      puts "  B first=#{pair.dig(:sliver_lineage_b, :first_appeared_at).inspect}"
      puts "  A repair=#{pair.dig(:sliver_lineage_a, :short_edge_detector, :reason)}"
      puts "  B repair=#{pair.dig(:sliver_lineage_b, :short_edge_detector, :reason)}"
    end
    puts "\n[FIRST FAILURE INTRODUCTION] #{probe[:first_invalid_intersection_stage].inspect}"
    puts "normalization_error=#{analysis[:normalization_error]}"
    puts '=' * 100
  end

  def sanity_check!
    raise 'Target PID list changed unexpectedly' unless TARGETS.length == 4
    required = [
      :axis_plane_normalization_plan,
      :short_edge_sliver_collapse_plan,
      :triangle_snapshot,
      :conforming_triangle_snapshot,
      :collapse_source_altitude_sliver_triangles,
      :discard_collapsed_triangle_records,
      :normalize_triangle_records_allowing_collisions,
      :collapse_short_edge_sliver_triangles,
      :validate_normalized_triangle_mesh!,
      :collect_triangle_intersection_failures
    ]
    missing = required.reject do |method_name|
      LVN.private_method_defined?(method_name) || LVN.method_defined?(method_name)
    end
    raise "Production methods missing: #{missing.inspect}" unless missing.empty?
    rational = json_safe(Rational(2, 3))
    raise 'Rational JSON conversion failed' unless
      rational == { numerator: 2, denominator: 3 }
    JSON.generate(rational)

    # Regression guard: stage(...) returns a stage Hash, while conforming
    # analysis consumes its :triangles array. Mixing those shapes causes
    # "no implicit conversion of Symbol into Integer" immediately after the
    # first source triangle_snapshot.
    record = {
      triangle_index: 0,
      points_source_or_grid: [[0, 0, 0], [10, 0, 0], [0, 10, 0]],
      signature: [[0, 0, 0], [0, 10, 0], [10, 0, 0]],
      source_face_key: 1,
      source_polygon_index: 0
    }
    normalizer = ProbeNormalizer.new
    conforming = normalizer.send(
      :conforming_details,
      [record],
      [record],
      :grid
    )
    unless conforming[:vertex_candidate_count] == 3 &&
           conforming[:input_edge_count] == 3
      raise 'Conforming capture shape sanity failed'
    end
    true
  end

  def json_safe(value)
    case value
    when Rational
      { numerator: value.numerator, denominator: value.denominator }
    when Float
      value.finite? ? value : value.to_s
    when Symbol
      value.to_s
    when Array
      value.map { |entry| json_safe(entry) }
    when Hash
      value.each_with_object({}) do |(key, entry), result|
        result[key.to_s] = json_safe(entry)
      end
    when NilClass, TrueClass, FalseClass, Integer, String
      value
    else
      value.to_s
    end
  end
end

LvnHardGateDeepProbe.run unless
  defined?($lvn_hard_gate_deep_probe_no_autorun) &&
  $lvn_hard_gate_deep_probe_no_autorun
nil
