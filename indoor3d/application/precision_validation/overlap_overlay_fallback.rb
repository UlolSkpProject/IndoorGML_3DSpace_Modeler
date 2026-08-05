# frozen_string_literal: true

require_relative '../../validity/validation_error_geometry_resolver'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        # Precision validation intentionally skips the extension overlap recheck.
        # A raw val3dity 701 row is therefore the authoritative signal that the
        # selected CellSpace pair should lazily build transient Boolean overlap
        # geometry for Fix Mode. Explicit recheck metadata remains authoritative
        # whenever it exists, preserving tolerated and non-positive decisions.
        module OverlapOverlayFallbackPatch
          private

          def positive_overlap_recheck?(row, pair)
            refs = row[:geometry_refs] || row['geometry_refs'] || {}
            recheck = refs[:overlap_recheck] || refs['overlap_recheck']
            return super if recheck.is_a?(Hash)

            validation_error_code(row) == 701
          end

          def validation_error_code(row)
            (row[:code] || row['code']).to_s[/\d+/].to_i
          end
        end

        def self.install_overlap_overlay_fallback!
          resolver_class = IndoorGmlConverter::ValidationErrorGeometryResolver
          unless resolver_class.ancestors.include?(OverlapOverlayFallbackPatch)
            resolver_class.prepend(OverlapOverlayFallbackPatch)
          end
          true
        end
      end

      PrecisionValidation.install_overlap_overlay_fallback!
    end
  end
end
