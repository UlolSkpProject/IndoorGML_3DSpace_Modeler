# frozen_string_literal: true

snapshot_path = File.expand_path(
  'val3dity_recheck_v3_proxy_equivalence_snapshot.rb',
  __dir__
)

unless defined?(
  ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::
    Val3dityRecheckV3ProxyEquivalenceSnapshot
)
  require snapshot_path
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3ProxyEquivalenceSnapshot
          class << self
            private

            # Hash default blocks insert a key when cohorts[index] is read. The
            # original stable-control filter used cohorts[index].empty?, which
            # inserted all otherwise-unselected request indices and caused the
            # final cohorts.keys iteration to capture all 1,318 requests.
            def select_decisions(decisions, comparison, stable_sample_count)
              by_index = decisions.to_h do |row|
                [row.fetch('index').to_i, row]
              end
              cohorts = Hash.new { |hash, key| hash[key] = [] }

              Array(comparison.dig('pair_comparison', 'mismatches')).each do |row|
                index = row.fetch('index').to_i
                initial_status = row.dig('initial', 'status').to_s
                v3_status = row.dig('v3', 'status').to_s
                cohorts[index] << 'decision_mismatch'
                cohorts[index] <<
                  "initial_#{initial_status}_to_v3_#{v3_status}"
              end

              decisions.each do |row|
                index = row.fetch('index').to_i
                status = row['status'].to_s
                proxy = row['proxy'] || {}
                path = proxy['path'].to_s
                cohorts[index] << 'kept_control' if status == 'kept'
                cohorts[index] << 'inconclusive_control' if
                  status == 'inconclusive'
                cohorts[index] << 'fallback_control' if
                  path == 'original_full_recheck_fallback'
                cohorts[index] << 'boundary_repair_applied' if
                  proxy.dig(
                    'v3_analysis',
                    'reconstructed_topology',
                    'boundary_ear_repair_applied'
                  ) == true
              end

              stable_direct = decisions.select do |row|
                index = row.fetch('index').to_i
                row['status'].to_s == 'suppressed' &&
                  row.dig('proxy', 'path').to_s ==
                    'v3_direct_mesh_proxy' &&
                  cohorts.fetch(index, []).empty?
              end

              representative_sample(
                stable_direct,
                [stable_sample_count, 0].max
              ).each do |row|
                cohorts[row.fetch('index').to_i] <<
                  'stable_direct_suppressed_control'
              end

              cohorts.keys.sort.filter_map do |index|
                next if cohorts.fetch(index, []).empty?

                row = by_index[index]
                next unless row

                row.merge('cohorts' => cohorts.fetch(index).uniq.sort)
              end
            end

            # Array#uniq! returns nil when no duplicate was removed. The original
            # implementation chained sort! after uniq!, causing a NoMethodError
            # for already-unique request-index/code/cohort arrays.
            def group_selected_pairs(rows)
              grouped = {}
              rows.each do |row|
                cells = Array(row['cells']).map(&:to_s)
                key = cells.sort.join('|')
                entry = grouped[key] ||= {
                  'cells' => cells,
                  'request_indices' => [],
                  'codes' => [],
                  'cohorts' => [],
                  'source_decisions' => []
                }
                entry['request_indices'] << row.fetch('index').to_i
                entry['codes'] << row['code'].to_i
                entry['cohorts'].concat(Array(row['cohorts']))
                entry['source_decisions'] << {
                  'index' => row.fetch('index').to_i,
                  'code' => row['code'].to_i,
                  'status' => row['status'].to_s,
                  'reason' => row['reason'].to_s,
                  'path' => row.dig('proxy', 'path'),
                  'fallback_reason' => row.dig(
                    'proxy',
                    'fallback_reason'
                  ),
                  'intersection_status' => row.dig(
                    'proxy',
                    'intersection_status'
                  )
                }
              end

              grouped.values.each do |entry|
                entry['request_indices'] =
                  entry['request_indices'].uniq.sort
                entry['codes'] = entry['codes'].uniq.sort
                entry['cohorts'] = entry['cohorts'].uniq.sort
                entry['source_decisions'].sort_by! do |row|
                  row['index']
                end
              end

              grouped.values.sort_by do |entry|
                entry['request_indices'].min
              end
            end
          end
        end
      end
    end
  end
end
