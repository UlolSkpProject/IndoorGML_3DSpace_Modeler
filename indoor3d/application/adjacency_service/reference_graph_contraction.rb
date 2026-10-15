# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Fail-closed, non-destructive contraction of a connected Reference Graph
      # subgraph. The caller is responsible for candidate selection and must
      # supply actual Native 3D LOS and (for new points) Solid validation.
      #
      # No Native check is inferred from proximity, spheres or Ruby geometry.
      # An existing edge may be reused because the source Reference Graph is
      # already Native LOS-verified. Diagnostic blocked edges are not accepted.
      module ReferenceGraphContraction
        module_function

        # representative: original node index in members, or :new.
        # new_node: { point: Geom::Point3d, radius: Float } for :new only.
        # los_validator: ->(point_a, point_b) { true ONLY on Native clear LOS }
        # point_validator: ->(point, radius) { true ONLY if valid in Solid }
        # Returns { accepted:, reason:, graph:, los_checks:, ... }.
        def contract(source, members:, representative:, new_node: nil,
                     protected_indices: [], los_validator: nil, point_validator: nil)
          nodes = Array(source.fetch(:nodes))
          input_edges = Array(source.fetch(:edges))
          count = nodes.length
          return rejected(source, :empty_graph) if count.zero?
          return rejected(source, :invalid_nodes) unless nodes.all? { |node| valid_node?(node) }
          return rejected(source, :unsupported_edge_annotations) if
            source.key?(:added_edges) || source.key?(:original_edge_count)

          weights = source.key?(:edge_weights) ? Array(source[:edge_weights]) : nil
          metadata = source.key?(:edge_metadata) ? Array(source[:edge_metadata]) : nil
          return rejected(source, :invalid_edge_metadata) if
            (weights && (weights.length != input_edges.length || !weights.all? { |v| valid_number?(v) && v >= 0 })) ||
            (metadata && metadata.length != input_edges.length)

          edges = {}
          adjacency = Array.new(count) { {} }
          input_edges.each_with_index do |edge, index|
            return rejected(source, :invalid_edge) unless edge.is_a?(Array) && edge.size == 2
            a, b = edge
            return rejected(source, :invalid_edge) unless a.is_a?(Integer) && b.is_a?(Integer) &&
              a.between?(0, count - 1) && b.between?(0, count - 1) && a != b
            key = [a, b].sort.freeze
            return rejected(source, :duplicate_edge) if edges.key?(key)
            edges[key] = { weight: weights && weights[index], metadata: metadata && metadata[index] }
            adjacency[a][b] = true
            adjacency[b][a] = true
          end

          selected = Array(members).uniq
          return rejected(source, :invalid_members) if selected.empty? ||
            selected.any? { |i| !i.is_a?(Integer) || !i.between?(0, count - 1) }
          selected.sort!
          return rejected(source, :disconnected_members) unless connected?(selected, adjacency)

          fresh = representative == :new
          return rejected(source, :invalid_representative) unless fresh ||
            (representative.is_a?(Integer) && selected.include?(representative))
          return rejected(source, :invalid_representative) if fresh != !new_node.nil?
          return rejected(source, :state_must_survive) if selected.include?(0) && representative != 0

          protected = Array(protected_indices)
          return rejected(source, :invalid_protection) unless protected.all? { |i| i.is_a?(Integer) && i.between?(0, count - 1) }
          protected_set = protected.to_h { |i| [i, true] }
          protected_set[0] = true
          removed = fresh ? selected : selected.reject { |i| i == representative }
          return rejected(source, :protected_member) if removed.any? { |i| protected_set[i] }
          return rejected(source, :nothing_to_contract) if removed.empty?

          rep_node = fresh ? new_node : nodes[representative]
          return rejected(source, :invalid_representative_node) unless valid_node?(rep_node)
          if fresh
            return rejected(source, :unverified_representative) unless point_validator &&
              point_validator.call(rep_node[:point], rep_node[:radius]) == true
          end
          rep_point = rep_node[:point]
          members_set = selected.to_h { |i| [i, true] }
          boundary = selected.flat_map { |i| adjacency[i].keys }.reject { |i| members_set[i] }.uniq.sort
          existing_rep_edges = fresh ? {} : adjacency[representative]
          checks = 0

          # Losing member paths through an unseen center is not permitted.
          # Existing Native edges are sufficient; all other member paths
          # require an explicit Native LOS success.
          ((fresh ? selected : removed) + boundary).uniq.sort.each do |index|
            next if existing_rep_edges[index]
            return rejected(source, :native_los_unavailable, checks, boundary) unless los_validator
            checks += 1
            return rejected(source, :native_los_blocked, checks, boundary) unless
              los_validator.call(rep_point, nodes[index][:point]) == true
          end

          removed_set = removed.to_h { |i| [i, true] }
          surviving = (0...count).reject { |i| removed_set[i] }
          reindex = surviving.each_with_index.to_h
          rep_result = fresh ? surviving.length : reindex.fetch(representative)
          result_nodes = surviving.map { |i| duplicate_node(nodes[i]) }
          result_nodes << duplicate_node(rep_node) if fresh

          # Store every retained original edge first; only subsequently append
          # Native-validated replacement edges. Never reclassify a blocked edge.
          result_edges = {}
          edges.sort_by { |key, _| key }.each do |(a, b), detail|
            next if removed_set[a] || removed_set[b]
            result_edges[[reindex.fetch(a), reindex.fetch(b)].sort.freeze] = detail
          end
          new_edges = []
          boundary.each do |index|
            key = [rep_result, reindex.fetch(index)].sort.freeze
            next if result_edges.key?(key)
            result_edges[key] = { weight: distance(rep_point, nodes[index][:point]),
                                  metadata: { source: :native_los, replaced_members: selected.freeze }.freeze }
            new_edges << key
          end
          sorted_edges = result_edges.keys.sort
          origins = source.key?(:original_indices) ? Array(source[:original_indices]) : (0...count).to_a
          return rejected(source, :invalid_origins, checks, boundary) unless origins.length == count && origins.first == 0
          result_origins = surviving.map { |i| origins[i] }
          result_origins << nil if fresh
          rep_origin = fresh ? nil : origins[representative]
          history = Array(source[:merged_into]).map(&:dup)
          removed.each { |i| history << [origins[i], rep_origin] unless origins[i].nil? }
          # Transitive resolution is necessary when earlier representatives
          # were themselves absorbed in this or an earlier contraction.
          parent = history.to_h
          return rejected(source, :invalid_merge_history, checks, boundary) if parent.key?(nil)
          history = parent.keys.sort.map do |from|
            target = parent[from]
            seen = { from => true }
            while parent.key?(target)
              return rejected(source, :invalid_merge_history, checks, boundary) if seen[target]
              seen[target] = true
              target = parent[target]
            end
            [from, target].freeze
          end

          graph = source.merge(
            nodes: result_nodes.freeze,
            edges: sorted_edges.map(&:freeze).freeze,
            original_indices: result_origins.freeze,
            merged_into: history.freeze
          )
          graph[:edge_weights] = sorted_edges.map { |key| result_edges[key][:weight] }.freeze if weights
          graph[:edge_metadata] = sorted_edges.map { |key| result_edges[key][:metadata] }.freeze if metadata
          graph[:contraction_history] = (Array(source[:contraction_history]) + [{
            member_indices: selected.freeze,
            removed_indices: removed.freeze,
            representative_index: rep_result,
            representative_original_index: rep_origin,
            boundary_indices: boundary.freeze,
            new_edges: new_edges.sort.map(&:freeze).freeze,
            los_checks: checks
          }.freeze]).freeze
          accepted(graph.freeze, checks, boundary, removed, new_edges)
        end

        def valid_number?(value)
          value.is_a?(Numeric) && value.finite?
        end

        def valid_node?(node)
          return false unless node.is_a?(Hash) && valid_number?(node[:radius]) && node[:radius] >= 0
          point = node[:point]
          point && %i[x y z].all? { |axis| valid_number?(point.public_send(axis)) }
        rescue NoMethodError
          false
        end

        def distance(a, b)
          Math.sqrt((a.x - b.x)**2 + (a.y - b.y)**2 + (a.z - b.z)**2)
        end

        def connected?(members, adjacency)
          membership = members.to_h { |i| [i, true] }
          seen = { members.first => true }
          queue = [members.first]
          head = 0
          while head < queue.length
            index = queue[head]
            head += 1
            adjacency[index].each_key do |neighbor|
              next if seen[neighbor] || !membership[neighbor]
              seen[neighbor] = true
              queue << neighbor
            end
          end
          seen.length == members.length
        end

        def duplicate_node(node)
          copy = node.dup
          point = node[:point]
          # Geom::Point3d#dup returns an origin point in SketchUp 2026.
          # Reconstruct from coordinates so contractions preserve geometry.
          copy[:point] = point.class.new(point.x, point.y, point.z).freeze
          copy.freeze
        end

        def accepted(graph, checks, boundary, removed, new_edges)
          { accepted: true, reason: :ok, graph: graph, los_checks: checks,
            boundary_indices: boundary.freeze, removed_indices: removed.freeze,
            new_edges: new_edges.sort.map(&:freeze).freeze }.freeze
        end

        def rejected(source, reason, checks = 0, boundary = [])
          { accepted: false, reason: reason, graph: source, los_checks: checks,
            boundary_indices: boundary.freeze, removed_indices: [].freeze,
            new_edges: [].freeze }.freeze
        end
      end
    end
  end
end
