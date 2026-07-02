# frozen_string_literal: true

require 'fileutils'

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
              measure_export_step('write GML file') { File.write(output_path, xml) }
              @export_total_elapsed = monotonic_time - export_started_at
              log_export_timing_summary
              output_path
            end
          end

          def self.output_root
            File.expand_path('../../../../tmp/indoorgml', __dir__)
          end

          def self.default_temp_gml_path
            File.join(output_root, 'temp.gml')
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
            model = Sketchup.active_model
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
              geometry_appender: method(:append_cell_surfaces),
              state_position: method(:state_world_position),
              transition_state1_position: method(:transition_state1_world_position),
              transition_state2_position: method(:transition_state2_world_position),
              measure_step: method(:measure_export_step)
            ).to_xml
          end

          def append_cell_surfaces(shell, cell_space, cell_id)
            group = cell_space.valid_sketchup_group
            return unless group

            world_transform = cell_space_world_transformation(group)
            faces = group.definition.entities.grep(Sketchup::Face)
            faces.each_with_index do |face, index|
              surface_member = shell.add_element('gml:surfaceMember')
              polygon = surface_member.add_element('gml:Polygon')
              polygon.add_attribute('gml:id', "polygon_#{index}_#{cell_id}")
              append_local_crs_attributes(polygon)
              exterior = polygon.add_element('gml:exterior')
              linear_ring = exterior.add_element('gml:LinearRing')
              exterior_ring_points(face, world_transform).each do |point|
                linear_ring.add_element('gml:pos').text = format_export_point(point)
              end
              append_interior_rings(polygon, face, world_transform)
            end
          end

          def exportable_cell_spaces
            export_snapshot.cell_spaces
          end

          def exportable_transitions
            export_snapshot.transitions
          end

          def export_snapshot
            @export_snapshot ||= ExportSnapshot.build(
              indoor_model: @indoor_model,
              cell_spaces: @requested_cell_spaces,
              transitions: @requested_transitions
            )
          end

          def loop_points(loop, transform)
            loop.vertices.map do |vertex|
              vertex.position.transform(transform)
            end
          end

          def exterior_ring_points(face, transform)
            oriented_ring_points(face.outer_loop, transform, transformed_face_normal(face, transform), true)
          end

          def append_interior_rings(polygon, face, transform)
            normal = transformed_face_normal(face, transform)
            face.loops.each do |loop|
              next if loop == face.outer_loop

              interior = polygon.add_element('gml:interior')
              linear_ring = interior.add_element('gml:LinearRing')
              oriented_ring_points(loop, transform, normal, false).each do |point|
                linear_ring.add_element('gml:pos').text = format_export_point(point)
              end
            end
          end

          def oriented_ring_points(loop, transform, normal, align_with_normal)
            ring = loop_points(loop, transform)
            polygon_normal = polygon_normal(ring)
            if normal && polygon_normal
              same_direction = polygon_normal.dot(normal) >= 0.0
              ring.reverse! if same_direction != align_with_normal
            end
            ring << ring.first if ring.first
            ring
          end

          def transformed_face_normal(face, transform)
            normal = face.normal.transform(transform)
            return nil if normal.length <= 0.000001

            normal.normalize!
            normal
          end

          def polygon_normal(points)
            return nil if points.length < 3

            x = 0.0
            y = 0.0
            z = 0.0
            points.each_with_index do |point, index|
              next_point = points[(index + 1) % points.length]
              x += (point.y - next_point.y) * (point.z + next_point.z)
              y += (point.z - next_point.z) * (point.x + next_point.x)
              z += (point.x - next_point.x) * (point.y + next_point.y)
            end
            normal = Geom::Vector3d.new(x, y, z)
            return nil if normal.length <= 0.000001

            normal.normalize!
            normal
          end

          def state_world_position(state)
            group = state&.duality_cell&.valid_sketchup_group
            return Utils::Transformation.entity_world_transformation_under_root(group, @indoor_model.primal_group).origin if group

            state.position
          end

          def transition_state1_world_position(transition)
            transition_point_world_position(transition.state1_point) || state_world_position(transition.state1)
          end

          def transition_state2_world_position(transition)
            transition_point_world_position(transition.state2_point) || state_world_position(transition.state2)
          end

          def cell_space_world_transformation(group)
            Utils::Transformation.entity_world_transformation_under_root(group, @indoor_model.primal_group)
          end

          def transition_point_world_position(point)
            return nil unless point.is_a?(Geom::Point3d)

            Utils::Transformation.root_local_point_to_model(point, @indoor_model.primal_group)
          rescue StandardError
            point
          end

          def format_export_point(point)
            [
              format_number(export_coordinate_value(point.x)),
              format_number(export_coordinate_value(point.y)),
              format_number(export_coordinate_value(point.z))
            ].join(' ')
          end

          def export_coordinate_value(value)
            value.to_f * export_coordinate_unit[:factor]
          end

          def export_coordinate_unit
            @export_coordinate_unit ||= begin
              model = Sketchup.active_model
              unit_key = model&.options&.[]('UnitsOptions')&.[]('LengthUnit').to_i
              EXPORT_COORDINATE_UNITS[unit_key] || EXPORT_COORDINATE_UNITS[0]
            rescue StandardError => e
              IndoorCore::Logger.puts "[IndoorGML] Export unit lookup failed: #{e.class}: #{e.message}"
              EXPORT_COORDINATE_UNITS[0]
            end
          end

          def append_local_crs_attributes(element)
            unit = export_coordinate_unit
            element.add_attribute('srsName', unit[:srs_name])
            element.add_attribute('srsDimension', '3')
            element.add_attribute('axisLabels', 'x y z')
            element.add_attribute('uomLabels', "#{unit[:unit]} #{unit[:unit]} #{unit[:unit]}")
          end

          def log_export_timing_summary
            return if @export_timings.nil? || @export_timings.empty?

            timings = @export_timings.map do |label, elapsed|
              "#{label}=#{format('%.4fs', elapsed)}"
            end
            total = @export_total_elapsed ? " total=#{format('%.4fs', @export_total_elapsed)}" : ''
            IndoorCore::Logger.puts("[IndoorGML] Export timing: #{timings.join(', ')}#{total}")
          end

          def format_number(value)
            numeric = value.to_f
            return '0' if numeric.abs < 1.0e-15

            format('%.17g', numeric)
          end

        end

      end
    end
  end
end
