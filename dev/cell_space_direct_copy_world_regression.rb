# frozen_string_literal: true

# Group-only end-to-end regression for direct PrimalSpaceFeatures batch copy.
# ComponentInstance input is forbidden.
#
# core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
# root = File.expand_path('..', File.dirname(core_file))
# load File.join(root, 'dev', 'cell_space_direct_copy_world_regression.rb')
# ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceDirectCopyWorldRegression.build!
# ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceDirectCopyWorldRegression.convert_and_verify!

if defined?(ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceDirectCopyWorldRegression)
  ULOL::Indoor3DGmlModeler::IndoorCore.send(:remove_const, :CellSpaceDirectCopyWorldRegression)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceDirectCopyWorldRegression
        PREFIX = '__CS_DIRECT_COPY_WORLD__'
        EXPECTED = 8
        STOREY = 'F01'
        CATEGORY = 'Room'
        TOLERANCE_MM = 0.001

        class << self
          def run!
            build! && convert_and_verify!
          end

          def build!
            ensure_ready!
            model = Sketchup.active_model
            ensure_blank_model!(model)
            started = false
            model.start_operation('Build CellSpace Direct Copy World Regression Fixture', true)
            started = true

            @roots = build_fixture(model)
            assert_group_only!(model)
            @jobs = CellSpaceConversionJobBuilder.new(entities: @roots).build
            validate_jobs!(@jobs)
            @baseline = snapshot_jobs(@jobs)
            @existing_cells = current_cells(model).map { |group| entity_key(group) }
            select_roots(model)

            model.commit_operation
            started = false
            print_fixture
            true
          rescue StandardError => e
            model.abort_operation if model && started
            reset!
            report_error('build', e)
            false
          end

          def convert_and_verify!
            ensure_ready!
            ensure_built!
            model = Sketchup.active_model
            assert_group_only!(model)
            indoor_model = IndoorModel.current
            unless indoor_model.prepare_cell_space_creation_active_context(model)
              raise 'Failed to prepare active context for CellSpace conversion'
            end

            active_path = ActivePathController.new(model, logger: IndoorCore::Logger).snapshot
            jobs = CellSpaceConversionJobBuilder.apply_fallback_storey(@jobs, STOREY)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            @result = indoor_model.convert_cell_space_jobs_bulk_local_grid(
              jobs,
              fallback_target: [CellSpaceType::GENERAL, CATEGORY],
              original_active_path: active_path,
              operation_name: 'CellSpace Direct Copy World Regression',
              activate_root_context: true
            )
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
            report = verify_model
            print_conversion(@result, elapsed)
            print_verification(report)
            report[:passed]
          rescue StandardError => e
            report_error('convert/verify', e)
            false
          end

          def verify!
            ensure_ready!
            ensure_snapshot!
            report = verify_model
            print_verification(report)
            report[:passed]
          rescue StandardError => e
            report_error('verify', e)
            false
          end

          def reset!
            @roots = @jobs = @baseline = @existing_cells = @result = nil
            true
          end

          private

          def build_fixture(model)
            roots = []
            roots << box(model.entities, 'ROOT_A', [1100, 700, 900], tr([1200, 800, 300], 17))
            roots << box(model.entities, 'ROOT_B', [980, 1330, 760], tr([-2600, -1700, 620], -34))

            parent = group(model.entities, 'NESTED_2_PARENT', tr([4500, -1200, 500], -23))
            box(parent.entities, 'NESTED_2_SOLID', [1250, 760, 980], tr([350, 420, 200], 11))
            roots << parent

            parent = group(model.entities, 'NESTED_3_PARENT', tr([-3200, 2800, 700], 31))
            middle = group(parent.entities, 'NESTED_3_MIDDLE', tr([900, -350, 250], -14, [1.15, 0.85, 1.20]))
            box(middle.entities, 'NESTED_3_SOLID', [900, 1400, 800], tr([-220, 510, 130], 8))
            roots << parent

            parent = group(model.entities, 'NESTED_ROTATED_A_PARENT', tr([7000, 3000, 200], 42))
            box(parent.entities, 'NESTED_ROTATED_A_SOLID', [1450, 850, 1050], tr([500, -200, 300], -9))
            roots << parent

            parent = group(model.entities, 'NESTED_ROTATED_B_PARENT', tr([-6500, -2800, 400], -37, [0.90, 0.90, 1.10]))
            box(parent.entities, 'NESTED_ROTATED_B_SOLID', [1380, 930, 1170], tr([-350, 600, 150], 18))
            roots << parent

            roots << box(model.entities, 'ROOT_SCALED_A', [1000, 1600, 750], tr([2500, 6500, 280], 28, [1.10, 0.90, 1.30]))
            roots << box(model.entities, 'ROOT_SCALED_B', [1750, 650, 1200], tr([9000, -5200, 900], 63, [0.95, 1.20, 0.80]))
            roots
          end

          def group(entities, suffix, transformation)
            result = entities.add_group
            raise 'Fixture Group creation failed' unless result&.valid?
            result.name = name(suffix)
            result.transformation = transformation
            result
          end

          def box(entities, suffix, size_mm, transformation)
            result = group(entities, suffix, transformation)
            width, depth, height = size_mm.map { |value| value.to_f.mm }
            face = result.entities.add_face(
              ORIGIN,
              Geom::Point3d.new(width, 0, 0),
              Geom::Point3d.new(width, depth, 0),
              Geom::Point3d.new(0, depth, 0)
            )
            raise 'Fixture box face creation failed' unless face&.valid?
            face.reverse! if face.normal.z < 0
            face.pushpull(height)
            result
          end

          def tr(position_mm, angle_deg, scale = [1.0, 1.0, 1.0])
            Geom::Transformation.translation(position_mm.map { |value| value.to_f.mm }) *
              Geom::Transformation.rotation(ORIGIN, Z_AXIS, angle_deg.to_f * Math::PI / 180.0) *
              Geom::Transformation.scaling(ORIGIN, *scale.map(&:to_f))
          end

          def assert_group_only!(model)
            components = collect_components(model.entities)
            unless components.empty?
              raise "ComponentInstance is forbidden: #{components.first(10).map { |e| label(e) }.inspect}"
            end
            invalid_roots = Array(@roots).reject { |e| e&.valid? && e.is_a?(Sketchup::Group) }
            raise "Fixture roots must all be Group: #{invalid_roots.map { |e| label(e) }.inspect}" unless invalid_roots.empty?
            true
          end

          def collect_components(entities, visited = {})
            entities.to_a.flat_map do |entity|
              found = []
              if defined?(Sketchup::ComponentInstance) && entity.instance_of?(Sketchup::ComponentInstance)
                found << entity
              end
              if entity.is_a?(Sketchup::Group) && entity.valid? && entity.definition&.valid?
                key = entity.definition.object_id
                unless visited[key]
                  visited[key] = true
                  found.concat(collect_components(entity.definition.entities, visited))
                end
              end
              found
            end
          end

          def validate_jobs!(jobs)
            unless jobs.length == EXPECTED
              raise "Expected #{EXPECTED} solid jobs, got #{jobs.length}: #{jobs.map { |j| label(j[:source]) }.inspect}"
            end
            invalid = jobs.reject { |j| j[:source].is_a?(Sketchup::Group) }
            raise "All jobs must be Group: #{invalid.map { |j| label(j[:source]) }.inspect}" unless invalid.empty?
            invalid = jobs.reject { |j| j[:source]&.valid? && j[:source].respond_to?(:manifold?) && j[:source].manifold? }
            raise "Fixture produced non-solid jobs: #{invalid.map { |j| label(j[:source]) }.inspect}" unless invalid.empty?
            true
          end

          def snapshot_jobs(jobs)
            jobs.each_with_index.map do |job, index|
              transformation = job[:transformation]
              points = world_points(job[:source], transformation)
              raise "No vertices: #{label(job[:source])}" if points.empty?
              origin = transformation.origin
              {
                index: index,
                label: label(job[:source]),
                points: points,
                origin_mm: [origin.x.to_mm, origin.y.to_mm, origin.z.to_mm]
              }
            end
          end

          def verify_model
            model = Sketchup.active_model
            primal = find_primal(model)
            raise 'IndoorGML_PrimalSpaceFeatures not found' unless primal&.valid?
            components = collect_components(model.entities)
            cells = current_cells(model).reject { |group| Array(@existing_cells).include?(entity_key(group)) }
            primal_world = Utils::Transformation.root_transformation_in_model(primal)
            candidates = cells.map do |group|
              {
                group: group,
                label: group.name.to_s,
                points: world_points(group, primal_world * group.transformation),
                direct: Utils::Transformation.direct_child_of_root?(group, primal)
              }
            end
            matches = greedy_match(@baseline, candidates)
            matched = matches.filter_map { |match| match[:candidate] }
            all_matched = matches.length == @baseline.length && matches.all? { |match| match[:candidate] }
            within = all_matched && matches.all? { |match| match[:error] <= tolerance }
            direct = candidates.all? { |candidate| candidate[:direct] }
            count_ok = cells.length == EXPECTED
            no_components = components.empty?
            {
              passed: count_ok && all_matched && within && direct && no_components,
              count_ok: count_ok,
              actual_count: cells.length,
              all_matched: all_matched,
              within: within,
              direct: direct,
              no_components: no_components,
              components: components.map { |entity| label(entity) },
              max_error: matches.map { |match| match[:error] }.compact.max || Float::INFINITY,
              matches: matches,
              unmatched: candidates - matched
            }
          end

          def greedy_match(baselines, candidates)
            remaining = candidates.dup
            baselines.map do |baseline|
              candidate, error = remaining.map do |entry|
                [entry, cloud_distance(baseline[:points], entry[:points])]
              end.min_by { |_entry, distance| distance }
              remaining.delete(candidate) if candidate
              { baseline: baseline, candidate: candidate, error: error || Float::INFINITY }
            end
          end

          def cloud_distance(first, second)
            return Float::INFINITY unless first.length == second.length && !first.empty?
            [directed_distance(first, second), directed_distance(second, first)].max
          end

          def directed_distance(first, second)
            first.map do |point|
              second.map do |candidate|
                dx = point[0] - candidate[0]
                dy = point[1] - candidate[1]
                dz = point[2] - candidate[2]
                Math.sqrt(dx * dx + dy * dy + dz * dz)
              end.min
            end.max
          end

          def world_points(entity, transformation)
            return [] unless entity&.valid? && entity.respond_to?(:definition) && entity.definition&.valid?
            entity.definition.entities.grep(Sketchup::Edge).flat_map(&:vertices).uniq.map do |vertex|
              point = vertex.position.transform(transformation)
              [point.x.to_f, point.y.to_f, point.z.to_f]
            end
          end

          def print_fixture
            puts "\n#{'=' * 96}"
            puts 'CellSpace Direct Copy World Regression — GROUP ONLY'
            puts "Roots=#{@roots.length}, Solid jobs=#{@jobs.length}, ComponentInstance=0, Shared definition=not tested"
            @baseline.each_with_index do |entry, index|
              origin = entry[:origin_mm]
              puts format('%2d. %-48s origin=(%.3f, %.3f, %.3f) mm', index + 1, entry[:label], *origin)
            end
            puts "Run convert_and_verify!\n#{'=' * 96}"
          end

          def print_conversion(result, elapsed)
            metrics = result&.metrics || {}
            puts "\n#{'=' * 96}"
            puts format('Converted=%d Errors=%d Elapsed=%.3f sec', result&.converted_count.to_i, Array(result&.errors).length, elapsed)
            Array(result&.errors).each { |error| puts "  - #{error[:group]}: #{error[:reason]}" }
            puts format('Create/State=%.3f sec, Adjacency=%.3f sec', metrics[:cell_space_state_duration].to_f, metrics[:adjacency_transition_duration].to_f)
            puts '=' * 96
          end

          def print_verification(report)
            puts "\n#{'=' * 96}"
            report[:matches].each_with_index do |match, index|
              candidate = match[:candidate]
              pass = candidate && match[:error] <= tolerance
              puts format('%s %2d. %-40s -> %-36s error=%12.9f mm', pass ? 'PASS' : 'FAIL', index + 1, match[:baseline][:label], candidate ? candidate[:label] : '(unmatched)', to_mm(match[:error]))
            end
            report[:unmatched].each { |candidate| puts "Unmatched: #{candidate[:label]}" }
            report[:components].each { |component| puts "Unexpected ComponentInstance: #{component}" }
            puts '-' * 96
            puts "Cell count                 : #{report[:actual_count]}/#{EXPECTED} #{report[:count_ok] ? 'PASS' : 'FAIL'}"
            puts "All world clouds matched   : #{report[:all_matched] ? 'PASS' : 'FAIL'}"
            puts "World error <= #{TOLERANCE_MM} mm : #{report[:within] ? 'PASS' : 'FAIL'}"
            puts "All direct Primal children : #{report[:direct] ? 'PASS' : 'FAIL'}"
            puts "No ComponentInstance       : #{report[:no_components] ? 'PASS' : 'FAIL'}"
            puts format('Maximum world error        : %.9f mm', to_mm(report[:max_error]))
            puts(report[:passed] ? 'OVERALL: PASS' : 'OVERALL: FAIL')
            puts '=' * 96
            report
          end

          def current_cells(model)
            primal = find_primal(model)
            return [] unless primal&.valid?
            primal.entities.grep(Sketchup::Group).select { |group| group&.valid? && feature(group) == 'CellSpace' }
          rescue StandardError
            []
          end

          def find_primal(model)
            dictionary = IndoorModel::ATTRIBUTE_DICTIONARY_NAME
            model.entities.grep(Sketchup::Group).find do |group|
              group.get_attribute(dictionary, 'feature') == 'PrimalSpaceFeatures' ||
                group.name.to_s == 'IndoorGML_PrimalSpaceFeatures'
            end
          rescue StandardError
            nil
          end

          def feature(entity)
            entity.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'feature')
          rescue StandardError
            nil
          end

          def ensure_blank_model!(model)
            cells = current_cells(model)
            raise "Blank model required: found #{cells.length} CellSpace(s)" unless cells.empty?
            blockers = model.entities.to_a.reject do |entity|
              entity.is_a?(Sketchup::Group) && entity.name.to_s.start_with?('IndoorGML_')
            end
            raise "Blank model required: #{blockers.first(10).map { |entity| label(entity) }.inspect}" unless blockers.empty?
            true
          end

          def ensure_ready!
            raise 'This script must run inside SketchUp' unless defined?(Sketchup) && Sketchup.respond_to?(:active_model)
            raise 'IndoorGML extension is not fully loaded' unless defined?(IndoorModel) && IndoorModel.respond_to?(:current)
            unless IndoorModel.current.respond_to?(:convert_cell_space_jobs_bulk_local_grid)
              raise 'Local Grid bulk conversion entrypoint is unavailable'
            end
            true
          end

          def ensure_built!
            ensure_snapshot!
            invalid = @jobs.reject { |job| job[:source]&.valid? }
            raise 'Fixture sources are invalid. Open a blank model and run build! again.' unless invalid.empty?
            true
          end

          def ensure_snapshot!
            raise 'Fixture is not built. Run build! first.' unless @baseline && @jobs && @roots
            true
          end

          def select_roots(model)
            model.selection.clear
            @roots.each { |entity| model.selection.add(entity) if entity&.valid? }
            model.active_view.zoom_extents if model.active_view
          rescue StandardError
            nil
          end

          def label(entity)
            return '(nil)' unless entity
            name_value = entity.respond_to?(:name) ? entity.name.to_s : ''
            id = entity.respond_to?(:entityID) ? entity.entityID : nil
            value = name_value.empty? ? entity.class.name.to_s : name_value
            id ? "#{value} [entity #{id}]" : value
          rescue StandardError
            entity.to_s
          end

          def name(suffix)
            "#{PREFIX}#{suffix}"
          end

          def entity_key(entity)
            return entity.persistent_id if entity.respond_to?(:persistent_id)
            return entity.entityID if entity.respond_to?(:entityID)
            entity.object_id
          rescue StandardError
            entity.object_id
          end

          def tolerance
            TOLERANCE_MM.mm.to_f
          end

          def to_mm(value)
            value&.finite? ? value.to_f / 1.mm.to_f : Float::INFINITY
          end

          def report_error(stage, error)
            puts "\n[CELLSPACE DIRECT COPY WORLD REGRESSION] #{stage} failed: #{error.class}: #{error.message}"
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
