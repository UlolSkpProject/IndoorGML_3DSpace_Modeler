# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_mesh_proxy_benchmark'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityRecheckV3MeshProxy
          class RebuildAnalyzer
            private

            # Preserve both boolean outcomes from ray parity voting.
            #
            # Array#filter_map discards false values, so a region classified as
            # outside by every ray was previously converted into an empty vote
            # set and reported as cap_region_classification_ambiguous. Only nil
            # represents a missing vote; false is a valid outside vote.
            def point_inside_mesh(point, mesh)
              directions = [
                [1.0, 0.371390676, 0.217481243],
                [0.193117843, 1.0, 0.417291033],
                [0.317819431, 0.229143117, 1.0]
              ]
              votes = directions.map do |direction|
                ray_parity(point, direction, mesh)
              end.compact
              return nil if votes.empty?

              true_count = votes.count(true)
              false_count = votes.count(false)
              return true if true_count > false_count
              return false if false_count > true_count

              nil
            end
          end
        end
      end
    end
  end
end
