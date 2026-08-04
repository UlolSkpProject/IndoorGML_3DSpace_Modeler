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
                  'fallback_reason' => row.dig('proxy', 'fallback_reason'),
                  'intersection_status' =>
                    row.dig('proxy', 'intersection_status')
                }
              end

              grouped.values.each do |entry|
                entry['request_indices'] =
                  entry['request_indices'].uniq.sort
                entry['codes'] = entry['codes'].uniq.sort
                entry['cohorts'] = entry['cohorts'].uniq.sort
                entry['source_decisions'].sort_by! { |row| row['index'] }
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
