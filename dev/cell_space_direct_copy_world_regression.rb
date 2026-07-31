# frozen_string_literal: true

# Dev-only end-to-end regression probe for direct PrimalSpaceFeatures batch copy.
#
# Preconditions:
# - SketchUp model is empty except for IndoorGML system groups.
# - IndoorGML extension is fully loaded.
#
# Usage from SketchUp Ruby Console:
#   load 'C:/path/to/IndoorGML_3DSpace_Modeler/dev/cell_space_direct_copy_world_regression.rb'
#   ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceDirectCopyWorldRegression.build!
#   # Inspect the generated nested/shared-definition fixture if desired.
#   ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceDirectCopyWorldRegression.convert_and_verify!
#
# Or run both stages at once:
#   ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceDirectCopyWorldRegression.run!

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceDirectCopyWorldRegression
        FIXTURE_PREFIX = '__CS_DIRECT_COPY_WORLD__'
        EXPECTED_SOLID_COUNT = 8
        STOREY = 'F01'
        CATEGORY_CODE = 'Room'
        TOLERANCE_MM = 0.001

        class << self
          def run!
            return false unless build!

            convert_and_verify!
          end

          def build!
            ensure_extension_ready!
            model = Sketchup.active_model
            ensure_blank_model!(model)

            operation_started = false
            model.start_operation('Build CellSpace Direct Copy World Regression Fixture', true)
            operation_started = true
            @roots = build_fixture(model)
            @jobs = CellSpaceConversionJobBuilder.new(entities: @roots).build
            validate_jobs!(@jobs)
            @baseline = snapshot_jobs(@jobs)
            @existing_cell_keys = current_cell_groups(model).map { |group| entity_key(group) }
            select_roots(model, @roots)
            model.commit_operation
            operation_started = false

            puts
            puts '=' * 100
            puts 'CellSpace Direct Copy World Regression Fixture'
            puts '=' * 100
            puts "Top-level roots : #{@roots.length}"
            puts "Solid jobs      : #{@jobs.length}"
            @baseline.each_with_index do |entry, index|
              origin = entry[:world_origin_mm]
              puts format(
                '%2d. %-44s vertices=%d origin=(%.3f, %.3f, %.3f) mm',
                index + 1,
                entry[:label],
                entry[:points].length,
                origin[0],
                origin[1],
                origin[2]
              )
            end
            puts
            puts 'Fixture 생성 완료. 모델을 확인한 뒤 convert_and_verify!를 실행하세요.'
            puts '=' * 100
            true
          rescue StandardError => e
            model.abort_operation if model && operation_started
            reset_state!
            report_error('build', e)
            false
          end

          def convert_and_verify!
            ensure_extension_ready!
            ensure_built_state!

            model = Sketchup.active_model
            indoor_model = IndoorModel.current
            unless indoor_model.prepare_cell_space_creation_active_context(model)
              raise 'Failed to prepare active context for CellSpace conversion'
            end

            original_active_path = ActivePathController.new(
              model,
              logger: IndoorCore::Logger
            ).snapshot

            jobs = CellSpaceConversionJobBuilder.apply_fallback_storey(@jobs, STOREY)
            started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            @conversion_result = indoor_model.convert_cell_space_jobs_bulk_local_grid_v2(
              jobs,
              fallback_target: [CellSpaceType::GENERAL, CATEGORY_CODE],
              original_active_path: original_active_path,
              operation_name: 'CellSpace Direct Copy World Regression',
              activate_root_context: true
            )
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

            report = verify_current_model
            print_conversion_result(@conversion_result, elapsed)
            print_verification_report(report)
            report[:passed]
          rescue StandardError => e
            report_error('convert/verify', e)
            false
          end

          def verify!
            ensure_extension_ready!
            ensure_snapshot_state!
            report = verify_current_model
            print_verification_report(report)
            report[:passed]
          rescue StandardError => e
            report_error('verify', e)
            false
          end

          def reset_state!
            @roots = nil
            @jobs = nil
            @baseline = nil
            @existing_cell_keys = nil
            @conversion_result = nil
            true
          end

          private

          def build_fixture(model)
            roots = []

            roots << add_box_group(
              model.entities,
              name: fixture_name('ROOT_SOLID'),
              size_mm: [1100.0, 700.0, 900.0],
              transformation: transform(
                translation_mm: [1200.0, 800.0, 300.0],
                rotation_deg: 17.0
              )
            )

            nested_two_parent = model.entities.add_group
            nested_two_parent.name = fixture_name('NESTED_2_PARENT')
            nested_two_parent.transformation = transform(
              translation_mm: [4500.0, -1200.0, 500.0],
              rotation_deg: -23.0
            )
            add_box_group(
              nested_two_parent.entities,
              name: fixture_name('NESTED_2_SOLID'),
              size_mm: [1250.0, 760.0, 980.0],
              transformation: transform(
                translation_mm: [350.0, 420.0, 200.0],
                rotation_deg: 11.0
              )
            )
            roots << nested_two_parent

            nested_three_parent = model.entities.add_group
            nested_three_parent.name = fixture_name('NESTED_3_PARENT')
            nested_three_parent.transformation = transform(
              translation_mm: [-3200.0, 2800.0, 700.0],
              rotation_deg: 31.0
            )
            nested_three_middle = nested_three_parent.entities.add_group
            nested_three_middle.name = fixture_name('NESTED_3_MIDDLE')
            nested_three_middle.transformation = transform(
              translation_mm: [900.0, -350.0, 250.0],
              rotation_deg: -14.0,
              scale: [1.15, 0.85, 1.20]
            )
            add_box_group(
              nested_three_middle.entities,
              name: fixture_name('NESTED_3_SOLID'),
              size_mm: [900.0, 1400.0, 800.0],
              transformation: transform(
                translation_mm: [-220.0, 510.0, 130.0],
                rotation_deg: 8.0
              )
            )
            roots << nested_three_parent

            shared_container_definition = model.definitions.add(
              fixture_name('SHARED_CONTAINER_DEFINITION')
            )
            shared_container_child = add_box_group(
              shared_container_definition.entities,
              name: fixture_name('SHARED_CONTAINER_CHILD_SOLID'),
              size_mm: [1450.0, 850.0, 1050.0],
              transformation: transform(
                translation_mm: [180.0, 240.0, 120.0],
                rotation_deg: 7.0
              )
            )
            shared_container_child.set_attribute(
              FIXTURE_PREFIX,
              'shared_definition_probe',
              true
            )

            shared_wrapper_a = model.entities.add_group
            shared_wrapper_a.name = fixture_name('SHARED_CONTAINER_WRAPPER_A')
            shared_wrapper_a.transformation = transform(
              translation_mm: [7000.0, 3000.0, 200.0],
              rotation_deg: 42.0
            )
            shared_instance_a = shared_wrapper_a.entities.add_instance(
              shared_container_definition,
              transform(
                translation_mm: [500.0, -200.0, 300.0],
                rotation_deg: -9.0
              )
            )
            shared_instance_a.name = fixture_name('SHARED_CONTAINER_INSTANCE_A')
            roots << shared_wrapper_a

            shared_wrapper_b = model.entities.add_group
            shared_wrapper_b.name = fixture_name('SHARED_CONTAINER_WRAPPER_B')
            shared_wrapper_b.transformation = transform(
              translation_mm: [-6500.0, -2800.0, 400.0],
              rotation_deg: -37.0
            )
            shared_instance_b = shared_wrapper_b.entities.add_instance(
              shared_container_definition,
              transform(
                translation_mm: [-350.0, 600.0, 150.0],
                rotation_deg: 18.0,
                scale: [0.90, 0.90, 1.10]
              )
            )
            shared_instance_b.name = fixture_name('SHARED_CONTAINER_INSTANCE_B')
            roots << shared_wrapper_b

            shared_solid_definition = model.definitions.add(
              fixture_name('SHARED_SOLID_DEFINITION')
            )
            add_box_geometry(
              shared_solid_definition.entities,
              [1000.0, 1600.0, 750.0]
            )

            shared_solid_a = model.entities.add_instance(
              shared_solid_definition,
              transform(
                translation_mm: [2500.0, 6500.0, 280.0],
                rotation_deg: 28.0
              )
            )
            shared_solid_a.name = fixture_name('SHARED_SOLID_A')
            roots << shared_solid_a

            shared_solid_b = model.entities.add_instance(
              shared_solid_definition,
              transform(
                translation_mm: [-2500.0, -6500.0, 810.0],
                rotation_deg: -41.0,
                scale: [1.10, 0.90, 1.30]
              )
            )
            shared_solid_b.name = fixture_name('SHARED_SOLID_B')
            roots << shared_solid_b

            unique_component_definition = model.definitions.add(
              fixture_name('ROOT_UNIQUE_COMPONENT_DEFINITION')
            )
            add_box_geometry(
              unique_component_definition.entities,
              [1750.0, 650.0, 1200.0]
            )
            unique_component = model.entities.add_instance(
              unique_component_definition,
              transform(
                translation_mm: [9000.0, -5200.0, 900.0],
                rotation_deg: 63.0,
                scale: [0.95, 1.20, 0.80]
              )
            )
            unique_component.name = fixture_name('ROOT_UNIQUE_COMPONENT')
            roots << unique_component

            roots
          end

          def add_box_group(entities, name:, size_mm:, transformation:)
            group = entities.add_group
            group.name = name
            add_box_geometry(group.entities, size_mm)
            group.transformation = transformation
            group
          end

          def add_box_geometry(entities, size_mm)
            width, depth, height = size_mm.map { |value| value.to_f.mm }
            points = [
              Geom::Point3d.new(0.0, 0.0, 0.0),
              Geom::Point3d.new(width, 0.0, 0.0),
              Geom::Point3d.new(width, depth, 0.0),
              Geom::Point3d.new(0.0, depth, 0.0)
            ]
            face = entities.add_face(points)
            raise 'Fixture box base face creation failed' unless face&.valid?

            face.reverse! if face.normal.z < 0.0
            face.pushpull(height)
            true
          end

          def transform(translation_mm:, rotation_deg:, scale: [1.0, 1.0, 1.0])
            translation = Geom::Transformation.translation(
              translation_mm.map { |value| value.to_f.mm }
            )
            rotation = Geom::Transformation.rotation(
              Geom::Point3d.new(0.0, 0.0, 0.0),
              Geom::Vector3d.new(0.0, 0.0, 1.0),
              rotation_deg.to_f * Math::PI / 180.0
            )
            scaling = Geom::Transformation.scaling(
              Geom::Point3d.new(0.0, 0.0, 0.0),
              scale[0].to_f,
              scale[1].to_f,
              scale[2].to_f
            )
            translation * rotation * scaling
          end

          def snapshot_jobs(jobs)
            jobs.each_with_index.map do |job, index|
              source = job[:source]
              world_transformation = job[:transformation]
              points = world_vertex_points(source, world_transformation)
              raise "Fixture source has no edge vertices: #{source_label(source)}" if points.empty?

              origin = world_transformation.origin
              {
                index: index,
                label: source_label(source),
                source_class: source.class.name.to_s,
                points: points,
                world_origin_mm: [origin.x.to_mm, origin.y.to_mm, origin.z.to_mm]
              }
            end
          end

          def verify_current_model
            model = Sketchup.active_model
            primal_group = find_primal_group(model)
            raise 'IndoorGML_PrimalSpaceFeatures group not found after conversion' unless primal_group&.valid?

            new_cells = current_cell_groups(model).reject do |group|
              Array(@existing_cell_keys).include?(entity_key(group))
            end
            primal_world = Utils::Transformation.root_transformation_in_model(primal_group)
            candidates = new_cells.map do |group|
              {
                group: group,
                label: group.name.to_s,
                points: world_vertex_points(
                  group,
                  primal_world * group.transformation
                ),
                direct_child: Utils::Transformation.direct_child_of_root?(
                  group,
                  primal_group
                )
              }
            end

            matches = greedy_match(@baseline, candidates)
            max_error = matches.map { |match| match[:error] }.compact.max || Float::INFINITY
            all_matched = matches.length == @baseline.length &&
                          matches.all? { |match| match[:candidate] }
            all_within_tolerance = all_matched && matches.all? do |match|
              match[:error] <= tolerance_length
            end
            all_direct_children = candidates.all? { |candidate| candidate[:direct_child] }
            definitions = new_cells.filter_map do |group|
              group.definition if group.respond_to?(:definition) && group.definition&.valid?
            end
            all_unique_definitions = definitions.length == new_cells.length &&
                                     definitions.map(&:object_id).uniq.length == definitions.length
            count_ok = new_cells.length == EXPECTED_SOLID_COUNT

            {
              passed: count_ok &&
                      all_matched &&
                      all_within_tolerance &&
                      all_direct_children &&
                      all_unique_definitions,
              count_ok: count_ok,
              expected_count: EXPECTED_SOLID_COUNT,
              actual_count: new_cells.length,
              all_matched: all_matched,
              all_within_tolerance: all_within_tolerance,
              all_direct_children: all_direct_children,
              all_unique_definitions: all_unique_definitions,
              max_error: max_error,
              matches: matches,
              unmatched_candidates: candidates - matches.filter_map { |match| match[:candidate] }
            }
          end

          def greedy_match(baselines, candidates)
            remaining = candidates.dup
            baselines.map do |baseline|
              candidate, error = remaining.map do |entry|
                [entry, point_cloud_distance(baseline[:points], entry[:points])]
              end.min_by { |_entry, distance| distance }

              remaining.delete(candidate) if candidate
              {
                baseline: baseline,
                candidate: candidate,
                error: error || Float::INFINITY
              }
            end
          end

          def point_cloud_distance(first_points, second_points)
            return Float::INFINITY unless first_points.length == second_points.length
            return Float::INFINITY if first_points.empty?

            [
              directed_point_cloud_distance(first_points, second_points),
              directed_point_cloud_distance(second_points, first_points)
            ].max
          end

          def directed_point_cloud_distance(source_points, target_points)
            source_points.map do |point|
              target_points.map { |candidate| point_distance(point, candidate) }.min
            end.max
          end

          def point_distance(first, second)
            dx = first[0] - second[0]
            dy = first[1] - second[1]
            dz = first[2] - second[2]
            Math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
          end

          def world_vertex_points(entity, world_transformation)
            return [] unless entity&.valid?
            return [] unless entity.respond_to?(:definition) && entity.definition&.valid?

            entity.definition.entities
                  .grep(Sketchup::Edge)
                  .flat_map(&:vertices)
                  .uniq
                  .map do |vertex|
                    point = vertex.position.transform(world_transformation)
                    [point.x.to_f, point.y.to_f, point.z.to_f]
                  end
          end

          def validate_jobs!(jobs)
            unless jobs.length == EXPECTED_SOLID_COUNT
              labels = jobs.map { |job| source_label(job[:source]) }
              raise "Expected #{EXPECTED_SOLID_COUNT} solid jobs, got #{jobs.length}: #{labels.inspect}"
            end

            non_solids = jobs.reject do |job|
              source = job[:source]
              source&.valid? && source.respond_to?(:manifold?) && source.manifold?
            end
            return true if non_solids.empty?

            raise "Fixture produced non-solid jobs: #{non_solids.map { |job| source_label(job[:source]) }.inspect}"
          end

          def print_conversion_result(result, elapsed)
            puts
            puts '=' * 100
            puts 'CellSpace Direct Copy Conversion Result'
            puts '=' * 100
            puts format('Elapsed         : %.3f sec', elapsed)
            puts "Converted       : #{result&.converted_count.to_i}"
            puts "Errors          : #{Array(result&.errors).length}"
            Array(result&.errors).each do |error|
              puts "  - #{error[:group]}: #{error[:reason]}"
            end
            metrics = result&.metrics || {}
            puts format('Create/State    : %.3f sec', metrics[:cell_space_state_duration].to_f)
            puts format('Adjacency       : %.3f sec', metrics[:adjacency_transition_duration].to_f)
            puts '=' * 100
          end

          def print_verification_report(report)
            puts
            puts '=' * 100
            puts 'CellSpace Direct Copy World Coordinate Verification'
            puts '=' * 100
            report[:matches].each_with_index do |match, index|
              baseline = match[:baseline]
              candidate = match[:candidate]
              error_mm = length_to_mm(match[:error])
              passed = candidate && match[:error] <= tolerance_length
              puts format(
                '%s %2d. %-42s -> %-42s max_error=%12.9f mm',
                passed ? 'PASS' : 'FAIL',
                index + 1,
                baseline[:label],
                candidate ? candidate[:label] : '(unmatched)',
                error_mm
              )
            end
            unless report[:unmatched_candidates].empty?
              puts 'Unmatched CellSpaces:'
              report[:unmatched_candidates].each do |candidate|
                puts "  - #{candidate[:label]}"
              end
            end
            puts '-' * 100
            puts "Cell count                 : #{report[:actual_count]}/#{report[:expected_count]} #{report[:count_ok] ? 'PASS' : 'FAIL'}"
            puts "All world clouds matched   : #{report[:all_matched] ? 'PASS' : 'FAIL'}"
            puts "World error <= #{TOLERANCE_MM} mm : #{report[:all_within_tolerance] ? 'PASS' : 'FAIL'}"
            puts "All direct Primal children : #{report[:all_direct_children] ? 'PASS' : 'FAIL'}"
            puts "All definitions unique     : #{report[:all_unique_definitions] ? 'PASS' : 'FAIL'}"
            puts format('Maximum world error        : %.9f mm', length_to_mm(report[:max_error]))
            puts '-' * 100
            puts(report[:passed] ? 'OVERALL: PASS' : 'OVERALL: FAIL')
            puts '=' * 100
            report
          end

          def current_cell_groups(model)
            primal_group = find_primal_group(model)
            return [] unless primal_group&.valid?

            primal_group.entities.grep(Sketchup::Group).select do |group|
              group&.valid? && indoor_feature(group) == 'CellSpace'
            end
          rescue StandardError
            []
          end

          def find_primal_group(model)
            dictionary = IndoorModel::ATTRIBUTE_DICTIONARY_NAME
            model.entities.grep(Sketchup::Group).find do |group|
              feature = group.get_attribute(dictionary, 'feature')
              feature == 'PrimalSpaceFeatures' ||
                group.name.to_s == 'IndoorGML_PrimalSpaceFeatures'
            end
          rescue StandardError
            model.entities.grep(Sketchup::Group).find do |group|
              group.name.to_s == 'IndoorGML_PrimalSpaceFeatures'
            end
          end

          def indoor_feature(entity)
            entity.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'feature')
          rescue StandardError
            nil
          end

          def ensure_blank_model!(model)
            existing_cells = current_cell_groups(model)
            unless existing_cells.empty?
              raise "Blank model required: found #{existing_cells.length} existing CellSpace group(s)"
            end

            blockers = model.entities.to_a.reject { |entity| allowed_system_root_entity?(entity) }
            return true if blockers.empty?

            labels = blockers.first(10).map { |entity| source_label(entity) }
            raise "Blank model required: found non-system root entities #{labels.inspect}"
          end

          def allowed_system_root_entity?(entity)
            return false unless entity.is_a?(Sketchup::Group)

            name = entity.name.to_s
            name.start_with?('IndoorGML_')
          rescue StandardError
            false
          end

          def ensure_extension_ready!
            unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)
              raise 'This script must run inside SketchUp'
            end
            unless defined?(IndoorModel) && IndoorModel.respond_to?(:current)
              raise 'IndoorGML extension is not fully loaded'
            end
            indoor_model = IndoorModel.current
            unless indoor_model.respond_to?(:convert_cell_space_jobs_bulk_local_grid_v2)
              raise 'Local Grid V2 bulk conversion entrypoint is unavailable'
            end
            true
          end

          def ensure_built_state!
            ensure_snapshot_state!
            invalid_sources = @jobs.reject { |job| job[:source]&.valid? }
            unless invalid_sources.empty?
              raise 'Fixture sources are no longer valid. Reopen an empty model and run build! again.'
            end
            true
          end

          def ensure_snapshot_state!
            unless @baseline && @jobs && @roots
              raise 'Fixture is not built. Run build! first.'
            end
            true
          end

          def select_roots(model, roots)
            model.selection.clear
            roots.each { |entity| model.selection.add(entity) if entity&.valid? }
            model.active_view.zoom_extents if model.active_view
          rescue StandardError
            nil
          end

          def source_label(entity)
            return '(nil)' unless entity

            name = entity.respond_to?(:name) ? entity.name.to_s : ''
            entity_id = entity.respond_to?(:entityID) ? entity.entityID : nil
            label = name.empty? ? entity.class.name.to_s : name
            entity_id ? "#{label} [entity #{entity_id}]" : label
          rescue StandardError
            entity.to_s
          end

          def fixture_name(suffix)
            "#{FIXTURE_PREFIX}#{suffix}"
          end

          def entity_key(entity)
            return entity.persistent_id if entity.respond_to?(:persistent_id)
            return entity.entityID if entity.respond_to?(:entityID)

            entity.object_id
          rescue StandardError
            entity.object_id
          end

          def tolerance_length
            TOLERANCE_MM.mm.to_f
          end

          def length_to_mm(value)
            return Float::INFINITY unless value&.finite?

            value.to_f / 1.mm.to_f
          end

          def report_error(stage, error)
            puts
            puts "[CELLSPACE DIRECT COPY WORLD REGRESSION] #{stage} failed: #{error.class}: #{error.message}"
            puts error.backtrace.first(15).join("\n")
          end
        end
      end
    end
  end
end

puts '[CELLSPACE DIRECT COPY WORLD REGRESSION] loaded'
puts '1) ...::CellSpaceDirectCopyWorldRegression.build!'
puts '2) ...::CellSpaceDirectCopyWorldRegression.convert_and_verify!'
puts 'or ...::CellSpaceDirectCopyWorldRegression.run!'
