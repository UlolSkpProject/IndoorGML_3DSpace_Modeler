# frozen_string_literal: true

require_relative 'validation_focus_report_mapper'
require_relative 'val3dity_full_intersection_rechecker'
require_relative '../export/gml_exporter'
require_relative '../utils/transformation'
require_relative '../utils/geometry/source_group'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Applies narrowly-scoped, topology-preserving repairs for validation
        # errors whose referenced polygon or CellSpace pair can be resolved
        # back to SketchUp geometry. Every mutation is isolated in its own undo
        # operation and rolled back unless the result remains valid.
        class ValidationAutoFixService
          SUPPORTED_CODES = Val3dityReportSchema::AUTO_FIX_SUPPORTED_CODES
          CELL_TARGET_CODES = [303, 307, 701].freeze
          ORIENTATION_CODES = [303, 307].freeze
          DEFAULT_SNAP_TOLERANCE = 0.001
          AUTO_FIX_PLANARITY_TOLERANCE_MM = 0.01
          AUTO_FIX_OVERLAP_MAX_THICKNESS_MM = 1.5
          OVERLAP_MODIFICATION_PRIORITY = {
            'window' => 0,
            'door' => 1,
            'elevator' => 2,
            'room' => 3,
            'stair' => 4
          }.freeze
          LENGTH_EPSILON = 1.0e-9
          CONGRUENT_EDGE_RELATIVE_TOLERANCE = 0.1

          Result = Struct.new(
            :code,
            :row_id,
            :attempted,
            :fixed,
            :skipped,
            :failed,
            :messages,
            keyword_init: true
          ) do
            def success?
              fixed.to_i.positive? && (skipped.to_i + failed.to_i).zero?
            end

            def summary
              "성공 #{fixed.to_i}건 / 실패 #{skipped.to_i + failed.to_i}건"
            end

            def to_h
              {
                code: code.to_s,
                rowId: row_id.to_s,
                attempted: attempted.to_i,
                fixed: fixed.to_i,
                skipped: skipped.to_i,
                failed: failed.to_i,
                message: summary,
                details: Array(messages)
              }
            end
          end

          def initialize(indoor_model:, report:, logger: nil)
            @indoor_model = indoor_model
            @report = report || {}
            @model = indoor_model&.model
            @logger = logger || (defined?(IndoorCore::Logger) && IndoorCore::Logger)
          end

          def attempt(code:, row_id:)
            normalized_code = normalize_code(code)
            result = build_result(normalized_code, row_id)
            unless SUPPORTED_CODES.include?(normalized_code)
              result.skipped += unsupported_attempt_count(normalized_code, row_id)
              result.messages << "ErrorCode #{normalized_code} 자동 수정은 아직 지원하지 않습니다."
              return result
            end
            rows = selected_rows(normalized_code, row_id)
            if rows.empty?
              result.skipped += 1
              result.messages << '선택한 validation row를 현재 report에서 찾지 못했습니다.'
              return result
            end

            # Resolve Face objects before the first mutation. SketchUp can
            # reorder the definition's face collection while healing geometry.
            targets = rows.map do |row|
              resolved = if CELL_TARGET_CODES.include?(normalized_code)
                           resolved_cell_targets(row)
                         else
                           resolved_face_targets(row)
                         end
              [row, resolved]
            end
            targets.each do |row, resolved_targets|
              if resolved_targets.empty?
                result.skipped += 1
                target_label = normalized_code == 701 ? 'CellSpace 쌍' : 'face'
                result.messages << "대상 #{target_label}을 찾지 못했습니다."
                next
              end

              if normalized_code == 104
                repair_duplicate_edges(row, resolved_targets, result)
              elsif normalized_code == 203
                repair_non_planar_faces(row, resolved_targets, result)
              elsif normalized_code == 701
                repair_cell_overlap(row, resolved_targets, result)
              elsif ORIENTATION_CODES.include?(normalized_code)
                repair_face_orientations(row, resolved_targets, result, normalized_code)
              else
                repair_short_edges(row, resolved_targets, result)
              end
            end
            result
          rescue StandardError => e
            result ||= build_result(normalize_code(code), row_id)
            result.failed += 1
            result.messages << "#{e.class}: #{e.message}"
            log("Validation auto fix failed: #{e.class}: #{e.message}")
            result
          end

          private

          def unsupported_attempt_count(code, row_id)
            return 1 unless row_id.to_s.empty?

            count = Val3dityReportSchema.grouped_error_item_rows(@report || {}).count do |row|
              normalize_code(row[:code]) == code
            end
            [count, 1].max
          end

          def build_result(code, row_id)
            Result.new(
              code: code,
              row_id: row_id,
              attempted: 0,
              fixed: 0,
              skipped: 0,
              failed: 0,
              messages: []
            )
          end

          def normalize_code(value)
            value.to_s[/\d+/].to_i
          end

          def selected_rows(code, row_id)
            rows = ValidationFocusReportMapper.focus_row_states(@report, @indoor_model)
            rows = rows.select { |row| normalize_code(row[:code]) == code }
            return rows if row_id.to_s.empty?

            rows.select { |row| row[:id].to_s == row_id.to_s }
          end

          def resolved_face_targets(row)
            refs = row.dig(:geometry_refs, :faces)
            Array(refs).filter_map do |reference|
              cell_space = cell_space_for(reference[:cell_id])
              group = cell_space&.sketchup_group
              next unless group&.valid? && group.respond_to?(:definition)

              face = group.definition.entities.grep(Sketchup::Face)[reference[:face_index].to_i]
              next unless face&.valid?

              { cell_space: cell_space, group: group, face: face }
            rescue StandardError
              nil
            end.uniq { |target| [entity_key(target[:group]), entity_key(target[:face])] }
          end

          def resolved_cell_targets(row)
            Array(row[:cells]).filter_map do |cell_id|
              cell_space = cell_space_for(cell_id)
              group = cell_space&.sketchup_group
              next unless group&.valid? && group.respond_to?(:definition)

              { cell_space: cell_space, group: group }
            rescue StandardError
              nil
            end.uniq { |target| entity_key(target[:group]) }
          end

          def cell_space_for(value)
            if @indoor_model&.respond_to?(:find_cell_space_by_normalized_id)
              return @indoor_model.find_cell_space_by_normalized_id(value)
            end

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

          def repair_duplicate_edges(row, face_targets, result)
            face_targets.group_by { |target| target[:group] }.each_value do |group_targets|
              group = group_targets.first[:group]
              cell_space = group_targets.first[:cell_space]
              edges = group_targets.flat_map do |target|
                duplicate_edges_for_face(target[:face])
              end.select { |edge| entity_valid?(edge) }
                 .uniq { |edge| entity_key(edge) }

              if edges.empty?
                result.skipped += 1
                result.messages << '한 face에서 반복 사용된 edge가 없습니다.'
                next
              end

              result.attempted += edges.length
              repaired = run_repair_operation('Fix IndoorGML validation error 104', group) do
                group.definition.entities.erase_entities(edges)
                valid_cell_space_group?(group) && edges.none? { |edge| entity_valid?(edge) }
              end
              record_repair_result(result, row, cell_space, group, repaired, edges.length, '중복 edge 제거')
            end
          end

          def repair_face_orientations(row, cell_targets, result, code)
            cell_targets.each do |target|
              group = target[:group]
              cell_space = target[:cell_space]
              changed_count = 0
              result.attempted += 1
              repaired = run_repair_operation(
                "Fix IndoorGML validation error #{code}",
                group
              ) do
                preparation = Utils::Geometry.prepare_cell_space_source_group!(group)
                changed_count = preparation[:reversed_face_count].to_i
                next false unless preparation[:valid] && changed_count.positive?

                verification = Utils::Geometry.prepare_cell_space_source_group!(group)
                verification[:valid] && verification[:reversed_face_count].to_i.zero? &&
                  valid_cell_space_group?(group)
              end

              if repaired
                result.fixed += changed_count
                result.messages << "reversed face #{changed_count}개 방향 수정 완료"
                notify_cell_space_changed(cell_space, group)
              elsif changed_count.zero?
                result.skipped += 1
                result.messages << '뒤집을 reversed face가 없습니다.'
              else
                result.failed += 1
                result.messages << 'face 방향 수정 후 solid 검증 실패로 rollback'
              end
            end
          end

          def repair_non_planar_faces(row, face_targets, result)
            tolerance = planarity_tolerance_inches
            face_targets.group_by { |target| entity_key(target[:group]) }.each_value do |group_targets|
              group = group_targets.first[:group]
              cell_space = group_targets.first[:cell_space]
              transform = cell_group_world_transformation(group)
              plans = group_targets.filter_map do |target|
                plan = non_planar_vertex_plan(target[:face], transform, tolerance)
                unless plan
                  result.skipped += 1
                  result.messages << '인접 face가 모두 사각형인 안전한 vertex를 찾지 못해 수동 수정이 필요합니다.'
                  next
                end
                plan.merge(face: target[:face])
              end
              next if plans.empty?

              moves = compatible_planarity_moves(plans, tolerance)
              unless moves
                result.skipped += plans.length
                result.messages << '동일 vertex의 투영 위치가 충돌해 수동 수정이 필요합니다.'
                next
              end

              result.attempted += plans.length
              source_face_count = group.definition.entities.grep(Sketchup::Face).length
              source_edge_count = group.definition.entities.grep(Sketchup::Edge).length
              repaired = run_repair_operation('Fix IndoorGML validation error 203', group) do
                apply_vertex_projection_moves(group, moves)
                valid_cell_space_group?(group) &&
                  group.definition.entities.grep(Sketchup::Face).length == source_face_count &&
                  group.definition.entities.grep(Sketchup::Edge).length == source_edge_count
              end
              record_repair_result(
                result,
                row,
                cell_space,
                group,
                repaired,
                plans.length,
                '사각형 인접 face vertex 평면 투영'
              )
            end
          end

          def repair_cell_overlap(row, cell_targets, result)
            targets = Array(cell_targets).first(2)
            unless targets.length == 2
              result.skipped += 1
              result.messages << '701 CellSpace 쌍을 찾지 못해 수동 수정이 필요합니다.'
              return
            end

            plan = overlap_projection_plan(targets)
            unless plan
              result.skipped += 1
              result.messages << '1.5 mm 이하에서 안전하게 사영할 경계 face를 찾지 못해 수동 수정이 필요합니다.'
              return
            end

            group = plan[:target][:group]
            cell_space = plan[:target][:cell_space]
            source_face_count = group.definition.entities.grep(Sketchup::Face).length
            source_edge_count = group.definition.entities.grep(Sketchup::Edge).length
            source_volume = group.volume.to_f.abs
            result.attempted += 1
            repaired = run_repair_operation('Fix IndoorGML validation error 701', group) do
              apply_vertex_projection_moves(group, plan[:moves])
              repaired_volume = group.volume.to_f.abs
              valid_cell_space_group?(group) &&
                repaired_volume < source_volume - LENGTH_EPSILON &&
                group.definition.entities.grep(Sketchup::Face).length == source_face_count &&
                group.definition.entities.grep(Sketchup::Edge).length == source_edge_count &&
                overlap_removed_after_projection?(targets)
            end
            record_repair_result(
              result,
              row,
              cell_space,
              group,
              repaired,
              1,
              "#{cell_space.category_code} CellSpace 경계 face 정사영"
            )
          end

          def overlap_projection_plan(targets)
            tolerance = overlap_max_thickness_inches
            analysis = overlap_rechecker(tolerance).pair_analysis(
              report_cell_id(targets[0][:cell_space]),
              report_cell_id(targets[1][:cell_space])
            )
            return nil unless analysis[:status] == :ok

            intersection = Hash(analysis[:intersection])
            return nil unless repairable_overlap_intersection?(intersection)
            return nil unless intersection[:component_count].nil? ||
                              intersection[:component_count].to_i == 1

            modification_targets(targets).filter_map do |target|
              overlap_projection_plan_for_target(
                target,
                targets,
                analysis,
                tolerance
              )
            end.min_by { |plan| [plan[:max_displacement], plan[:target_index]] }
          rescue StandardError => e
            log("701 overlap projection planning failed: #{e.class}: #{e.message}")
            nil
          end

          def repairable_overlap_intersection?(intersection)
            data = Hash(intersection)
            if data[:status] == :reproduced
              return data[:volume].to_f > LENGTH_EPSILON
            end

            data[:status] == :not_reproduced &&
              data[:reason].to_s == 'REPRODUCED_INTERSECTION_WITHIN_OVERLAP_TOLERANCE' &&
              data[:raw_reproduced_volume].to_f > LENGTH_EPSILON
          end

          def modification_targets(targets)
            ranked = Array(targets).each_with_index.filter_map do |target, index|
              rank = overlap_modification_rank(target[:cell_space])
              [target, index, rank] unless rank.nil?
            end
            return [] if ranked.empty?

            best_rank = ranked.map(&:last).min
            ranked.select { |_target, _index, rank| rank == best_rank }
                  .map { |target, index, _rank| target.merge(pair_index: index) }
          end

          def overlap_modification_rank(cell_space)
            OVERLAP_MODIFICATION_PRIORITY[cell_space&.category_code.to_s.downcase]
          end

          def overlap_projection_plan_for_target(target, targets, analysis, tolerance)
            target_index = target[:pair_index].to_i
            candidates = Array(analysis[:adjacency_candidates]).select do |candidate|
              overlap_candidate_within_limit?(candidate, tolerance)
            end
            candidates.filter_map do |candidate|
              overlap_projection_plan_for_candidate(
                target,
                targets,
                candidate,
                tolerance
              )
            end.min_by do |plan|
              [
                plan[:max_displacement],
                plan[:penetration_depth],
                -plan[:overlap_area]
              ]
            end
          end

          def overlap_projection_plan_for_candidate(target, targets, candidate, tolerance)
            target_index = target[:pair_index].to_i
            source_face_index = target_index.zero? ? candidate[:face1_index] : candidate[:face2_index]
            reference_face = target_index.zero? ? candidate[:face2] : candidate[:face1]
            source_face = target[:group].definition.entities.grep(Sketchup::Face)[source_face_index.to_i]
            return nil unless source_face&.valid?
            return nil unless reference_face && Array(reference_face[:points]).length >= 3

            reference_plane = plane_from_normal_and_point(
              reference_face[:normal],
              reference_face[:points].first
            )
            transform = target[:group].transformation
            inverse = transform.inverse
            moves = Array(source_face.vertices).map do |vertex|
              parent_point = vertex.position.transform(transform)
              projected_parent = project_point_to_plane(parent_point, reference_plane)
              projected_local = projected_parent.transform(inverse)
              {
                vertex: vertex,
                target: Geom::Point3d.new(
                  projected_local.x, projected_local.y, projected_local.z
                ),
                displacement: parent_point.distance(projected_parent).to_f
              }
            end
            return nil if moves.empty?
            return nil if moves.any? { |move| move[:displacement] > tolerance + LENGTH_EPSILON }
            return nil unless projected_vertex_neighborhood_planar?(moves)

            {
              target: target,
              target_index: target_index,
              reference: targets[1 - target_index],
              source_face: source_face,
              moves: moves,
              max_displacement: moves.map { |move| move[:displacement] }.max.to_f,
              penetration_depth: candidate[:penetration_depth].to_f,
              overlap_area: candidate[:overlap_area].to_f
            }
          end

          def overlap_candidate_within_limit?(candidate, tolerance)
            depth = candidate[:penetration_depth].to_f
            depth > LENGTH_EPSILON && depth <= tolerance + LENGTH_EPSILON
          end

          def projected_vertex_neighborhood_planar?(moves)
            replacements = Array(moves).each_with_object({}) do |move, result|
              result[entity_key(move[:vertex])] = move[:target]
            end
            affected_faces = Array(moves).flat_map do |move|
              Array(move[:vertex].faces)
            end.select { |face| entity_valid?(face) }
               .uniq { |face| entity_key(face) }
            return false if affected_faces.empty?

            tolerance = planarity_tolerance_inches
            affected_faces.all? do |face|
              points = Array(face.outer_loop.vertices).map do |vertex|
                replacements[entity_key(vertex)] || vertex.position
              end
              fitted_plane_max_distance(points) <= tolerance + LENGTH_EPSILON
            end
          end

          def overlap_removed_after_projection?(targets)
            analysis = overlap_rechecker(Utils::Geometry::VALIDATION_TOLERANCE).pair_analysis(
              report_cell_id(targets[0][:cell_space]),
              report_cell_id(targets[1][:cell_space])
            )
            return false unless analysis[:status] == :ok

            intersection = Hash(analysis[:intersection])
            intersection[:status] == :not_reproduced ||
              intersection[:volume].to_f <= LENGTH_EPSILON
          rescue StandardError
            false
          end

          def overlap_rechecker(tolerance)
            Val3dityFullIntersectionRechecker.new(
              indoor_model: @indoor_model,
              tolerance: tolerance,
              model: @model,
              logger: @logger
            )
          end

          def report_cell_id(cell_space)
            "cell_#{normalize_cell_id(cell_space&.id)}"
          end

          def plane_from_normal_and_point(normal, point)
            nx = normal.x.to_f
            ny = normal.y.to_f
            nz = normal.z.to_f
            d = -((nx * point.x.to_f) + (ny * point.y.to_f) + (nz * point.z.to_f))
            [nx, ny, nz, d]
          end

          def non_planar_vertex_plan(face, transform, tolerance)
            vertices = Array(face&.outer_loop&.vertices)
            return nil if vertices.length < 4

            world_points = vertices.map { |vertex| vertex.position.transform(transform) }
            candidates = vertices.each_index.filter_map do |index|
              reference_points = world_points.each_with_index.filter_map do |point, point_index|
                point unless point_index == index
              end
              plane = fit_plane(reference_points)
              next unless plane

              distance = point_plane_distance(world_points[index], plane)
              next unless distance > tolerance + LENGTH_EPSILON

              {
                vertex: vertices[index],
                projected_world: project_point_to_plane(world_points[index], plane),
                distance: distance
              }
            end.sort_by { |candidate| -candidate[:distance] }

            candidate = candidates.find do |item|
              adjacent_faces_all_quadrilateral?(item[:vertex], face)
            end
            return nil unless candidate

            projected_local = candidate[:projected_world].transform(transform.inverse)
            proposed_points = world_points.each_with_index.map do |point, index|
              same_entity?(vertices[index], candidate[:vertex]) ? candidate[:projected_world] : point
            end
            return nil if fitted_plane_max_distance(proposed_points) > tolerance + LENGTH_EPSILON

            adjacent_faces = Array(candidate[:vertex].faces).reject { |item| same_entity?(item, face) }
            affected_faces = [face, *adjacent_faces].uniq { |item| entity_key(item) }
            return nil unless affected_faces.all? do |affected_face|
              proposed_face_points = Array(affected_face.outer_loop.vertices).map do |vertex|
                same_entity?(vertex, candidate[:vertex]) ? projected_local : vertex.position
              end
              fitted_plane_max_distance(proposed_face_points) <= tolerance + LENGTH_EPSILON
            end

            {
              vertex: candidate[:vertex],
              target: Geom::Point3d.new(projected_local.x, projected_local.y, projected_local.z),
              distance: candidate[:distance]
            }
          rescue StandardError
            nil
          end

          def adjacent_faces_all_quadrilateral?(vertex, target_face)
            adjacent = Array(vertex&.faces).select do |face|
              entity_valid?(face) && !same_entity?(face, target_face)
            end
            !adjacent.empty? && adjacent.all? { |face| Array(face.vertices).length == 4 }
          end

          def compatible_planarity_moves(plans, tolerance)
            Array(plans).each_with_object({}) do |plan, moves|
              key = entity_key(plan[:vertex])
              existing = moves[key]
              if existing && existing[:target].distance(plan[:target]).to_f > tolerance
                return nil
              end
              moves[key] ||= { vertex: plan[:vertex], target: plan[:target] }
            end.values
          end

          def apply_vertex_projection_moves(group, moves)
            vertices = Array(moves).map { |move| move[:vertex] }
            vectors = Array(moves).map do |move|
              move[:vertex].position.vector_to(move[:target])
            end
            group.definition.entities.transform_by_vectors(vertices, vectors)
          end

          def fitted_plane_max_distance(points)
            plane = fit_plane(points)
            return Float::INFINITY unless plane

            Array(points).map { |point| point_plane_distance(point, plane) }.max.to_f
          end

          def fit_plane(points)
            source = Array(points)
            return nil if source.length < 3

            plane = Geom.fit_plane_to_points(source)
            return nil unless plane && plane.length == 4
            return nil if plane[0].to_f**2 + plane[1].to_f**2 + plane[2].to_f**2 <= LENGTH_EPSILON

            plane.map(&:to_f)
          rescue StandardError
            nil
          end

          def point_plane_distance(point, plane)
            a, b, c, d = plane
            denominator = Math.sqrt((a * a) + (b * b) + (c * c))
            return Float::INFINITY if denominator <= LENGTH_EPSILON

            ((a * point.x.to_f) + (b * point.y.to_f) + (c * point.z.to_f) + d).abs / denominator
          end

          def project_point_to_plane(point, plane)
            a, b, c, d = plane
            denominator = (a * a) + (b * b) + (c * c)
            raise 'Invalid best-fit plane.' if denominator <= LENGTH_EPSILON

            scale = ((a * point.x.to_f) + (b * point.y.to_f) + (c * point.z.to_f) + d) / denominator
            Geom::Point3d.new(
              point.x.to_f - (a * scale),
              point.y.to_f - (b * scale),
              point.z.to_f - (c * scale)
            )
          end

          def repair_short_edges(row, face_targets, result)
            threshold = snap_tolerance_inches
            candidates_by_group = face_targets.flat_map do |target|
              short_edge_candidates(target, threshold)
            end.group_by { |candidate| entity_key(candidate[:group]) }

            if candidates_by_group.empty?
              result.skipped += 1
              result.messages << 'snap tolerance 이내의 edge가 없습니다.'
              return
            end

            candidates_by_group.each_value do |group_candidates|
              candidates_by_edge = group_candidates.group_by do |candidate|
                entity_key(candidate[:edge])
              end
              planned = []
              used_vertices = {}
              candidates_by_edge.each_value do |edge_candidates|
                candidate_and_plan = edge_candidates.filter_map do |candidate|
                  plan = collapse_plan_for(candidate, threshold)
                  [candidate, plan] if plan
                end.first
                unless candidate_and_plan
                  result.skipped += 1
                  next
                end

                candidate, plan = candidate_and_plan
                plan_vertices = Array(plan[:moves]).flatten.compact.map { |vertex| entity_key(vertex) }
                # The opposite edge of the same sliver quad produces another
                # plan over the same four vertices. One shell rebuild already
                # collapses both edges, so do not schedule it twice.
                next if plan_vertices.any? { |key| used_vertices[key] }

                plan_vertices.each { |key| used_vertices[key] = true }
                planned << { candidate: candidate, plan: plan }
              end

              if planned.empty?
                result.messages << '안전한 degree-2/triangle/quad collapse 패턴이 아닙니다.'
                next
              end

              candidate = planned.first[:candidate]
              source_edges = planned.map { |entry| entry[:candidate][:edge] }
              combined_plan = {
                kind: planned.map { |entry| entry[:plan][:kind] }.uniq.join('+'),
                moves: planned.flat_map { |entry| Array(entry[:plan][:moves]) }
              }

              result.attempted += planned.length
              repaired = run_repair_operation('Fix IndoorGML validation error 102', candidate[:group]) do
                apply_collapse_plan(candidate[:group], combined_plan)
                source_edges.all? { |edge| collapsed_edge?(edge) } &&
                  valid_cell_space_group?(candidate[:group])
              end
              record_repair_result(
                result,
                row,
                candidate[:cell_space],
                candidate[:group],
                repaired,
                planned.length,
                "#{combined_plan[:kind]} collapse"
              )
            end
          end

          def short_edge_candidates(target, threshold)
            group = target[:group]
            transform = cell_group_world_transformation(group)
            target[:face].loops.flat_map do |loop|
              Array(loop.edges).filter_map do |edge|
                next unless entity_valid?(edge)
                next unless edge_world_length(edge, transform) <= threshold + LENGTH_EPSILON
                next unless edge_world_length(edge, transform) > LENGTH_EPSILON

                target.merge(edge: edge, loop: loop, transform: transform)
              end
            end
          rescue StandardError
            []
          end

          def collapse_plan_for(candidate, threshold)
            edge = candidate[:edge]
            start_vertex = edge.start
            end_vertex = edge.end
            if vertex_degree(start_vertex) == 2 && vertex_degree(end_vertex) == 2
              from, to = collapse_direction(start_vertex, end_vertex)
              return { kind: :degree_2_edge, moves: [[from, to]] }
            end

            loop = candidate[:loop]
            vertices = Array(loop&.vertices)
            edges = Array(loop&.edges)
            edge_index = edges.index { |item| same_entity?(item, edge) }
            return nil unless edge_index

            if vertices.length == 3
              from, to = collapse_direction(start_vertex, end_vertex)
              return { kind: :sliver_triangle, moves: [[from, to]] }
            end

            return nil unless vertices.length == 4 && edges.length == 4

            opposite_edge = edges[(edge_index + 2) % 4]
            return nil unless paired_short_edge?(edge, opposite_edge, candidate[:transform], threshold)

            first = vertices[edge_index]
            second = vertices[(edge_index + 1) % 4]
            third = vertices[(edge_index + 2) % 4]
            fourth = vertices[(edge_index + 3) % 4]
            if vertex_degree(first) <= vertex_degree(second)
              { kind: :sliver_quad, moves: [[first, second], [fourth, third]] }
            else
              { kind: :sliver_quad, moves: [[second, first], [third, fourth]] }
            end
          end

          def collapse_direction(first, second)
            vertex_degree(first) <= vertex_degree(second) ? [first, second] : [second, first]
          end

          def paired_short_edge?(edge, opposite_edge, transform, threshold)
            return false unless entity_valid?(opposite_edge)

            first_length = edge_world_length(edge, transform)
            second_length = edge_world_length(opposite_edge, transform)
            return false if second_length > threshold + LENGTH_EPSILON

            allowed_delta = [first_length, second_length, threshold].max *
              CONGRUENT_EDGE_RELATIVE_TOLERANCE
            (first_length - second_length).abs <= allowed_delta + LENGTH_EPSILON
          end

          def apply_collapse_plan(group, plan)
            rebuild_collapsed_shell(group, Array(plan[:moves]))
          end

          # SketchUp does not weld vertices merely because transform_by_vectors
          # moves them onto the same point. It can leave zero-length edges and
          # non-manifold faces behind. Rebuild the shell with the collapsed
          # vertex mapping instead, omitting only rings that became degenerate.
          def rebuild_collapsed_shell(group, moves)
            entities = group.definition.entities
            source_faces = entities.grep(Sketchup::Face).select { |face| entity_valid?(face) }
            raise 'CellSpace has no faces to rebuild.' if source_faces.empty?
            if source_faces.any? { |face| Array(face.loops).length > 1 }
              raise '102 shell rebuild does not support faces with inner loops.'
            end

            replacements = collapse_vertex_replacements(moves)
            snapshots = source_faces.map do |face|
              collapsed_face_snapshot(face, replacements)
            end
            rebuildable = snapshots.reject { |snapshot| snapshot[:degenerate] }
            raise '102 collapse removed every face in the CellSpace.' if rebuildable.empty?

            source_edges = entities.grep(Sketchup::Edge).select { |edge| entity_valid?(edge) }
            entities.erase_entities(source_edges)
            rebuilt_faces = rebuildable.map do |snapshot|
              face = entities.add_face(snapshot[:points])
              raise 'Failed to rebuild a CellSpace face after 102 collapse.' unless face&.valid?

              face.reverse! if face.normal.dot(snapshot[:normal]).negative?
              face.material = snapshot[:material] if snapshot[:material]
              face.back_material = snapshot[:back_material] if snapshot[:back_material]
              face
            end
            raise '102 collapse rebuilt an unexpected number of faces.' unless
              rebuilt_faces.length == rebuildable.length

            true
          end

          def collapse_vertex_replacements(moves)
            Array(moves).each_with_object({}) do |(from, to), replacements|
              raise 'Invalid 102 collapse vertex mapping.' unless from && to

              point = to.position
              replacements[entity_key(from)] = Geom::Point3d.new(point.x, point.y, point.z)
            end
          end

          def collapsed_face_snapshot(face, replacements)
            points = face.outer_loop.vertices.map do |vertex|
              replacement = replacements[entity_key(vertex)]
              point = replacement || vertex.position
              Geom::Point3d.new(point.x, point.y, point.z)
            end
            points = remove_consecutive_duplicate_points(points)
            {
              points: points,
              normal: Geom::Vector3d.new(face.normal.x, face.normal.y, face.normal.z),
              material: face.material,
              back_material: face.back_material,
              degenerate: degenerate_ring_points?(points)
            }
          end

          def remove_consecutive_duplicate_points(points)
            compact = Array(points).each_with_object([]) do |point, result|
              result << point unless result.last && same_point?(result.last, point)
            end
            compact.pop if compact.length > 1 && same_point?(compact.first, compact.last)
            compact
          end

          def degenerate_ring_points?(points)
            return true if Array(points).length < 3

            origin = points.first
            first_vector = nil
            points.drop(1).each do |point|
              vector = origin.vector_to(point)
              next if vector.length.to_f <= LENGTH_EPSILON

              if first_vector.nil?
                first_vector = vector
                next
              end
              return false if first_vector.cross(vector).length.to_f > LENGTH_EPSILON
            end
            true
          end

          def same_point?(first, second)
            first.distance(second).to_f <= LENGTH_EPSILON
          end

          def run_repair_operation(name, group)
            repaired = false
            with_unlocked(@indoor_model&.primal_group) do
              with_unlocked(group) do
                @indoor_model.with_indoor_model_operation(
                  name,
                  force: true,
                  rollback_if: -> { !repaired }
                ) do
                  @indoor_model.with_runtime_observer_suppression do
                    repaired = yield == true
                  end
                end
              end
            end
            repaired
          rescue StandardError => e
            log("#{name} failed: #{e.class}: #{e.message}")
            false
          end

          def with_unlocked(entity)
            return yield unless entity&.respond_to?(:locked?) && entity.respond_to?(:locked=)

            was_locked = entity.locked?
            entity.locked = false if was_locked
            yield
          ensure
            entity.locked = true if was_locked && entity_valid?(entity)
          end

          def record_repair_result(result, row, cell_space, group, repaired, count, label)
            if repaired
              result.fixed += count
              result.messages << "#{label} 완료"
              notify_cell_space_changed(cell_space, group)
            else
              result.failed += count
              result.messages << "#{label} 후 solid 검증 실패로 rollback"
            end
          end

          def notify_cell_space_changed(_cell_space, group)
            @indoor_model.cell_space_changed(group) if @indoor_model.respond_to?(:cell_space_changed)
          rescue StandardError => e
            log("Validation auto fix topology notification failed: #{e.class}: #{e.message}")
          end

          def duplicate_edges_for_face(face)
            Array(face&.loops).flat_map do |loop|
              counts = Hash.new { |hash, key| hash[key] = [] }
              Array(loop.edges).each { |edge| counts[entity_key(edge)] << edge }
              counts.values.select { |items| items.length > 1 }.map(&:first)
            end
          end

          def valid_cell_space_group?(group)
            group&.valid? && group.respond_to?(:manifold?) && group.manifold? &&
              group.respond_to?(:volume) && group.volume.to_f.abs > LENGTH_EPSILON
          rescue StandardError
            false
          end

          def collapsed_edge?(edge)
            return true unless entity_valid?(edge)

            edge.start.position.distance(edge.end.position).to_f <= LENGTH_EPSILON
          rescue StandardError
            true
          end

          def vertex_degree(vertex)
            Array(vertex&.edges).count { |edge| entity_valid?(edge) }
          end

          def edge_world_length(edge, transform)
            first = edge.start.position.transform(transform)
            second = edge.end.position.transform(transform)
            first.distance(second).to_f
          end

          def snap_tolerance_inches
            raw = @report.dig('parameters', 'snap_tol') ||
              @report.dig(:parameters, :snap_tol) || DEFAULT_SNAP_TOLERANCE
            tolerance = Float(raw)
            tolerance = DEFAULT_SNAP_TOLERANCE unless tolerance.positive?
            factor = GmlExporter.coordinate_unit_for_model(@model)[:factor].to_f
            factor = 1.0 unless factor.positive?
            tolerance / factor
          rescue ArgumentError, TypeError
            DEFAULT_SNAP_TOLERANCE
          end

          def planarity_tolerance_inches
            AUTO_FIX_PLANARITY_TOLERANCE_MM / 25.4
          end

          def overlap_max_thickness_inches
            AUTO_FIX_OVERLAP_MAX_THICKNESS_MM / 25.4
          end

          def cell_group_world_transformation(group)
            root = Utils::Transformation.root_transformation_in_model(@indoor_model&.primal_group)
            root * group.transformation
          end

          def entity_valid?(entity)
            entity && (!entity.respond_to?(:valid?) || entity.valid?)
          rescue StandardError
            false
          end

          def entity_key(entity)
            return [:nil] unless entity
            return [:persistent_id, entity.persistent_id] if entity.respond_to?(:persistent_id)

            [:object_id, entity.object_id]
          rescue StandardError
            [:object_id, entity.object_id]
          end

          def same_entity?(first, second)
            entity_key(first) == entity_key(second)
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
