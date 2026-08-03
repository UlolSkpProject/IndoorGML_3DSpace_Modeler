# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'tmpdir'
require 'time'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Phase 5.5.1 read-only inventory for polygon reconstruction complexity.
      #
      # This probe never calls LocalVertexNormalizer#normalize and never mutates
      # model geometry. It measures the snapped Face-loop sizes that drive the
      # hole-bridge and exact ear-clipping paths, then classifies Faces using a
      # provisional, geometry-independent complexity policy.
      module LvnFaceComplexityInventoryProbe
        TOLERANCE_MM = LocalVertexNormalizer::DEFAULT_TOLERANCE_MM
        MM_PER_INCH = LocalVertexNormalizer::MM_PER_INCH

        # Provisional Phase 5.5 policy. These values are inventory labels only;
        # production behavior is not changed by this probe.
        WEAK_VERTEX_LIMIT = 1_024
        INNER_LOOP_LIMIT = 64
        TOTAL_BOUNDARY_VERTEX_LIMIT = 2_048
        EAR_WORK_LIMIT = 2_000_000
        TOP_FACE_COUNT = 30

        module_function

        def run
          model = Sketchup.active_model
          selection = model.selection.to_a
          targets, skipped = inventory_targets(model, selection)
          raise 'Select one or more top-level manifold solids first' if targets.empty?

          log_path = build_log_path(model)
          FileUtils.mkdir_p(File.dirname(log_path))
          io = File.open(log_path, 'wb')
          io.set_encoding(Encoding::UTF_8)
          io.sync = true

          puts '=' * 112
          puts ' LVN Phase 5.5.1 — Face Complexity Inventory (Read Only)'
          puts '=' * 112
          puts format('log file              : %s', log_path)
          puts format('selected entities     : %d', selection.length)
          puts format('qualifying solids     : %d', targets.length)
          puts format('grid tolerance        : %.6f mm', TOLERANCE_MM)
          puts 'geometry mutations    : none'
          puts 'production LVN calls  : none'
          puts 'provisional action    : complex Face -> triangle-preserving path'
          print_skipped(skipped)
          puts '-' * 112

          write_event(
            io,
            'RUN_BEGIN',
            {
              probe: name,
              selected_entities: selection.length,
              qualifying_solids: targets.length,
              skipped: skipped,
              tolerance_mm: TOLERANCE_MM,
              policy: policy_hash,
              model_path: model.respond_to?(:path) ? model.path.to_s : nil,
              ruby_version: RUBY_VERSION,
              sketchup_version:
                Sketchup.respond_to?(:version) ? Sketchup.version.to_s : nil
            }
          )

          face_records = []
          solid_records = targets.map.with_index do |target, index|
            record = analyze_solid(target, index + 1, targets.length)
            face_records.concat(record.delete(:face_records))
            write_event(io, 'SOLID', record)
            print_solid_progress(record)
            record
          rescue StandardError => error
            failure = target_metadata(target).merge(
              index: index + 1,
              total: targets.length,
              status: 'ERROR',
              error_class: error.class.name,
              error_message: error.message,
              backtrace: Array(error.backtrace).first(12)
            )
            write_event(io, 'SOLID_ERROR', failure, level: 'ERROR')
            warn format(
              '[%d/%d] %s ERROR %s: %s',
              index + 1,
              targets.length,
              target[:label],
              error.class,
              error.message
            )
            failure
          end

          successful_solids = solid_records.select { |record| record[:status] == 'PASS' }
          failed_solids = solid_records.length - successful_solids.length
          complex_faces = face_records.select { |record| record[:complex] }
          complex_solids = successful_solids.count do |record|
            record[:complex_face_count].to_i.positive?
          end
          top_faces = face_records.sort_by { |record| face_sort_key(record) }
                                  .reverse
                                  .first(TOP_FACE_COUNT)
          top_faces.each { |record| write_event(io, 'TOP_FACE', record) }

          summary = {
            result: failed_solids.zero? ? 'PASS' : 'FAIL',
            qualifying_solids: targets.length,
            analyzed_solids: successful_solids.length,
            failed_solids: failed_solids,
            total_faces: face_records.length,
            complex_faces: complex_faces.length,
            complex_solids: complex_solids,
            polygon_faces: face_records.length - complex_faces.length,
            policy: policy_hash,
            face_quantiles: {
              weak_vertices: quantiles(face_records, :weak_vertex_count),
              inner_loops: quantiles(face_records, :inner_loop_count),
              total_boundary_vertices:
                quantiles(face_records, :total_boundary_vertex_count),
              bridge_candidates:
                quantiles(face_records, :bridge_candidate_estimate),
              ear_work: quantiles(face_records, :ear_work_estimate)
            },
            reason_counts: reason_counts(complex_faces),
            top_faces: top_faces
          }
          write_event(
            io,
            'RUN_END',
            summary,
            level: failed_solids.zero? ? 'INFO' : 'ERROR'
          )

          puts '-' * 112
          puts format('analyzed solids       : %d/%d', successful_solids.length, targets.length)
          puts format('total Faces           : %d', face_records.length)
          puts format('complex Faces         : %d', complex_faces.length)
          puts format('complex Solids        : %d', complex_solids)
          puts format('failed Solids         : %d', failed_solids)
          puts format('result                : %s', summary[:result])
          puts format('log file              : %s', log_path)
          puts '=' * 112
          failed_solids.zero?
        rescue StandardError => error
          warn "[LVN FACE COMPLEXITY] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(16).join("\n")
          false
        ensure
          if defined?(io) && io && !io.closed?
            write_event(io, 'LOG_CLOSE')
            io.close
          end
        end

        def inventory_targets(model, selection)
          skipped = Hash.new(0)
          targets = []
          Array(selection).each do |entity|
            unless entity.respond_to?(:valid?) && entity.valid? &&
                   entity.respond_to?(:definition) && entity.definition&.valid?
              skipped[:invalid_entity] += 1
              next
            end
            unless entity.parent == model
              skipped[:not_top_level] += 1
              next
            end
            unless entity.respond_to?(:manifold?) && entity.manifold? == true
              skipped[:not_manifold] += 1
              next
            end

            faces = entity.definition.entities.grep(Sketchup::Face).select(&:valid?)
            if faces.empty?
              skipped[:empty_geometry] += 1
              next
            end

            targets << {
              entity: entity,
              pid: persistent_id(entity),
              label: entity_label(entity),
              face_count: faces.length
            }
          rescue StandardError
            skipped[:inventory_error] += 1
          end
          [targets, skipped]
        end

        def analyze_solid(target, index, total)
          entity = target[:entity]
          faces = entity.definition.entities.grep(Sketchup::Face).select(&:valid?)
          face_records = faces.map.with_index do |face, face_index|
            analyze_face(target, face, face_index)
          end
          complex = face_records.select { |record| record[:complex] }
          {
            status: 'PASS',
            index: index,
            total: total,
            label: target[:label],
            pid: target[:pid],
            face_count: faces.length,
            complex_face_count: complex.length,
            max_weak_vertex_count:
              face_records.map { |record| record[:weak_vertex_count] }.max || 0,
            max_inner_loop_count:
              face_records.map { |record| record[:inner_loop_count] }.max || 0,
            max_total_boundary_vertex_count:
              face_records.map do |record|
                record[:total_boundary_vertex_count]
              end.max || 0,
            max_bridge_candidate_estimate:
              face_records.map do |record|
                record[:bridge_candidate_estimate]
              end.max || 0,
            max_ear_work_estimate:
              face_records.map { |record| record[:ear_work_estimate] }.max || 0,
            complex_reason_counts: reason_counts(complex),
            face_records: face_records
          }
        end

        def analyze_face(target, face, face_index)
          loops = ordered_face_loops(face).map do |loop|
            keys = loop.vertices.map { |vertex| grid_key(vertex.position) }
            cleaned, removed = remove_consecutive_duplicates(keys)
            {
              outer: loop == face.outer_loop,
              source_vertex_count: keys.length,
              snapped_vertex_count: cleaned.length,
              removed_consecutive_duplicates: removed
            }
          end
          outer = loops.find { |record| record[:outer] }
          holes = loops.reject { |record| record[:outer] }
          outer_count = outer ? outer[:snapped_vertex_count] : 0
          hole_counts = holes.map { |record| record[:snapped_vertex_count] }
          total_boundary = outer_count + hole_counts.sum
          weak_vertices = total_boundary + (2 * hole_counts.length)
          bridge_candidates = bridge_candidate_estimate(outer_count, hole_counts)
          ear_work = weak_vertices * weak_vertices

          reasons = []
          reasons << :weak_vertex_limit if weak_vertices > WEAK_VERTEX_LIMIT
          reasons << :inner_loop_limit if hole_counts.length > INNER_LOOP_LIMIT
          if total_boundary > TOTAL_BOUNDARY_VERTEX_LIMIT
            reasons << :total_boundary_vertex_limit
          end
          reasons << :ear_work_limit if ear_work > EAR_WORK_LIMIT

          {
            solid_label: target[:label],
            solid_pid: target[:pid],
            face_index: face_index,
            face_pid: persistent_id(face),
            loop_count: loops.length,
            inner_loop_count: hole_counts.length,
            outer_vertex_count: outer_count,
            hole_vertex_count: hole_counts.sum,
            total_boundary_vertex_count: total_boundary,
            weak_vertex_count: weak_vertices,
            expected_triangle_count: [weak_vertices - 2, 0].max,
            bridge_candidate_estimate: bridge_candidates,
            ear_work_estimate: ear_work,
            removed_consecutive_duplicates:
              loops.sum { |record| record[:removed_consecutive_duplicates] },
            complex: !reasons.empty?,
            action: reasons.empty? ? 'polygon_reconstruction' : 'triangle_preserving',
            reasons: reasons
          }
        end

        # Production bridge scans the current outer/weak polygon once per hole.
        # This estimate follows the source loop order and updates the polygon size
        # by hole_vertices + 2 duplicated bridge endpoints after every bridge.
        def bridge_candidate_estimate(outer_count, hole_counts)
          polygon_count = outer_count
          candidates = 0
          Array(hole_counts).each do |hole_count|
            candidates += polygon_count
            polygon_count += hole_count + 2
          end
          candidates
        end

        def ordered_face_loops(face)
          outer = face.outer_loop
          [outer] + face.loops.reject { |loop| loop == outer }
        end

        def grid_key(point)
          [point.x, point.y, point.z].map do |coordinate|
            ((coordinate.to_f * MM_PER_INCH) / TOLERANCE_MM).round
          end
        end

        def remove_consecutive_duplicates(keys)
          cleaned = []
          removed = 0
          Array(keys).each do |key|
            if cleaned.empty? || cleaned.last != key
              cleaned << key
            else
              removed += 1
            end
          end
          if cleaned.length > 1 && cleaned.first == cleaned.last
            cleaned.pop
            removed += 1
          end
          [cleaned, removed]
        end

        def policy_hash
          {
            weak_vertex_limit: WEAK_VERTEX_LIMIT,
            inner_loop_limit: INNER_LOOP_LIMIT,
            total_boundary_vertex_limit: TOTAL_BOUNDARY_VERTEX_LIMIT,
            ear_work_limit: EAR_WORK_LIMIT
          }
        end

        def quantiles(records, key)
          values = Array(records).map { |record| record[key].to_i }.sort
          return {} if values.empty?

          {
            min: values.first,
            p50: percentile(values, 0.50),
            p90: percentile(values, 0.90),
            p95: percentile(values, 0.95),
            p99: percentile(values, 0.99),
            max: values.last
          }
        end

        def percentile(sorted, fraction)
          return sorted.first if sorted.length == 1

          index = fraction * (sorted.length - 1)
          lower = index.floor
          upper = index.ceil
          return sorted[lower] if lower == upper

          ((sorted[lower] * (upper - index)) +
            (sorted[upper] * (index - lower))).round
        end

        def reason_counts(records)
          counts = Hash.new(0)
          Array(records).each do |record|
            Array(record[:reasons]).each { |reason| counts[reason] += 1 }
          end
          counts
        end

        def face_sort_key(record)
          [
            record[:complex] ? 1 : 0,
            record[:ear_work_estimate].to_i,
            record[:bridge_candidate_estimate].to_i,
            record[:weak_vertex_count].to_i,
            record[:inner_loop_count].to_i,
            record[:solid_pid].to_i,
            record[:face_pid].to_i
          ]
        end

        def target_metadata(target)
          {
            label: target[:label],
            pid: target[:pid],
            face_count: target[:face_count]
          }
        end

        def persistent_id(entity)
          entity.respond_to?(:persistent_id) ? entity.persistent_id.to_i : entity.object_id
        rescue StandardError
          entity.object_id
        end

        def entity_label(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          name = entity.definition.name.to_s if
            name.empty? && entity.respond_to?(:definition) && entity.definition
          name = entity.class.name if name.empty?
          "#{name} [PID=#{persistent_id(entity)}]"
        end

        def build_log_path(model)
          directory = if model.respond_to?(:path) && !model.path.to_s.empty?
                        File.dirname(model.path.to_s)
                      else
                        Dir.tmpdir
                      end
          stamp = Time.now.strftime('%Y%m%d_%H%M%S')
          File.join(
            directory,
            "lvn_face_complexity_inventory_#{stamp}_pid#{Process.pid}.log"
          )
        end

        def write_event(io, event, payload = {}, level: 'INFO')
          normalized = normalize_payload(payload || {})
          io.write(
            format(
              '[%s] %-5s %-34s %s\n',
              Time.now.strftime('%Y-%m-%d %H:%M:%S.%L %z'),
              level,
              event,
              JSON.generate(normalized)
            )
          )
          io.flush
        end

        def normalize_payload(value)
          case value
          when Hash
            value.each_with_object({}) do |(key, item), result|
              result[key.to_s] = normalize_payload(item)
            end
          when Array
            value.map { |item| normalize_payload(item) }
          when Symbol
            value.to_s
          when String, Numeric, TrueClass, FalseClass, NilClass
            value
          else
            value.to_s
          end
        end

        def print_solid_progress(record)
          puts format(
            '[%4d/%4d] F=%5d complex=%3d weak_max=%5d holes_max=%4d %s',
            record[:index],
            record[:total],
            record[:face_count],
            record[:complex_face_count],
            record[:max_weak_vertex_count],
            record[:max_inner_loop_count],
            record[:label]
          )
        end

        def print_skipped(skipped)
          entries = skipped.select { |_key, count| count.to_i.positive? }
          return puts('skipped               : none') if entries.empty?

          puts 'skipped:'
          entries.sort_by { |key, _count| key.to_s }.each do |key, count|
            puts format('  %-32s %6d', key, count)
          end
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::LvnFaceComplexityInventoryProbe.run
nil
