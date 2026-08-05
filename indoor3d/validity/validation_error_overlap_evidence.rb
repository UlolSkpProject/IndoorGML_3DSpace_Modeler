# frozen_string_literal: true

require_relative 'validation_error_geometry_resolver'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Interprets overlap evidence from a validation report row without
        # depending on which validation mode produced that row.
        #
        # Explicit overlap_recheck metadata is authoritative. When metadata is
        # absent, a raw 701 result itself authorizes lazy Boolean intersection
        # geometry for Fix Mode. Other codes, including 704, do not.
        module ValidationErrorOverlapEvidence
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

        resolver_class = ValidationErrorGeometryResolver
        unless resolver_class.ancestors.include?(ValidationErrorOverlapEvidence)
          resolver_class.prepend(ValidationErrorOverlapEvidence)
        end
      end
    end
  end
end
