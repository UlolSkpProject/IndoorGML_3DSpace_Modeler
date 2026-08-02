# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        # Dev-only bridge to the existing BulkCellSpaceConversionService preflight
        # implementation. It deliberately delegates geometry and target validation
        # to the service instead of copying their rules.
        class CellSpaceConversionPreflightAdapter
          def initialize(service)
            @service = service
          end

          def prepare(job, index)
            source = job[:source]
            unless service_call(:source_valid?, source)
              return [nil, service_call(:conversion_error, source, 'Conversion source is no longer valid')]
            end

            prepared = job.merge(job_id: "cell_space_conversion_#{index}")
                          .merge(source_label: service_call(:safe_group_label, source))
                          .freeze
            [prepared, nil]
          end

          def validate_geometry(job)
            plan, errors = service_call(:validate_plan_geometry, [job])
            [plan.first, errors.first]
          end

          def validate_target(job)
            plan, errors = service_call(:validate_plan_targets, [job])
            [plan.first, errors.first]
          end

          def empty_plan_error
            service_call(:conversion_error, nil, 'No valid solid groups were available for conversion')
          end

          private

          def service_call(method_name, *arguments)
            @service.__send__(method_name, *arguments)
          end
        end
      end
    end
  end
end
