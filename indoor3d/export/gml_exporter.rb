# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

require_relative 'atomic_file_writer'
require_relative 'export_snapshot'
require_relative 'gml_writer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class GmlExporter
          # SketchUp stores geometric coordinates internally in inches.
          EXPORT_COORDINATE_UNITS = {
            0 => { unit: 'in', factor: 1.0, srs_name: 'urn:ulol:def:crs:local-in' },
            1 => { unit: 'ft', factor: 1.0 / 12.0, srs_name: 'urn:ulol:def:crs:local-ft' },
            2 => { unit: 'mm', factor: 25.4, srs_name: 'urn:ulol:def:crs:local-mm' },
            3 => { unit: 'cm', factor: 2.54, srs_name: 'urn:ulol:def:crs:local-cm' },
            4 => { unit: 'm', factor: 0.0254, srs_name: 'urn:ulol:def:crs:local-m' }
          }.freeze
          def initialize(indoor_model, refresh_runtime_data: true, cell_spaces: nil, transitions: nil)
            @indoor_model = indoor_model
            @refresh_runtime_data = refresh_runtime_data
            @requested_cell_spaces = cell_spaces
            @requested_transitions = transitions
          end

          def export(output_path: self.class.default_temp_gml_path)
            with_root_model_coordinates do
              export_started_at = monotonic_time
              reset_export_cache
              measure_export_step('refresh runtime data') { @indoor_model.refresh_runtime_data } if @refresh_runtime_data
              validate_exportable_content!
              output_path = File.expand_path(output_path)
              FileUtils.mkdir_p(File.dirname(output_path))
              xml = measure_export_step('build XML document') { document }
              measure_export_step('write GML file') { AtomicFileWriter.write(output_path, xml) }
              @export_total_elapsed = monotonic_time - export_started_at
              log_export_timing_summary
              output_path
            end
          end

          def self.output_root
            File.join(Dir.tmpdir, 'ulol', 'indoorgml')
          end

          def self.default_temp_gml_path
            File.join(output_root, "temp-#{$$}.gml")
          end

          private

          def reset_export_cache
            @export_snapshot = nil
            @export_coordinate_unit = nil
            @export_timings = []
            @export_total_elapsed = nil
          end

          def validate_exportable_content!
            if exportable_cell_spaces.empty?
              raise 'No exportable CellSpace found. Create at least one valid CellSpace before exporting IndoorGML.'
            end

            exportable_cell_spaces.each do |cell_space|
              NavigationSemanticResolver.resolve(cell_space) if GmlWriter.cell_space_tag(cell_space).start_with?('navi:')
            end
          end

          def measure_export_step(label)
            started_at = monotonic_time
            yield
          ensure
            @export_timings << [label, monotonic_time - started_at] if @export_timings
          end

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end

          def with_root_model_coordinates
            model = export_model
            return yield unless model

            active_path = ActivePathController.new(model)
            previous_active_path = active_path.snapshot
            with_active_path_enforcement_suspended do
              active_path.close_to_root
              yield
            ensure
              active_path.restore(previous_active_path, close_when_nil: true)
            end
          end

          def with_active_path_enforcement_suspended
            if @indoor_model.respond_to?(:with_active_path_enforcement_suspended)
              @indoor_model.with_active_path_enforcement_suspended { yield }
            else
              yield
            end
          end

          def document
            GmlWriter.new(
              snapshot: export_snapshot,
              coordinate_unit: export_coordinate_unit,
              measure_step: method(:measure_export_step)
            ).to_xml
          end

          def exportable_cell_spaces
            export_snapshot.cell_spaces
          end

          def export_snapshot
            @export_snapshot ||= ExportSnapshot.build(
              indoor_model: @indoor_model,
              cell_spaces: @requested_cell_spaces,
              transitions: @requested_transitions
            )
          end

          def export_coordinate_unit
            @export_coordinate_unit ||= begin
              model = export_model
              unit_key = model&.options&.[]('UnitsOptions')&.[]('LengthUnit').to_i
              EXPORT_COORDINATE_UNITS[unit_key] || EXPORT_COORDINATE_UNITS[0]
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Export unit lookup failed: #{e.class}: #{e.message}"
              EXPORT_COORDINATE_UNITS[0]
            end
          end

          def log_export_timing_summary
            return if @export_timings.nil? || @export_timings.empty?

            timings = @export_timings.map do |label, elapsed|
              "#{label}=#{format('%.4fs', elapsed)}"
            end
            total = @export_total_elapsed ? " total=#{format('%.4fs', @export_total_elapsed)}" : ''
            IndoorCore::Logger.puts("[IndoorGML] Export timing: #{timings.join(', ')}#{total}")
          end

          def export_model
            @indoor_model&.model || Sketchup.active_model
          end

        end

      end
    end
  end
end
