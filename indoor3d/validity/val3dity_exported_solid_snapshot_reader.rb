# frozen_string_literal: true

require 'rexml/document'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityExportedSolidSnapshotReader
          def initialize(gml_path, numeric_epsilon:)
            @gml_path = gml_path
            @numeric_epsilon = numeric_epsilon
          end

          def read
            @snapshot ||= begin
              content = File.read(@gml_path, encoding: 'UTF-8')
              document = REXML::Document.new(content)
              snapshot = {}
              each_xml_element(document.root) do |element|
                next unless cell_space_element?(element)

                cell_id = xml_attribute(element, 'id')
                next if cell_id.to_s.empty?

                solid = first_descendant(element, 'Solid')
                next unless solid

                snapshot[cell_id] = parse_gml_solid_snapshot(solid, cell_id)
              end
              snapshot
            end
          end

          private

          def cell_space_element?(element)
            %w[CellSpace GeneralSpace TransitionSpace ConnectionSpace AnchorSpace].include?(xml_local_name(element))
          end

          def parse_gml_solid_snapshot(solid, cell_id)
            faces = []
            unsupported = false
            each_xml_element(solid) do |element|
              next unless xml_local_name(element) == 'Polygon'

              face = parse_gml_polygon_face(element)
              if face[:unsupported]
                unsupported = true
              elsif face[:face]
                faces << face[:face]
              end
            end
            { id: cell_id, faces: faces, unsupported: unsupported || faces.empty? }
          end

          def parse_gml_polygon_face(polygon)
            exterior = first_child(polygon, 'exterior')
            ring = first_descendant(exterior, 'LinearRing')
            return { unsupported: true } unless ring

            points = parse_gml_ring_points(ring, polygon)
            points = remove_closing_duplicate(points)
            return { unsupported: true } if points.length < 3

            interiors = children_by_name(polygon, 'interior').filter_map do |interior|
              interior_ring = first_descendant(interior, 'LinearRing')
              next unless interior_ring

              interior_points = remove_closing_duplicate(parse_gml_ring_points(interior_ring, polygon))
              interior_points.length >= 3 ? interior_points : nil
            end

            normal = Utils::Geometry.polygon_normal(points, epsilon: @numeric_epsilon)
            return { unsupported: true } unless normal

            {
              face: {
                points: points,
                interiors: interiors,
                normal: normal,
                triangles: triangulate_points(points)
              },
              unsupported: false
            }
          end

          def parse_gml_ring_points(ring, unit_context)
            positions = []
            each_xml_element(ring) do |element|
              next unless xml_local_name(element) == 'pos'

              values = element.text.to_s.split.map(&:to_f)
              next unless values.length >= 3

              positions << gml_point_to_inches(values[0], values[1], values[2], unit_context)
            end
            positions
          end

          def gml_point_to_inches(x, y, z, element)
            factor = gml_export_unit_factor(element)
            Geom::Point3d.new(x.to_f / factor, y.to_f / factor, z.to_f / factor)
          end

          def gml_export_unit_factor(element)
            unit = nil
            current = element
            while current
              labels = xml_attribute(current, 'uomLabels')
              unit = labels.to_s.split.first unless labels.to_s.empty?
              break if unit

              srs = xml_attribute(current, 'srsName')
              unit = srs.to_s[/local-([A-Za-z]+)/, 1] unless srs.to_s.empty?
              break if unit

              current = current.respond_to?(:parent) ? current.parent : nil
            end
            case unit
            when 'ft' then 1.0 / 12.0
            when 'mm' then 25.4
            when 'cm' then 2.54
            when 'm' then 0.0254
            else 1.0
            end
          end

          def triangulate_points(points)
            (1...(points.length - 1)).map { |index| [points.first, points[index], points[index + 1]] }
          end

          def remove_closing_duplicate(points)
            return points if points.length < 2

            first = points.first
            last = points.last
            first.distance(last) <= @numeric_epsilon ? points[0...-1] : points
          end

          def each_xml_element(element, &block)
            return unless element

            yield element
            element.elements.each { |child| each_xml_element(child, &block) }
          end

          def first_descendant(element, local_name)
            return nil unless element

            element.elements.each do |child|
              return child if xml_local_name(child) == local_name

              found = first_descendant(child, local_name)
              return found if found
            end
            nil
          end

          def first_child(element, local_name)
            return nil unless element

            element.elements.each do |child|
              return child if xml_local_name(child) == local_name
            end
            nil
          end

          def children_by_name(element, local_name)
            return [] unless element

            children = []
            element.elements.each do |child|
              children << child if xml_local_name(child) == local_name
            end
            children
          end

          def xml_local_name(element)
            element&.name.to_s.split(':').last
          end

          def xml_attribute(element, local_name)
            return nil unless element&.respond_to?(:attributes)

            element.attributes.each_attribute do |attribute|
              name = attribute.name.to_s
              expanded_name = attribute.respond_to?(:expanded_name) ? attribute.expanded_name.to_s : name
              return attribute.value if name == local_name || name.split(':').last == local_name ||
                                        expanded_name == local_name || expanded_name.split(':').last == local_name
            end
            nil
          end
        end
      end
    end
  end
end
