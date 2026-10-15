# frozen_string_literal: true

require_relative 'reference_graph_contraction'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Non-destructive COLLAPSED stage. Native, not Ruby, certifies that a
      # BEFORE loop spans a hole-free Solid membrane. This stage only verifies
      # the certificate's structural applicability to the immutable AFTER
      # graph, selects nonconflicting candidates, and delegates EVERY graph
      # mutation to ReferenceGraphContraction.contract.
      module ReferenceGraphLoopCollapser
        MAX_COLLAPSES = 256
        MAX_LOOP_VERTICES = 32

        module_function

        # Callback contract:
        #   los_validator.call(Point3d, Point3d) == true on Native clear LOS
        #   point_validator.call(Point3d, Float) == true on valid Solid point
        # Native certificates also authorize their exact representative and
        # the member/external links that Native verified. Callbacks are only
        # needed for edges not covered by that certificate.
        def collapse(after_graph, verified_candidates, los_validator: nil,
                     point_validator: nil)
          source = canonical_snapshot(after_graph)
          nodes = source.fetch(:nodes)
          edges = source.fetch(:edges)
          origins = source.fetch(:original_indices)
          records = Array(verified_candidates)

          unless valid_snapshot?(nodes, edges, origins)
            return unchanged(source, records.length)
          end

          adjacency = adjacency_for(nodes.length, edges)
          index_of = {}
          origins.each_with_index { |original, index| index_of[original] = index unless original.nil? }

          # Detect and evaluate EVERY candidate from the same frozen AFTER
          # snapshot; never synthesize a Ruby Hole certificate or new cycle.
          discovered = records.filter_map do |record|
            normalized = normalize_certificate(record, nodes.first[:point])
            next unless normalized
            candidate = candidate_for(normalized, nodes, origins, index_of, adjacency)
            next unless candidate
            candidate.freeze
          end
          discovered.sort_by! { |candidate| candidate.fetch(:priority) }

          # If duplicate records disagree, prefer the deterministic record
          # ordering. Preflight against the original snapshot before selecting
          # mutually exclusive contractions, so a failed candidate cannot
          # prevent a later independent candidate from being selected.
          eligible = []
          seen_rings = {}
          discovered.each do |candidate|
            signature = candidate.fetch(:original_vertices).sort.freeze
            next if seen_rings[signature]
            preflight = apply_candidate(source, candidate,
                                        los_validator: los_validator,
                                        point_validator: point_validator)
            next unless preflight[:accepted]
            seen_rings[signature] = true
            eligible << candidate
          end

          selected = []
          reserved = {}
          eligible.each do |candidate|
            break if selected.size >= MAX_COLLAPSES
            vertices = candidate.fetch(:after_vertices)
            next if vertices.any? { |index| reserved[index] }
            # Cross-edges whose two endpoints both disappear would demand
            # an unchecked new representative-to-representative LOS.
            removed = candidate.fetch(:removed_indices)
            next if selected.any? { |other|
              removed.any? { |a|
                other.fetch(:removed_indices).any? { |b| adjacency[a].include?(b) }
              }
            }
            selected << candidate
            vertices.each { |index| reserved[index] = true }
          end

          current = source
          completed = 0
          selected.each do |candidate|
            # Re-resolve CURRENT indices through stable BEFORE original ids.
            # Original local AFTER indices are never reused after reindexing.
            outcome = apply_candidate(current, candidate,
                                      los_validator: los_validator,
                                      point_validator: point_validator)
            next unless outcome[:accepted]
            current = outcome.fetch(:graph)
            completed += 1
          end

          stats = {
            collapse_count: completed,
            loop_count: discovered.size,
            eligible_count: eligible.size,
            rejected_count: records.size - completed,
            triangle_count: discovered.count { |candidate| candidate[:original_vertices].size == 3 }
          }
          current.merge(stats).freeze
        end

        def canonical_snapshot(source)
          hash = Hash(source)
          nodes = Array(hash.fetch(:nodes))
          edges = Array(hash.fetch(:edges)).map { |pair| Array(pair).dup.freeze }
          order = (0...edges.length).to_a
          # Canonical edge ordering is part of the output contract, even if
          # no certificate survived. Preserve per-edge metadata alignment.
          if edges.all? { |pair| pair.length == 2 && pair.all? { |i| i.is_a?(Integer) } }
            order.sort_by! { |index| edges[index] }
          end
          updates = {
            nodes: nodes.dup.freeze,
            edges: order.map { |index| edges[index] }.freeze,
            original_indices: Array(hash.fetch(:original_indices)).dup.freeze,
            merged_into: Array(hash[:merged_into]).map { |pair| Array(pair).dup.freeze }.freeze,
            contraction_history: Array(hash[:contraction_history]).dup.freeze
          }
          %i[edge_weights edge_metadata].each do |field|
            next unless hash.key?(field)
            values = Array(hash[field])
            updates[field] = order.map { |index| values[index] }.freeze if values.length == edges.length
          end
          hash.merge(updates).freeze
        end

        def valid_snapshot?(nodes, edges, origins)
          return false if nodes.empty? || nodes.size != origins.size || origins.first != 0
          return false unless origins.compact.all? { |id| id.is_a?(Integer) && id >= 0 }
          return false unless origins.compact.uniq.size == origins.compact.size
          return false unless nodes.all? { |record|
            record.is_a?(Hash) && record[:radius].is_a?(Numeric) &&
              record[:radius].finite? && record[:radius] >= 0 && valid_point?(record[:point])
          }
          seen = {}
          edges.all? do |pair|
            a, b = pair
            next false unless a.is_a?(Integer) && b.is_a?(Integer) &&
                              a.between?(0, nodes.size - 1) &&
                              b.between?(0, nodes.size - 1) && a < b
            key = [a, b]
            next false if seen[key]
            seen[key] = true
          end
        end

        def valid_point?(point)
          point && %i[x y z].all? do |axis|
            value = point.public_send(axis)
            value.is_a?(Numeric) && value.finite?
          end
        rescue NoMethodError
          false
        end

        def normalize_certificate(record, point_type_reference)
          record = Hash(record)
          ids = Array(record[:vertices] || record[:triangle])
          return nil unless ids.length.between?(3, MAX_LOOP_VERTICES) &&
                            ids.uniq.length == ids.length &&
                            ids.all? { |id| id.is_a?(Integer) && id >= 0 }
          coordinates = record[:point]
          coords = if coordinates.respond_to?(:x)
                     [coordinates.x, coordinates.y, coordinates.z]
                   else
                     Array(coordinates)
                   end
          return nil unless coords.length == 3 &&
                            coords.all? { |number| number.is_a?(Numeric) && number.finite? }
          radius = record[:radius]
          return nil unless radius.is_a?(Numeric) && radius.finite? && radius >= 0
          visible = Array(record[:visible_neighbors])
          return nil unless visible.uniq.size == visible.size &&
                            visible.all? { |id| id.is_a?(Integer) && id >= 0 }
          point = point_type_reference.class.new(*coords)
          {
            original_vertices: canonical_ring(ids).freeze,
            point: point.freeze,
            radius: radius.to_f,
            visible_originals: visible.freeze
          }.freeze
        rescue ArgumentError, TypeError, NoMethodError
          nil
        end

        def canonical_ring(ids)
          min_position = ids.index(ids.min)
          first = ids.rotate(min_position)
          backward = [first.first] + first.drop(1).reverse
          (first <=> backward) <= 0 ? first : backward
        end

        def adjacency_for(count, edges)
          adjacency = Array.new(count) { [] }
          edges.each do |a, b|
            next unless a.is_a?(Integer) && b.is_a?(Integer) &&
                        a.between?(0, count - 1) && b.between?(0, count - 1) && a != b
            adjacency[a] << b
            adjacency[b] << a
          end
          adjacency.each(&:sort!)
        end

        def candidate_for(certificate, nodes, origins, index_of, adjacency)
          ring = certificate.fetch(:original_vertices)
          after = ring.map { |id| index_of[id] }
          # A BEFORE member absorbed by AFTER cannot be resurrected.
          return nil if after.any?(&:nil?) || after.uniq.length != after.length
          members = after.to_h { |index| [index, true] }
          length = after.size
          return nil unless length.times.all? do |i|
            adjacency[after[i]].include?(after[(i + 1) % length])
          end
          # Induced ring: precisely two ring-neighbors per member, no chords.
          return nil unless after.all? do |index|
            adjacency[index].count { |neighbor| members[neighbor] } == 2
          end

          state = ring.include?(0)
          return nil if state && (after.first != 0 || point_key(certificate[:point]) != point_key(nodes[0][:point]))
          removed = state ? after.reject(&:zero?) : after
          boundary = after.flat_map { |index| adjacency[index] }
                          .reject { |index| members[index] }.uniq.sort
          area = loop_area(nodes, after)
          return nil unless area.finite? && area.positive?

          # Area and ids are derived for deterministic PRIORITY ONLY.
          # Ruby does not validate planar membranes or infer Hole-free status.
          certificate.merge(
            after_vertices: after.freeze,
            removed_indices: removed.freeze,
            boundary_indices: boundary.freeze,
            state_loop: state,
            priority: [area, length, ring, point_key(certificate[:point]), certificate[:radius],
                       certificate[:visible_originals].sort].freeze
          )
        end

        def loop_area(nodes, vertices)
          # Newell-area magnitude handles planar sloping cycles; do not use
          # signed XY area (which vanishes for nearly vertical planes).
          nx = ny = nz = 0.0
          vertices.each_with_index do |vertex, index|
            a = nodes[vertex][:point]
            b = nodes[vertices[(index + 1) % vertices.length]][:point]
            nx += a.y * b.z - a.z * b.y
            ny += a.z * b.x - a.x * b.z
            nz += a.x * b.y - a.y * b.x
          end
          0.5 * Math.sqrt(nx * nx + ny * ny + nz * nz)
        end

        def apply_candidate(graph, candidate, los_validator:, point_validator:)
          originals = Array(graph.fetch(:original_indices))
          current = {}
          originals.each_with_index { |id, index| current[id] = index unless id.nil? }
          indices = candidate.fetch(:original_vertices).map { |id| current[id] }
          return { accepted: false } if indices.any?(&:nil?)
          representative = candidate.fetch(:state_loop) ? 0 : :new
          rep_node = if candidate.fetch(:state_loop)
                       nil
                     else
                       { point: candidate.fetch(:point), radius: candidate.fetch(:radius) }.freeze
                     end

          # The certificate is an explicit Native attestation, not a Ruby
          # geometric guess. Adapter allows exactly the center-to-members
          # (non-State) and center-to-listed-external-neighbor LOS that Native
          # certified; all other segments need an actual Native callback.
          certified_ids = candidate.fetch(:state_loop) ? [] : candidate.fetch(:original_vertices)
          certified_ids += candidate.fetch(:visible_originals)
          center = candidate.fetch(:state_loop) ? graph[:nodes][0][:point] : candidate.fetch(:point)
          point_lookup = Hash.new { |map, key| map[key] = [] }
          graph.fetch(:nodes).each_with_index do |node, index|
            point_lookup[point_key(node[:point])] << index
          end
          center_key = point_key(center)
          validated_los = lambda do |first, last|
            if point_key(first) == center_key
              matches = point_lookup[point_key(last)]
              if matches.size == 1 && certified_ids.include?(originals[matches.first])
                return true
              end
            end
            los_validator && los_validator.call(first, last) == true
          end
          validated_point = lambda do |p, radius|
            point_key(p) == point_key(candidate[:point]) &&
              radius == candidate[:radius] &&
              (!point_validator || point_validator.call(p, radius) == true)
          end
          ReferenceGraphContraction.contract(
            graph, members: indices,
            representative: representative,
            new_node: rep_node,
            los_validator: validated_los,
            point_validator: validated_point
          )
        end

        def point_key(p)
          [p.x, p.y, p.z]
        end

        def unchanged(source, rejected)
          source.merge(
            collapse_count: 0, loop_count: 0, eligible_count: 0,
            rejected_count: rejected, triangle_count: 0
          ).freeze
        end
      end
    end
  end
end
