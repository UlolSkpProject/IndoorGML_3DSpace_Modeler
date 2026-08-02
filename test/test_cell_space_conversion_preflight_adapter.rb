# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/cell_space_conversion_preflight_adapter'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CellSpaceConversionPreflightAdapterTest < Minitest::Test
        Infrastructure = ThreadedProgressInfrastructure

        class FakeSource
          attr_reader :name

          def initialize(name, valid: true)
            @name = name
            @valid = valid
          end

          def valid?
            @valid == true
          end
        end

        class FakeService
          attr_reader :calls

          def initialize
            @calls = []
          end

          private

          def source_valid?(source)
            @calls << [:source_valid, source.name]
            source.valid?
          end

          def safe_group_label(source)
            @calls << [:safe_group_label, source.name]
            "label:#{source.name}"
          end

          def conversion_error(source, reason)
            label = source ? source.name : 'unknown group'
            @calls << [:conversion_error, label, reason]
            { group: label, reason: reason }
          end

          def validate_plan_geometry(plan)
            job = plan.fetch(0)
            @calls << [:validate_plan_geometry, job[:source_label]]
            return [[], [{ group: job[:source_label], reason: 'bad geometry' }]] if job[:geometry_valid] == false

            [plan.freeze, []]
          end

          def validate_plan_targets(plan)
            job = plan.fetch(0)
            @calls << [:validate_plan_targets, job[:source_label]]
            return [[], [{ group: job[:source_label], reason: 'missing target' }]] if job[:target_valid] == false

            [plan.freeze, []]
          end
        end

        def test_prepare_uses_service_validity_and_label_helpers
          source = FakeSource.new('A')
          service = FakeService.new
          adapter = Infrastructure::CellSpaceConversionPreflightAdapter.new(service)

          prepared, error = adapter.prepare({ source: source }, 7)

          assert_nil error
          assert_equal 'cell_space_conversion_7', prepared[:job_id]
          assert_equal 'label:A', prepared[:source_label]
          assert prepared.frozen?
          assert_equal [[:source_valid, 'A'], [:safe_group_label, 'A']], service.calls
        end

        def test_prepare_invalid_source_uses_service_error_formatter
          source = FakeSource.new('B', valid: false)
          service = FakeService.new
          adapter = Infrastructure::CellSpaceConversionPreflightAdapter.new(service)

          prepared, error = adapter.prepare({ source: source }, 0)

          assert_nil prepared
          assert_equal({ group: 'B', reason: 'Conversion source is no longer valid' }, error)
          assert_equal [
            [:source_valid, 'B'],
            [:conversion_error, 'B', 'Conversion source is no longer valid']
          ], service.calls
        end

        def test_geometry_and_target_validation_delegate_to_service
          source = FakeSource.new('C')
          service = FakeService.new
          adapter = Infrastructure::CellSpaceConversionPreflightAdapter.new(service)
          prepared, = adapter.prepare(
            { source: source, geometry_valid: false, target_valid: false },
            0
          )

          geometry_job, geometry_error = adapter.validate_geometry(prepared)
          target_job, target_error = adapter.validate_target(prepared)

          assert_nil geometry_job
          assert_equal({ group: 'label:C', reason: 'bad geometry' }, geometry_error)
          assert_nil target_job
          assert_equal({ group: 'label:C', reason: 'missing target' }, target_error)
          assert_includes service.calls, [:validate_plan_geometry, 'label:C']
          assert_includes service.calls, [:validate_plan_targets, 'label:C']
        end

        def test_empty_plan_error_uses_service_error_formatter
          service = FakeService.new
          adapter = Infrastructure::CellSpaceConversionPreflightAdapter.new(service)

          error = adapter.empty_plan_error

          assert_equal({ group: 'unknown group', reason: 'No valid solid groups were available for conversion' }, error)
          assert_equal [
            [:conversion_error, 'unknown group', 'No valid solid groups were available for conversion']
          ], service.calls
        end
      end
    end
  end
end
