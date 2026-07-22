# frozen_string_literal: true

require 'json'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        # Diagnostic-only override. Production behavior is unchanged until a
        # coplanar patch rebuild raises; only the failing patch is then described.
        def retriangulate_exact_coplanar_patches(
          triangle_records,
          forced_source_face_keys: [],
          force_all: false
        )
          forced_keys = Array(forced_source_face_keys).compact.to_h { |key| [key, true] }
          patches = exact_coplanar_triangle_patches(triangle_records)
          rebuilt_records = []
          rebuilt_patches = 0
          preserved_patches = 0
          forced_patches = 0
          source_triangle_count = 0
          rebuilt_triangle_count = 0
          boundary_loop_count = 0
          hole_count = 0

          patches.each_with_index do |patch, patch_index|
            forced = force_all || patch.any? do |record|
              forced_keys[record[:source_face_key]]
            end
            required = forced || exact_coplanar_patch_retriangulation_required?(patch)
            unless required
              rebuilt_records.concat(patch)
              preserved_patches += 1
              next
            end

            begin
              replacement, patch_report = retriangulate_exact_coplanar_patch(patch)
            rescue Error, ArgumentError => error
              emit_exact_coplanar_patch_provenance_trace(
                patch,
                patch_index: patch_index,
                patch_count: patches.length,
                forced_keys: forced_keys,
                force_all: force_all,
                forced: forced,
                error: error
              )
              raise
            end

            rebuilt_records.concat(replacement)
            rebuilt_patches += 1
            forced_patches += 1 if forced
            source_triangle_count += patch.length
            rebuilt_triangle_count += replacement.length
            boundary_loop_count += patch_report[:boundary_loops]
            hole_count += patch_report[:holes]
          end

          [
            rebuilt_records,
            {
              detected_patches: patches.length,
              rebuilt_patches: rebuilt_patches,
              preserved_patches: preserved_patches,
              forced_patches: forced_patches,
              forced_source_face_keys: forced_keys.keys,
              source_triangles: source_triangle_count,
              rebuilt_triangles: rebuilt_triangle_count,
              boundary_loops: boundary_loop_count,
              holes: hole_count
            }
          ]
        end

        def emit_exact_coplanar_patch_provenance_trace(
          patch,
          patch_index:,
          patch_count:,
          forced_keys:,
          force_all:,
          forced:,
          error:
        )
          triangles = patch.map do |record|
            record[:points].map { |point| grid_indices(point) }
          end

          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          patch.each_with_index do |record, record_index|
            triangle = triangles.fetch(record_index)
            3.times do |edge_index|
              edge = canonical_edge_key(
                triangle[edge_index],
                triangle[(edge_index + 1) % 3]
              )
              edge_owners[edge] << {
                record_index: record_index,
                source_face_key: record[:source_face_key],
                source_polygon_index: record[:source_polygon_index]
              }
            end
          end

          boundary_owner_records = edge_owners.filter_map do |edge, owners|
            next unless owners.length == 1

            {
              edge: edge,
              owners: owners
            }
          end

          intersection_error = nil
          begin
            validate_triangle_intersections!(triangles)
          rescue Error, ArgumentError => validation_error
            intersection_error = "#{validation_error.class}: #{validation_error.message}"
          end

          required_by_geometry = begin
            exact_coplanar_patch_retriangulation_required?(patch)
          rescue Error, ArgumentError => requirement_error
            "ERROR: #{requirement_error.class}: #{requirement_error.message}"
          end

          plane_key = exact_integer_plane_key(triangles.first)
          drop_axis = plane_key.first(3).each_index.max_by do |axis|
            plane_key[axis].abs
          end

          loop_trace = begin
            loops = exact_boundary_loops(boundary_owner_records.map { |entry| entry[:edge] })
            loops.map.with_index do |loop, loop_index|
              projected = loop.map { |point| integer_project_2d(point, drop_axis) }
              {
                loop_index: loop_index,
                points: loop,
                projected: projected,
                area2: integer_polygon_area2(projected),
                simple: simple_integer_polygon_2d?(projected)
              }
            end
          rescue Error, ArgumentError => loop_error
            {
              error: "#{loop_error.class}: #{loop_error.message}"
            }
          end

          source_face_keys = patch.filter_map { |record| record[:source_face_key] }.uniq
          forced_source_face_keys_in_patch = source_face_keys.select do |key|
            forced_keys[key]
          end

          triangle_records = patch.each_with_index.map do |record, record_index|
            triangle = triangles.fetch(record_index)
            source_normal = Array(record[:source_normal]).map(&:to_f)
            actual_normal = integer_triangle_normal(triangle)
            reversed_from_source = source_normal.length == 3 &&
              vector_dot(actual_normal, source_normal).negative?

            {
              record_index: record_index,
              source_face_key: record[:source_face_key],
              source_polygon_index: record[:source_polygon_index],
              force_retriangulation: !!record[:force_retriangulation],
              points: triangle,
              source_normal: source_normal,
              actual_normal: actual_normal,
              reversed_from_source: reversed_from_source,
              minimum_altitude_mm: exact_triangle_minimum_altitude_mm(triangle)
            }
          end

          trace = {
            trace: 'LVN exact coplanar patch provenance',
            error: "#{error.class}: #{error.message}",
            tolerance_mm: @tolerance_mm,
            strict_coplanar_tolerance_mm: STRICT_COPLANAR_TOLERANCE_MM,
            patch_index: patch_index,
            detected_patch_count: patch_count,
            patch_triangle_count: patch.length,
            source_face_keys: source_face_keys,
            forced_source_face_keys: forced_keys.keys,
            forced_source_face_keys_in_patch: forced_source_face_keys_in_patch,
            force_all: force_all,
            forced: forced,
            required_by_geometry: required_by_geometry,
            plane_key: plane_key,
            drop_axis: drop_axis,
            triangles_intersect_before_retriangulation: !intersection_error.nil?,
            pre_retriangulation_intersection_error: intersection_error,
            triangles: triangle_records,
            boundary_edges: boundary_owner_records,
            boundary_loops: loop_trace
          }

          puts '\n=== LVN COPLANAR PATCH PROVENANCE BEGIN ==='
          puts JSON.pretty_generate(trace)
          puts '=== LVN COPLANAR PATCH PROVENANCE END ==='
        rescue StandardError => trace_error
          puts '\n=== LVN COPLANAR PATCH PROVENANCE TRACE FAILED ==='
          puts "#{trace_error.class}: #{trace_error.message}"
          puts trace_error.backtrace.first(20)
          puts '=== LVN COPLANAR PATCH PROVENANCE TRACE FAILED END ==='
        end
      end
    end
  end
end
