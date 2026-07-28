# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        GRID_ALTITUDE_SLIVER_MAX_PATCH_ATTEMPTS = 50 unless
          const_defined?(:GRID_ALTITUDE_SLIVER_MAX_PATCH_ATTEMPTS, false)
        GRID_INVALID_SOURCE_FACE_MAX_ATTEMPTS = 50 unless
          const_defined?(:GRID_INVALID_SOURCE_FACE_MAX_ATTEMPTS, false)

        private

        unless private_method_defined?(:normalize_triangle_records_before_grid_altitude_sliver_v2)
          alias_method :normalize_triangle_records_before_grid_altitude_sliver_v2,
                       :normalize_triangle_records_allowing_collisions
        end

        def normalize_triangle_records_allowing_collisions(
          records,
          axis_plane_plan = nil,
          duplicate_diagnostics: nil
        )
          snapped, report = normalize_triangle_records_before_grid_altitude_sliver_v2(
            records,
            axis_plane_plan,
            duplicate_diagnostics: duplicate_diagnostics
          )

          repaired, repair_report = retriangulate_grid_altitude_slivers(snapped)
          @grid_altitude_sliver_retriangulation_stats_v2 = repair_report
          [repaired, report]
        end

        # Preserve the established altitude-sliver path first. Only when that path
        # is inapplicable, or leaves exact invalid intersections behind, try the
        # more general source-Face retriangulation fallback. This keeps previously
        # successful sliver repairs unchanged while covering snap-induced
        # intersections between otherwise well-shaped triangles.
        def retriangulate_grid_altitude_slivers(triangle_records)
          threshold_mm = @tolerance_mm
          input_slivers = grid_altitude_sliver_indices(triangle_records, threshold_mm)
          initial_invalid = grid_invalid_pair_signatures(triangle_records)

          if input_slivers.empty?
            if initial_invalid.empty?
              return [
                triangle_records,
                empty_grid_altitude_sliver_retriangulation_report(
                  triangle_records.length,
                  threshold_mm,
                  :no_low_altitude_triangles_or_invalid_pairs
                )
              ]
            end

            repaired, invalid_report = retriangulate_grid_invalid_source_faces(
              triangle_records
            )
            return [
              repaired,
              empty_grid_altitude_sliver_retriangulation_report(
                triangle_records.length,
                threshold_mm,
                invalid_report[:accepted_face_count].positive? ? nil : :no_safe_invalid_face_retriangulation,
                initial_invalid_pair_count: initial_invalid.length,
                final_invalid_pair_count: invalid_report[:final_invalid_pair_count],
                invalid_source_face_retriangulation: invalid_report
              )
            ]
          end

          working = triangle_records.dup
          current_invalid = initial_invalid
          attempts = []
          accepted = []
          attempted_patch_count = 0

          loop do
            break if attempted_patch_count >= GRID_ALTITUDE_SLIVER_MAX_PATCH_ATTEMPTS

            sliver_indices = grid_altitude_sliver_indices(working, threshold_mm)
            break if sliver_indices.empty?

            patches = grid_altitude_sliver_patches(working, sliver_indices)
            break if patches.empty?

            best = nil
            patches.each do |patch_indices|
              break if attempted_patch_count >= GRID_ALTITUDE_SLIVER_MAX_PATCH_ATTEMPTS

              attempted_patch_count += 1
              patch_records = patch_indices.map { |index| working[index] }
              before_low_count = patch_records.count do |record|
                grid_altitude_sliver_record?(record, threshold_mm)
              end
              next if before_low_count.zero? || patch_records.length < 2

              before_min_altitude = patch_records.map do |record|
                grid_record_minimum_altitude_mm(record)
              end.min

              begin
                replacements, details = retriangulate_exact_coplanar_patch(patch_records)
                next if same_grid_triangle_set?(patch_records, replacements)

                after_low_count = replacements.count do |record|
                  grid_altitude_sliver_record?(record, threshold_mm)
                end
                after_min_altitude = replacements.map do |record|
                  grid_record_minimum_altitude_mm(record)
                end.min

                unless after_low_count < before_low_count &&
                       after_min_altitude > before_min_altitude
                  attempts << {
                    source_face_key: patch_records.first[:source_face_key],
                    patch_triangle_count: patch_records.length,
                    accepted: false,
                    reason: :altitude_not_improved,
                    before_low_altitude_count: before_low_count,
                    after_low_altitude_count: after_low_count,
                    before_minimum_altitude_mm: before_min_altitude,
                    after_minimum_altitude_mm: after_min_altitude
                  }
                  next
                end

                tentative = replace_grid_patch(working, patch_indices, replacements)
                tentative_invalid = grid_invalid_pair_signatures(tentative)
                new_invalid = tentative_invalid - current_invalid
                removed_invalid = current_invalid - tentative_invalid

                unless new_invalid.empty?
                  attempts << {
                    source_face_key: patch_records.first[:source_face_key],
                    patch_triangle_count: patch_records.length,
                    accepted: false,
                    reason: :new_invalid_pairs,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length,
                    new_invalid_pair_count: new_invalid.length,
                    removed_invalid_pair_count: removed_invalid.length
                  }
                  next
                end

                candidate = {
                  records: tentative,
                  invalid_pairs: tentative_invalid,
                  report: {
                    source_face_key: patch_records.first[:source_face_key],
                    patch_triangle_count: patch_records.length,
                    replacement_triangle_count: replacements.length,
                    accepted: true,
                    before_low_altitude_count: before_low_count,
                    after_low_altitude_count: after_low_count,
                    before_minimum_altitude_mm: before_min_altitude,
                    after_minimum_altitude_mm: after_min_altitude,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length,
                    removed_invalid_pair_count: removed_invalid.length,
                    boundary_loops: details[:boundary_loops],
                    holes: details[:holes]
                  }
                }

                score = [
                  before_low_count - after_low_count,
                  removed_invalid.length,
                  after_min_altitude - before_min_altitude
                ]
                best = [score, candidate] if best.nil? || (score <=> best[0]) == 1
              rescue Error, ArgumentError => error
                attempts << {
                  source_face_key: patch_records.first[:source_face_key],
                  patch_triangle_count: patch_records.length,
                  accepted: false,
                  reason: :retriangulation_rejected,
                  error: "#{error.class}: #{error.message}"
                }
              end
            end

            break unless best

            chosen = best[1]
            working = chosen[:records]
            current_invalid = chosen[:invalid_pairs]
            accepted << chosen[:report]
            attempts << chosen[:report]
          end

          invalid_report = empty_grid_invalid_source_face_retriangulation_report(
            current_invalid.length
          )
          unless current_invalid.empty?
            working, invalid_report = retriangulate_grid_invalid_source_faces(working)
            current_invalid = grid_invalid_pair_signatures(working)
          end

          remaining_slivers = grid_altitude_sliver_indices(working, threshold_mm)
          affected_source_face_keys = (
            accepted.map { |entry| entry[:source_face_key] } +
            Array(invalid_report[:affected_source_face_keys])
          ).compact.uniq
          any_repair = !accepted.empty? || invalid_report[:accepted_face_count].positive?

          [
            working,
            {
              policy: :altitude_then_invalid_source_face_retriangulation,
              threshold_mm: threshold_mm,
              input_triangle_count: triangle_records.length,
              output_triangle_count: working.length,
              detected_sliver_count: input_slivers.length,
              remaining_sliver_count: remaining_slivers.length,
              initial_invalid_pair_count: initial_invalid.length,
              final_invalid_pair_count: current_invalid.length,
              attempted_patch_count: attempted_patch_count,
              accepted_patch_count: accepted.length,
              invalid_pair_reduction: initial_invalid.length - current_invalid.length,
              affected_source_face_keys: affected_source_face_keys,
              accepted_patches: accepted.first(20),
              attempts: attempts.first(40),
              invalid_source_face_retriangulation: invalid_report,
              skipped: !any_repair,
              skip_reason: any_repair ? nil : :no_safe_improving_patch
            }
          ]
        end

        def empty_grid_altitude_sliver_retriangulation_report(
          input_triangle_count,
          threshold_mm,
          reason,
          initial_invalid_pair_count: 0,
          final_invalid_pair_count: 0,
          invalid_source_face_retriangulation: nil
        )
          invalid_report = invalid_source_face_retriangulation ||
            empty_grid_invalid_source_face_retriangulation_report(
              initial_invalid_pair_count
            )
          applied = invalid_report[:accepted_face_count].to_i.positive?

          {
            policy: :altitude_then_invalid_source_face_retriangulation,
            threshold_mm: threshold_mm,
            input_triangle_count: input_triangle_count,
            output_triangle_count: invalid_report.fetch(
              :output_triangle_count,
              input_triangle_count
            ),
            detected_sliver_count: 0,
            remaining_sliver_count: 0,
            initial_invalid_pair_count: initial_invalid_pair_count,
            final_invalid_pair_count: final_invalid_pair_count,
            attempted_patch_count: 0,
            accepted_patch_count: 0,
            invalid_pair_reduction:
              initial_invalid_pair_count - final_invalid_pair_count,
            affected_source_face_keys:
              Array(invalid_report[:affected_source_face_keys]),
            accepted_patches: [],
            attempts: [],
            invalid_source_face_retriangulation: invalid_report,
            skipped: !applied,
            skip_reason: applied ? nil : reason
          }
        end

        # When grid snapping creates an invalid triangle pair without creating a
        # low-altitude triangle, the old repair path had no candidate at all. Use
        # the original source Face as the smallest trustworthy ownership unit:
        # rebuild only affected Face triangulations from their preserved boundary,
        # never move a vertex, and accept a candidate only when it removes at least
        # one existing invalid pair, creates none, and preserves closed topology.
        def retriangulate_grid_invalid_source_faces(triangle_records)
          initial_invalid_pairs = grid_invalid_pairs(triangle_records)
          initial_invalid = grid_invalid_pair_signatures(triangle_records)
          return [
            triangle_records,
            empty_grid_invalid_source_face_retriangulation_report(0)
          ] if initial_invalid_pairs.empty?

          working = triangle_records.dup
          current_invalid = initial_invalid
          attempts = []
          accepted = []
          attempted_face_count = 0

          loop do
            break if current_invalid.empty?
            break if attempted_face_count >= GRID_INVALID_SOURCE_FACE_MAX_ATTEMPTS

            invalid_pairs = grid_invalid_pairs(working)
            candidate_face_keys = invalid_pairs.flat_map do |first, second|
              [working[first][:source_face_key], working[second][:source_face_key]]
            end.compact.uniq
            break if candidate_face_keys.empty?

            best = nil
            candidate_face_keys.each do |source_face_key|
              break if attempted_face_count >= GRID_INVALID_SOURCE_FACE_MAX_ATTEMPTS

              patch_indices = working.each_index.select do |index|
                working[index][:source_face_key] == source_face_key &&
                  !degenerate_triangle_record?(working[index])
              end
              next if patch_indices.length < 2

              attempted_face_count += 1
              patch_records = patch_indices.map { |index| working[index] }
              begin
                replacements, details = retriangulate_grid_source_face_patch(
                  patch_records
                )
                next if same_grid_triangle_set?(patch_records, replacements)

                tentative = replace_grid_patch(working, patch_indices, replacements)
                validate_normalized_triangle_topology!(tentative)
                tentative_invalid = grid_invalid_pair_signatures(tentative)
                new_invalid = tentative_invalid - current_invalid
                removed_invalid = current_invalid - tentative_invalid

                unless new_invalid.empty?
                  attempts << {
                    source_face_key: source_face_key,
                    patch_triangle_count: patch_records.length,
                    accepted: false,
                    reason: :new_invalid_pairs,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length,
                    new_invalid_pair_count: new_invalid.length,
                    removed_invalid_pair_count: removed_invalid.length
                  }
                  next
                end
                if removed_invalid.empty?
                  attempts << {
                    source_face_key: source_face_key,
                    patch_triangle_count: patch_records.length,
                    accepted: false,
                    reason: :invalid_pairs_not_reduced,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length
                  }
                  next
                end

                candidate = {
                  records: tentative,
                  invalid_pairs: tentative_invalid,
                  report: {
                    source_face_key: source_face_key,
                    patch_triangle_count: patch_records.length,
                    replacement_triangle_count: replacements.length,
                    accepted: true,
                    before_invalid_pair_count: current_invalid.length,
                    after_invalid_pair_count: tentative_invalid.length,
                    removed_invalid_pair_count: removed_invalid.length,
                    boundary_loops: details[:boundary_loops],
                    holes: details[:holes]
                  }
                }
                score = [
                  removed_invalid.length,
                  patch_records.length - replacements.length,
                  -replacements.length
                ]
                best = [score, candidate] if best.nil? || (score <=> best[0]) == 1
              rescue Error, ArgumentError => error
                attempts << {
                  source_face_key: source_face_key,
                  patch_triangle_count: patch_records.length,
                  accepted: false,
                  reason: :source_face_retriangulation_rejected,
                  error: "#{error.class}: #{error.message}"
                }
              end
            end

            break unless best

            chosen = best[1]
            working = chosen[:records]
            current_invalid = chosen[:invalid_pairs]
            accepted << chosen[:report]
            attempts << chosen[:report]
          end

          [
            working,
            {
              policy: :invalid_pair_driven_source_face_retriangulation,
              input_triangle_count: triangle_records.length,
              output_triangle_count: working.length,
              initial_invalid_pair_count: initial_invalid.length,
              final_invalid_pair_count: current_invalid.length,
              invalid_pair_reduction: initial_invalid.length - current_invalid.length,
              attempted_face_count: attempted_face_count,
              accepted_face_count: accepted.length,
              affected_source_face_keys:
                accepted.map { |entry| entry[:source_face_key] }.compact.uniq,
              accepted_faces: accepted.first(20),
              attempts: attempts.first(40),
              skipped: accepted.empty?,
              skip_reason: accepted.empty? ? :no_safe_improving_source_face : nil
            }
          ]
        end

        def empty_grid_invalid_source_face_retriangulation_report(
          invalid_pair_count,
          triangle_count = nil
        )
          {
            policy: :invalid_pair_driven_source_face_retriangulation,
            input_triangle_count: triangle_count,
            output_triangle_count: triangle_count,
            initial_invalid_pair_count: invalid_pair_count,
            final_invalid_pair_count: invalid_pair_count,
            invalid_pair_reduction: 0,
            attempted_face_count: 0,
            accepted_face_count: 0,
            affected_source_face_keys: [],
            accepted_faces: [],
            attempts: [],
            skipped: true,
            skip_reason: invalid_pair_count.zero? ? :no_invalid_pairs : :no_attempt
          }
        end

        # Rebuilds one snapped source Face from its current boundary graph. The
        # source Face can be microscopically non-planar after independent grid
        # rounding, so triangulation decisions use the dominant 2D projection of
        # its original source normal while replacement vertices stay on the exact
        # snapped 3D grid coordinates.
        def retriangulate_grid_source_face_patch(patch)
          source_face_keys = patch.map { |record| record[:source_face_key] }.compact.uniq
          unless source_face_keys.length == 1
            raise ReconstructionError,
                  "Grid source-Face patch has mixed provenance: #{source_face_keys.inspect}"
          end

          point_by_key = {}
          edge_owners = Hash.new { |hash, key| hash[key] = [] }
          patch.each_with_index do |record, index|
            triangle = record[:points].map do |point|
              key = grid_indices(point)
              point_by_key[key] ||= point
              key
            end
            3.times do |edge_index|
              edge = canonical_edge_key(
                triangle[edge_index],
                triangle[(edge_index + 1) % 3]
              )
              edge_owners[edge] << index
            end
          end

          overused = edge_owners.select { |_edge, owners| owners.length > 2 }
          unless overused.empty?
            raise TopologyChangedError,
                  "Grid source-Face patch has overused edges: #{overused.first(10).inspect}"
          end

          boundary_edges = edge_owners.filter_map do |edge, owners|
            edge if owners.length == 1
          end
          if boundary_edges.empty?
            raise TopologyChangedError, 'Grid source-Face patch has no preserved boundary'
          end

          loops = exact_boundary_loops(boundary_edges)
          source_normal = Array(patch.first[:source_normal]).map(&:to_f)
          unless source_normal.length == 3 && source_normal.any? { |value| value.abs > 0.0 }
            raise ReconstructionError, 'Grid source-Face patch has no usable source normal'
          end
          drop_axis = source_normal.each_index.max_by { |axis| source_normal[axis].abs }
          outer, holes = classify_exact_patch_loops(loops, drop_axis)
          expected_area2 = integer_polygon_area2(
            outer.map { |point| integer_project_2d(point, drop_axis) }
          ).abs - holes.sum do |hole|
            integer_polygon_area2(
              hole.map { |point| integer_project_2d(point, drop_axis) }
            ).abs
          end
          unless expected_area2.positive?
            raise TopologyChangedError,
                  'Grid source-Face patch has zero projected boundary area'
          end

          triangle_keys = triangulate_exact_polygon_with_holes(
            outer,
            holes,
            drop_axis
          )
          template = patch.first
          replacements = triangle_keys.each_with_index.map do |keys, index|
            points = keys.map { |key| point_by_key.fetch(key) }
            points = orient_patch_triangle(points, source_normal)
            template.merge(
              points: points,
              source_polygon_index: index,
              grid_source_face_retriangulated: true
            )
          end

          validate_exact_patch_replacement!(
            replacements,
            boundary_edges,
            loops.length,
            drop_axis,
            expected_area2
          )

          [
            replacements,
            {
              boundary_loops: loops.length,
              holes: holes.length,
              source_face_key: source_face_keys.first
            }
          ]
        end

        def grid_altitude_sliver_indices(records, threshold_mm)
          records.each_index.select do |index|
            grid_altitude_sliver_record?(records[index], threshold_mm)
          end
        end

        def grid_altitude_sliver_record?(record, threshold_mm)
          return false if degenerate_triangle_record?(record)

          grid_record_minimum_altitude_mm(record) < threshold_mm
        end

        def grid_record_minimum_altitude_mm(record)
          triangle = record[:points].map { |point| grid_indices(point) }
          exact_triangle_minimum_altitude_mm(triangle)
        end

        def grid_altitude_sliver_patches(records, sliver_indices)
          sliver_lookup = sliver_indices.to_h { |index| [index, true] }
          indexed = records.each_index.filter_map do |index|
            record = records[index]
            next if degenerate_triangle_record?(record)

            [index, record]
          end

          groups = indexed.group_by do |_index, record|
            [record[:source_face_key], exact_coplanar_patch_key(record)]
          end

          patches = []
          groups.each_value do |entries|
            edge_owners = Hash.new { |hash, key| hash[key] = [] }
            entries.each do |index, record|
              triangle = record[:points].map { |point| grid_indices(point) }
              exact_triangle_edge_keys(triangle).each do |edge|
                edge_owners[edge] << index
              end
            end

            adjacency = Hash.new { |hash, key| hash[key] = [] }
            entries.each { |index, _record| adjacency[index] }
            edge_owners.each_value do |owners|
              next unless owners.length == 2

              first, second = owners
              adjacency[first] << second
              adjacency[second] << first
            end

            visited = {}
            entries.each do |seed, _record|
              next if visited[seed]

              visited[seed] = true
              queue = [seed]
              component = []
              until queue.empty?
                current = queue.shift
                component << current
                adjacency[current].each do |neighbor|
                  next if visited[neighbor]

                  visited[neighbor] = true
                  queue << neighbor
                end
              end

              next unless component.any? { |index| sliver_lookup[index] }
              patches << component.sort
            end
          end

          patches.sort_by do |indices|
            [
              indices.map do |index|
                grid_record_minimum_altitude_mm(records[index])
              end.min,
              indices.first
            ]
          end
        end

        def same_grid_triangle_set?(first_records, second_records)
          first = first_records.map do |record|
            canonical_triangle_key(record[:points].map { |point| grid_indices(point) })
          end.sort
          second = second_records.map do |record|
            canonical_triangle_key(record[:points].map { |point| grid_indices(point) })
          end.sort
          first == second
        end

        def replace_grid_patch(records, patch_indices, replacements)
          result = records.dup
          insertion_index = patch_indices.min
          patch_indices.sort.reverse_each { |index| result.delete_at(index) }
          replacements.reverse_each { |record| result.insert(insertion_index, record) }
          result
        end

        def grid_invalid_pairs(records)
          active = records.each_index.filter_map do |index|
            record = records[index]
            next if degenerate_triangle_record?(record)

            [index, record[:points].map { |point| grid_indices(point) }]
          end
          failures = collect_triangle_intersection_failures(
            active.map { |_index, triangle| triangle }
          )
          failures[:pairs].map do |first, second|
            [active[first][0], active[second][0]]
          end
        end

        def grid_invalid_pair_signatures(records)
          grid_invalid_pairs(records).map do |first, second|
            triangles = [first, second].map do |index|
              records[index][:points].map { |point| grid_indices(point) }
            end
            triangles.map { |triangle| canonical_triangle_key(triangle) }.sort
          end.uniq.sort
        end
      end
    end
  end
end
