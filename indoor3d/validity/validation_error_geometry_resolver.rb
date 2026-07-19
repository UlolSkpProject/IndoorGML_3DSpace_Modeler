# frozen_string_literal: true

require_relative '../utils/transformation'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Builds transient draw geometry for the selected validation report row.
        # Returned points are copied into model/world coordinates. Boolean
        # helper entities exist only inside an operation that is always aborted.
        class ValidationErrorGeometryResolver
          class << self
            def store_overlap_geometry(model:, cell_ids:, geometry:)
              return false unless model && geometry.is_a?(Hash)

              overlap_geometry_cache[overlap_cache_key(model, cell_ids)] = geometry
              true
            end

            def fetch_overlap_geometry(model:, cell_ids:)
              return nil unless model

              overlap_geometry_cache[overlap_cache_key(model, cell_ids)]
            end

            def clear_overlap_geometry(model:)
              return false unless model

              model_id = model.object_id
              overlap_geometry_cache.delete_if { |key, _geometry| key.first == model_id }
              true
            end

            private

            def overlap_geometry_cache
              @overlap_geometry_cache ||= {}
            end

            def overlap_cache_key(model, cell_ids)
              normalized = Array(cell_ids).map do |cell_id|
                cell_id.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
                       .sub(/\Asolid_/, '')
                       .sub(/\Acell_/, '')
              end.reject(&:empty?).sort
              [model.object_id, normalized]
            end
          end

          def initialize(indoor_model:, model: nil, logger: nil)
            @indoor_model = indoor_model
            @model = model || indoor_model&.model
            @logger = logger || (defined?(IndoorCore::Logger) && IndoorCore::Logger)
            @pair_cache = {}
          end

          def resolve(row)
            geometry = empty_geometry
            return geometry unless row.is_a?(Hash)

            cell_ids = row_cell_ids(row)
            face_refs = geometry_face_refs(row).select do |face|
              cell_ids.empty? || cell_ids.include?(face[:cell_id])
            end
            append_face_geometry(geometry, face_refs)
            append_overlap_geometry(geometry, cell_ids, row)
            geometry[:status] = geometry_present?(geometry) ? :ready : :empty
            geometry
          rescue StandardError => e
            log("Validation error overlay resolve failed: #{e.class}: #{e.message}")
            empty_geometry.merge(status: :failed, reason: "#{e.class}: #{e.message}")
          end

          def clear_cache
            @pair_cache.clear
            self.class.clear_overlap_geometry(
              model: @model || Sketchup.active_model
            )
          end

          private

          def empty_geometry
            {
              status: :empty,
              face_triangles: [],
              face_edges: [],
              overlap_triangles: [],
              overlap_edges: [],
              overlap_volumes: [],
              unresolved_faces: [],
              unresolved_pairs: []
            }
          end

          def geometry_present?(geometry)
            !geometry[:face_triangles].empty? || !geometry[:overlap_triangles].empty?
          end

          def geometry_face_refs(row)
            refs = row[:geometry_refs] || row['geometry_refs'] || {}
            Array(refs[:faces] || refs['faces']).filter_map do |face|
              next unless face.is_a?(Hash)

              cell_id = face[:cell_id] || face['cell_id']
              face_index = face[:face_index] || face['face_index']
              next if cell_id.to_s.empty? || face_index.nil?

              { cell_id: normalize_cell_id(cell_id), face_index: face_index.to_i }
            end.uniq
          end

          def row_cell_ids(row)
            Array(row[:cells] || row['cells']).map do |cell_id|
              normalize_cell_id(cell_id)
            end.reject(&:empty?).uniq
          end

          def append_face_geometry(geometry, face_refs)
            Array(face_refs).each do |reference|
              cell_space = cell_space_for(reference[:cell_id])
              group = cell_space&.valid_sketchup_group
              face = group && group.definition.entities.grep(Sketchup::Face)[reference[:face_index]]
              unless face&.valid?
                geometry[:unresolved_faces] << reference
                next
              end

              transform = cell_group_world_transformation(group)
              snapshot = face_geometry(face, transform)
              geometry[:face_triangles].concat(snapshot[:triangles])
              geometry[:face_edges].concat(snapshot[:edges])
            rescue StandardError => e
              geometry[:unresolved_faces] << reference.merge(reason: "#{e.class}: #{e.message}")
            end
          end

          def append_overlap_geometry(geometry, cell_ids, row)
            return unless overlap_error_row?(row)

            Array(cell_ids).combination(2) do |cell_id1, cell_id2|
              cell1 = cell_space_for(cell_id1)
              cell2 = cell_space_for(cell_id2)
              group1 = cell1&.valid_sketchup_group
              group2 = cell2&.valid_sketchup_group
              unless valid_manifold_group?(group1) && valid_manifold_group?(group2)
                geometry[:unresolved_pairs] << [cell_id1, cell_id2]
                next
              end

              pair = [cell_id1, cell_id2]
              intersection = cached_overlap_geometry(pair)
              unless intersection
                unless positive_overlap_recheck?(row, pair)
                  geometry[:unresolved_pairs] << pair
                  next
                end

                cache_key = pair.sort
                intersection = @pair_cache[cache_key] ||=
                  boolean_intersection_geometry(group1, group2)
                if intersection[:status] == :ready
                  self.class.store_overlap_geometry(
                    model: @model || Sketchup.active_model,
                    cell_ids: pair,
                    geometry: intersection
                  )
                end
              end
              unless intersection[:status] == :ready
                geometry[:unresolved_pairs] << pair
                next
              end

              geometry[:overlap_triangles].concat(intersection[:triangles])
              geometry[:overlap_edges].concat(intersection[:edges])
              geometry[:overlap_volumes] << {
                cells: [cell_id1, cell_id2],
                volume_in3: intersection[:volume_in3]
              }
            end
          end

          def overlap_error_row?(row)
            code = (row[:code] || row['code']).to_s[/\d+/].to_i
            code == 701 || code == 704
          end

          def cached_overlap_geometry(pair)
            self.class.fetch_overlap_geometry(
              model: @model || Sketchup.active_model,
              cell_ids: pair
            )
          end

          def positive_overlap_recheck?(row, pair)
            refs = row[:geometry_refs] || row['geometry_refs'] || {}
            recheck = refs[:overlap_recheck] || refs['overlap_recheck']
            return false unless recheck.is_a?(Hash)
            return false if recheck[:tolerated] == true || recheck['tolerated'] == true

            recheck_cells = Array(recheck[:cells] || recheck['cells']).map do |cell|
              normalize_cell_id(cell)
            end
            return false unless recheck_cells.sort == pair.sort

            volume = recheck[:actual_overlap_volume_mm3] ||
              recheck['actual_overlap_volume_mm3']
            !volume.nil? && volume.to_f.positive?
          end

          def face_geometry(face, transform)
            mesh = face.mesh(0)
            triangles = mesh.polygons.flat_map do |polygon|
              points = polygon.map do |index|
                world_point(mesh.point_at(index.abs), transform)
              end
              triangulate_points(points)
            end
            edges = face.loops.flat_map do |loop|
              loop.vertices.each_with_index.flat_map do |vertex, index|
                following = loop.vertices[(index + 1) % loop.vertices.length]
                [
                  world_point(vertex.position, transform),
                  world_point(following.position, transform)
                ]
              end
            end
            { triangles: triangles, edges: edges }
          end

          def boolean_intersection_geometry(group1, group2)
            model = @model || Sketchup.active_model
            return { status: :failed } unless model

            operation_started = false
            copy1 = nil
            copy2 = nil
            result = nil
            begin
              operation_started = model.start_operation(
                'Build IndoorGML validation overlap overlay',
                true
              )
              return { status: :failed } unless operation_started

              copy1 = build_geometry_only_boolean_group(group1)
              copy2 = build_geometry_only_boolean_group(group2)
              return { status: :failed } unless valid_manifold_group?(copy1) &&
                                                    valid_manifold_group?(copy2)
              return { status: :failed } unless copy1.respond_to?(:intersect)

              result = copy1.intersect(copy2)
              return { status: :empty } unless result&.valid?
              return { status: :empty } unless valid_manifold_group?(result)

              volume = result.volume.to_f.abs
              return { status: :empty } unless volume.positive?

              transform = result.transformation
              snapshot = group_geometry(result, transform)
              return { status: :empty } if snapshot[:triangles].empty?

              snapshot.merge(status: :ready, volume_in3: volume)
            rescue StandardError => e
              log("Validation overlap overlay Boolean failed: #{e.class}: #{e.message}")
              { status: :failed, reason: "#{e.class}: #{e.message}" }
            ensure
              aborted = operation_started && model.abort_operation
              unless aborted
                [result, copy1, copy2].compact.each do |entity|
                  entity.erase! if entity.respond_to?(:valid?) && entity.valid?
                rescue StandardError
                  nil
                end
              end
            end
          end

          def group_geometry(group, transform)
            faces = group.definition.entities.grep(Sketchup::Face).select(&:valid?)
            triangles = []
            edge_keys = {}
            edges = []

            faces.each do |face|
              mesh = face.mesh(0)
              mesh.polygons.each do |polygon|
                points = polygon.map do |index|
                  world_point(mesh.point_at(index.abs), transform)
                end
                triangles.concat(triangulate_points(points))
              end
              face.edges.each do |edge|
                points = edge.vertices.map do |vertex|
                  world_point(vertex.position, transform)
                end
                key = points.map { |point| rounded_point_key(point) }.sort
                next if edge_keys[key]

                edge_keys[key] = true
                edges.concat(points)
              end
            end

            { triangles: triangles, edges: edges }
          end

          def triangulate_points(points)
            compact = Array(points)
            return [] if compact.length < 3
            return [compact] if compact.length == 3

            (1...(compact.length - 1)).map do |index|
              [compact[0], compact[index], compact[index + 1]]
            end
          end

          # Builds an untagged, attribute-free Group in model root coordinates.
          # It never references the CellSpace definition, so primal observers
          # cannot interpret the temporary Boolean input as another CellSpace.
          def build_geometry_only_boolean_group(source)
            model = @model || Sketchup.active_model
            return nil unless model&.respond_to?(:entities)

            source_transform = cell_group_world_transformation(source)
            polygon_mesh = Geom::PolygonMesh.new
            point_indices = {}
            polygon_count = 0

            source.definition.entities.grep(Sketchup::Face).each do |face|
              mesh = face.mesh(0)
              mesh.polygons.each do |polygon|
                indices = polygon.filter_map do |source_index|
                  point = world_point(mesh.point_at(source_index.abs), source_transform)
                  key = rounded_point_key(point)
                  point_indices[key] ||= polygon_mesh.add_point(point)
                end
                next if indices.uniq.length < 3

                polygon_mesh.add_polygon(indices)
                polygon_count += 1
              end
            end
            return nil if polygon_count.zero?

            group = model.entities.add_group
            return nil unless group&.valid?

            filled = group.entities.fill_from_mesh(polygon_mesh, true, 0)
            unless filled
              group.erase! if group.valid?
              return nil
            end

            group
          end

          def valid_manifold_group?(group)
            group&.valid? && group.respond_to?(:manifold?) && group.manifold? &&
              group.respond_to?(:volume) && group.volume.to_f.abs.positive?
          rescue StandardError
            false
          end

          def cell_space_for(value)
            target = normalize_cell_id(value)
            Array(@indoor_model&.cell_spaces).find do |cell_space|
              normalize_cell_id(cell_space&.id) == target
            end
          end

          def normalize_cell_id(value)
            value.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
                 .sub(/\Asolid_/, '')
                 .sub(/\Acell_/, '')
          end

          def cell_group_world_transformation(group)
            root_world_transformation * group.transformation
          end

          def root_world_transformation
            Utils::Transformation.root_transformation_in_model(
              @indoor_model&.primal_group
            )
          end

          def world_point(point, transform)
            transformed = point.transform(transform)
            Geom::Point3d.new(transformed.x, transformed.y, transformed.z)
          end

          def rounded_point_key(point)
            [point.x.to_f.round(8), point.y.to_f.round(8), point.z.to_f.round(8)]
          end

          def log(message)
            @logger.puts("[IndoorGML] #{message}") if @logger&.respond_to?(:puts)
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
