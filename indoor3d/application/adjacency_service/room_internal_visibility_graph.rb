# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Construct a runtime-only graph by connecting disconnected components
      # of the OPTIMIZED Room graph, preserving every existing node and edge.
      #
      # Two-tier Kruskal:
      #  1. Native LOS-clear candidate edges, ascending Euclidean distance
      #  2. Native LOS-blocked candidates, ascending Euclidean distance
      #
      # All original OPTIMIZED edges remain untouched. New edges are explicitly
      # tagged as :clear or :blocked; blocked edges may cross Room geometry and
      # MUST NOT be treated as navigable/exportable IndoorGML connections.
      # This is a diagnostic graph only.
      module RoomInternalVisibilityGraph
        # Preserve exhaustive Kruskal behavior for small Room graphs.
        # Floor-triangle seeds may legitimately create thousands of nodes.
        MAX_EXHAUSTIVE_NODES = 192
        MAX_NODES = 4097 # 4096 floor triangles + the fixed State
        MAX_PAIRS_PER_BATCH = 2048
        LARGE_GRAPH_NEIGHBOR_COUNTS = [4, 16, 64, 256].freeze

        module_function

        def build(optimized, los_batch:)
          nodes = Array(optimized.fetch(:nodes))
          unless nodes.length.between?(1, MAX_NODES)
            raise ArgumentError,
                  "Room internal graph requires 1..#{MAX_NODES} nodes; got #{nodes.length}"
          end

          originals = Array(optimized.fetch(:original_indices))
          unless originals.length == nodes.length && originals.first == 0
            raise ArgumentError, 'Room internal graph must have State at node 0'
          end
          raise ArgumentError, 'Native LOS callback required' unless los_batch.respond_to?(:call)

          points = nodes.map do |node|
            point = node.fetch(:point)
            unless [point.x, point.y, point.z].all?(&:finite?)
              raise ArgumentError, 'Room internal graph has non-finite node position'
            end
            point
          end

          original_edges = Array(optimized.fetch(:edges))
          union = UnionFind.new(nodes.length)
          existing = {}
          original_edges.each do |edge|
            unless edge.is_a?(Array) && edge.size == 2 &&
                   edge.all? { |index| index.is_a?(Integer) && index >= 0 && index < nodes.length } &&
                   edge[0] < edge[1] && !existing[edge]
              raise ArgumentError, 'OPTIMIZED graph has an invalid or duplicate edge'
            end
            existing[edge] = true
            union.join(edge[0], edge[1])
          end

          component_count_before = union.components
          original_weights = original_edges.map do |a, b|
            distance(points[a], points[b])
          end
          if union.components == 1
            return snapshot(nodes, original_edges, original_weights, originals,
                            [], component_count_before, union.components, 0)
          end

          # Dense all-pairs allocation is deliberately preserved only for
          # small graphs. A large Floor-triangle graph uses bounded nearest
          # intercomponent searches and the same 3D Native LOS/blocked tags.
          if nodes.size > MAX_EXHAUSTIVE_NODES
            return build_large_graph(
              nodes, original_edges, original_weights, originals,
              points, union, los_batch
            )
          end

          # Only across ORIGINAL distinct components. Geometry is queried once
          # per candidate in ascending distance, with bounded native batches.
          candidates = []
          nodes.size.times do |a|
            ((a + 1)...nodes.size).each do |b|
              next if union.same?(a, b)

              candidates << [distance(points[a], points[b]), a, b]
            end
          end
          candidates.sort_by! { |dist, a, b| [dist, a, b] }

          clean_additions = []
          blocked_candidates = []
          checked_pairs = 0

          candidates.each_slice(MAX_PAIRS_PER_BATCH) do |batch|
            checked = los_batch.call(batch.map { |_dist, a, b| [points[a], points[b]] })
            unless checked.is_a?(Array) && checked.length == batch.length &&
                   checked.all? { |result| result == true || result == false }
              raise ArgumentError, 'Native LOS batch returned invalid results'
            end
            checked_pairs += batch.length

            batch.each_with_index do |(dist, a, b), index|
              if checked[index]
                next unless union.join(a, b)

                clean_additions << addition(a, b, dist, :clear)
              else
                blocked_candidates << [dist, a, b]
              end
            end

            # The clean tier already spans every initial component.
            break if union.components == 1
          end

          blocked_additions = []
          if union.components > 1
            # These candidates have already been proven NOT LOS-clear.
            # Their use is explicitly second priority, never a hidden
            # fallback caused by a failed or unavailable Native API.
            blocked_candidates.each do |dist, a, b|
              next unless union.join(a, b)

              blocked_additions << addition(a, b, dist, :blocked)
              break if union.components == 1
            end
          end

          additions = clean_additions + blocked_additions
          final_edges = (original_edges.map(&:dup) + additions.map { |r| r[:edge] }).map(&:freeze).freeze
          final_weights = (original_weights + additions.map { |r| r[:length] }).freeze
          snapshot(
            nodes, final_edges, final_weights, originals, additions,
            component_count_before, union.components, checked_pairs
          )
        end

        # Scalable high-node-count experimental path. The original <=192
        # algorithm above remains untouched. This search never allocates an
        # O(N^2) list; every new connection still passes Native 3D LOS.
        # A LOS-blocked fallback remains diagnostic only, not navigable.
        def build_large_graph(nodes, original_edges, original_weights,
                              originals, points, union, los_batch)
          before = union.components
          checked = {}
          clear_additions = []
          blocked_additions = []
          blocked_pool = []
          attempts = 0

          LARGE_GRAPH_NEIGHBOR_COUNTS.each do |nearest|
            break if union.components == 1

            candidates = sparse_nearest_external_pairs(points, union, nearest)
            candidates.reject! { |record| checked.key?([record[1], record[2]]) }
            candidates.sort_by! { |distance_squared, a, b| [distance_squared, a, b] }

            candidates.each_slice(MAX_PAIRS_PER_BATCH) do |batch|
              results = los_batch.call(
                batch.map { |_dist, a, b| [points[a], points[b]] }
              )
              unless results.is_a?(Array) && results.length == batch.length &&
                     results.all? { |valid| valid == true || valid == false }
                raise ArgumentError, 'Native LOS batch returned invalid results'
              end

              attempts += batch.length
              batch.each_with_index do |(dist_sq, a, b), i|
                checked[[a, b]] = true
                if results[i]
                  next unless union.join(a, b)

                  clear_additions << addition(a, b, Math.sqrt(dist_sq), :clear)
                else
                  blocked_pool << [dist_sq, a, b]
                end
              end
              break if union.components == 1
            end
          end

          # Never disguise a blocked route as navigable. This fallback is
          # identical in classification to the exhaustive implementation.
          if union.components > 1
            blocked_pool.sort_by! { |dist_sq, a, b| [dist_sq, a, b] }
            blocked_pool.each do |dist_sq, a, b|
              next unless union.join(a, b)

              blocked_additions << addition(a, b, Math.sqrt(dist_sq), :blocked)
              break if union.components == 1
            end
          end

          # The bounded neighbor search can leave separate islands if
          # every nearby cross-component pair is blocked. Complete the
          # diagnostic graph through geometry-checked component bridges,
          # explicitly marking blocked links instead of inventing clear LOS.
          while union.components > 1
            roots = (0...points.length).map { |i| union.find(i) }
            closest = {}
            points.each_with_index do |a, i|
              ((i + 1)...points.length).each do |j|
                next if roots[i] == roots[j]

                b = points[j]
                dx = a.x - b.x
                dy = a.y - b.y
                dz = a.z - b.z
                dist_sq = dx * dx + dy * dy + dz * dz
                root = roots[i]
                other = roots[j]
                [[root, other], [other, root]].each do |first, second|
                  prior = closest[first]
                  record = [dist_sq, i, j]
                  closest[first] = record if prior.nil? ||
                    (record <=> prior) < 0
                end
              end
            end
            pair_records = closest.values.uniq.sort_by { |d, a, b| [d, a, b] }
            break if pair_records.empty?
            segments = pair_records.map { |_d, a, b| [points[a], points[b]] }
            results = []
            segments.each_slice(MAX_PAIRS_PER_BATCH) do |batch|
              response = los_batch.call(batch)
              unless response.is_a?(Array) && response.length == batch.length &&
                     response.all? { |value| value == true || value == false }
                raise ArgumentError, 'Native LOS batch returned invalid results'
              end
              results.concat(response)
            end
            attempts += pair_records.length
            pair_records.each_with_index do |(dist_sq, a, b), index|
              next unless union.join(a, b)

              kind = results[index] ? :clear : :blocked
              record = addition(a, b, Math.sqrt(dist_sq), kind)
              kind == :clear ? clear_additions << record : blocked_additions << record
            end
          end

          additions = clear_additions + blocked_additions
          edges = (original_edges.map(&:dup) + additions.map { |item| item[:edge] }).map(&:freeze).freeze
          weights = (original_weights + additions.map { |item| item[:length] }).freeze
          snapshot(nodes, edges, weights, originals, additions,
                   before, union.components, attempts)
        end

        def sparse_nearest_external_pairs(points, union, count)
          # Per-source K-nearest disjoint-component pairs; sort is
          # deterministic, and memory is O(K*N) rather than O(N^2).
          roots = (0...points.length).map { |i| union.find(i) }
          unique = {}
          points.each_with_index do |a, i|
            best = []
            points.each_with_index do |b, j|
              next if i == j || roots[i] == roots[j]

              dx = a.x - b.x
              dy = a.y - b.y
              dz = a.z - b.z
              dist_sq = dx * dx + dy * dy + dz * dz
              next if best.size >= count && dist_sq > best[-1][0]

              first, last = i < j ? [i, j] : [j, i]
              candidate = [dist_sq, first, last]
              at = best.bsearch_index { |item| (item <=> candidate) >= 0 } || best.size
              best.insert(at, candidate)
              best.pop if best.size > count
            end
            best.each { |record| unique[[record[1], record[2]]] = record }
          end
          unique.values
        end

        def distance(a, b)
          Math.sqrt(
            (a.x - b.x)**2 + (a.y - b.y)**2 + (a.z - b.z)**2
          )
        end

        def addition(a, b, dist, classification)
          {
            edge: [a, b].freeze,
            length: dist,
            classification: classification,
            los_clear: classification == :clear
          }.freeze
        end

        def snapshot(nodes, edges, weights, originals, additions,
                     initial_count, final_count, checked)
          clean = additions.count { |r| r[:classification] == :clear }
          blocked = additions.length - clean
          {
            nodes: nodes.freeze,
            edges: edges.freeze,
            edge_weights: weights.freeze,
            original_indices: originals.freeze,
            original_edge_count: edges.length - additions.length,
            added_edges: additions.freeze,
            clear_added_count: clean,
            blocked_added_count: blocked,
            component_count_before: initial_count,
            component_count_after: final_count,
            checked_pairs: checked,
            source_stage: :optimized
          }.freeze
        end

        # Union-Find with path compression and union-by-size.
        class UnionFind
          attr_reader :components

          def initialize(count)
            @parent = Array.new(count) { |index| index }
            @size = Array.new(count, 1)
            @components = count
          end

          def find(index)
            @parent[index] = find(@parent[index]) unless @parent[index] == index
            @parent[index]
          end

          def same?(a, b)
            find(a) == find(b)
          end

          def join(a, b)
            first = find(a)
            second = find(b)
            return false if first == second

            first, second = second, first if @size[first] < @size[second]
            @parent[second] = first
            @size[first] += @size[second]
            @components -= 1
            true
          end
        end
      end
    end
  end
end
