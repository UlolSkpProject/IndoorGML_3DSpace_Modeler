# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'time'
require_relative '../indoor3d/infrastructure/scene/entity_copy_helper'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnComplexFaceTrianglePreservingProbe
        WEAK_VERTEX_LIMIT = 512
        INNER_LOOP_LIMIT = 32
        TOTAL_BOUNDARY_VERTEX_LIMIT = 1_024
        EAR_WORK_LIMIT = 500_000
        HEARTBEAT_SECONDS = 15.0
        STACK_DEPTH = 12

        class ComplexFaceMeshValidationError < StandardError; end

        module Implementation
          private

          def normalize_entity(entity)
            @complex_face_triangle_preserving_records = []
            @complex_face_triangle_preserving_cleanup_skipped = false
            report = super
            report[:complex_face_triangle_preserving] = {
              enabled: !@complex_face_triangle_preserving_records.empty?,
              face_count: @complex_face_triangle_preserving_records.length,
              policy: LvnComplexFaceTrianglePreservingProbe.policy_hash,
              faces: @complex_face_triangle_preserving_records.map(&:dup),
              coplanar_cleanup_skipped:
                @complex_face_triangle_preserving_cleanup_skipped == true
            }
            report
          end

          # Complex source Faces use SketchUp's existing triangle mesh, but only
          # after the mesh passes the same exact source-boundary, degeneracy and
          # intersection checks used by the polygon reconstruction path.
          def source_boundary_triangle_records(face, source_face_key)
            complexity =
              LvnComplexFaceTrianglePreservingProbe.face_complexity(self, face)
            return super unless complexity[:complex]

            records = LvnComplexFaceTrianglePreservingProbe.mesh_triangle_records(
              self,
              face,
              source_face_key
            )
            loops = face.loops.map do |loop|
              compact_integer_loop(
                loop.vertices.map do |vertex|
                  source_precision_indices(vertex.position)
                end
              )
            end

            begin
              validate_source_boundary_retriangulation!(records, loops)
            rescue Error, ArgumentError => error
              raise ComplexFaceMeshValidationError,
                    "Complex source Face mesh failed exact boundary validation: " \
                    "face=#{source_face_key.inspect} " \
                    "#{error.class}: #{error.message}"
            end

            @complex_face_triangle_preserving_records << complexity.merge(
              source_face_key: source_face_key,
              mesh_triangle_count: records.length,
              exact_source_boundary_validated: true
            )
            records
          end

          # Once one complex source Face selected the triangle-preserving path,
          # retain the complete validated triangle surface. Removing coplanar
          # edges would recreate the same huge polygon and force another exact
          # bridge/ear triangulation during the final hard gate.
          def orient_and_merge_rebuilt_surface(entities, validated_triangles)
            return super if @complex_face_triangle_preserving_records.nil? ||
                            @complex_face_triangle_preserving_records.empty?

            topology_before = geometry_counts(entities)
            consistency = repair_reverse_faces(entities)
            topology = geometry_counts(entities)
            unless closed_surface?(topology)
              raise TopologyChangedError,
                    "Triangle-preserving rebuilt shell is not closed: " \
                    "#{topology.inspect}"
            end

            snapshot_duplicate_diagnostics = {}
            snapshot_triangles = normalized_triangle_snapshot(
              entities,
              duplicate_diagnostics: snapshot_duplicate_diagnostics,
              snapshot_role: :complex_face_triangle_preserving
            )
            snapshot_triangles, snapshot_cleanup =
              discard_collapsed_triangle_records(snapshot_triangles)
            snapshot_mesh_validation =
              validate_normalized_triangle_mesh!(snapshot_triangles)
            snapshot_surface_equivalence = verify_normalized_surface_equivalence!(
              validated_triangles,
              snapshot_triangles
            )

            @complex_face_triangle_preserving_cleanup_skipped = true
            cleanup = empty_coplanar_cleanup_report(
              fallback_reason: :complex_source_face_triangle_preserving
            )
            cleanup[:merged_faces] = 0
            cleanup[:preserved_constrained_edges] = true
            cleanup[:complex_face_count] =
              @complex_face_triangle_preserving_records.length

            topology_after = geometry_counts(entities)
            orientation = {
              reversed_faces: consistency[:reversed_faces].to_i,
              consistency_reversed_faces:
                consistency[:consistency_reversed_faces].to_i,
              shell_component_count: consistency[:component_count].to_i,
              outward_reversed_faces: consistency[:outward_reversed_faces].to_i,
              signed_volume_before_mm3:
                consistency[:signed_volume_before_in3].to_f * (MM_PER_INCH**3),
              signed_volume_after_mm3:
                consistency[:signed_volume_after_in3].to_f * (MM_PER_INCH**3),
              topology_before: topology_before,
              topology_after: topology_after,
              error: consistency[:error]
            }
            snapshot = {
              validated: true,
              triangles: snapshot_triangles,
              duplicate_diagnostics: snapshot_duplicate_diagnostics,
              degenerate_repair: snapshot_cleanup,
              mesh_validation: snapshot_mesh_validation,
              surface_equivalence: snapshot_surface_equivalence,
              topology: topology_after,
              triangle_preserving: true
            }

            [orientation, cleanup, snapshot]
          end
        end

        class SyncLog
          attr_reader :path

          def initialize(path, worker_thread: Thread.current)
            @path = path
            @worker_thread = worker_thread
            @started_at = monotonic_time
            @context = {}
            @mutex = Mutex.new
            @stop = false
            @io = File.open(path, 'wb')
            @io.set_encoding(Encoding::UTF_8)
            @io.sync = true
          end

          def context=(value)
            @mutex.synchronize { @context = normalize_payload(value || {}) }
          end

          def log(event, data = {}, level: 'INFO')
            payload = normalize_payload(data)
            line = format(
              "[%s] +%0.3fs %-5s %-38s %s\n",
              Time.now.strftime('%Y-%m-%d %H:%M:%S.%L %z'),
              monotonic_time - @started_at,
              level,
              event.to_s,
              JSON.generate(payload)
            )
            @mutex.synchronize do
              @io.write(line)
              @io.flush
            end
          end

          def start_heartbeat
            @thread = Thread.new do
              loop do
                sleep HEARTBEAT_SECONDS
                break if @stop

                context = @mutex.synchronize { @context.dup }
                stack = Array(@worker_thread.backtrace_locations)
                        .first(STACK_DEPTH)
                        .map do |location|
                  path = location.absolute_path || location.path
                  "#{File.basename(path.to_s)}:#{location.lineno}:in `#{location.label}'"
                end
                gc = GC.stat
                log(
                  'HEARTBEAT',
                  context.merge(
                    worker_status: @worker_thread.status,
                    worker_stack: stack,
                    gc: {
                      heap_live_slots: gc[:heap_live_slots],
                      total_allocated_objects: gc[:total_allocated_objects],
                      total_freed_objects: gc[:total_freed_objects],
                      minor_gc_count: gc[:minor_gc_count],
                      major_gc_count: gc[:major_gc_count]
                    }
                  )
                )
              end
            rescue StandardError => error
              log(
                'HEARTBEAT_ERROR',
                {
                  error_class: error.class.name,
                  error_message: error.message
                },
                level: 'ERROR'
              )
            end
          end

          def close
            @stop = true
            @thread&.wakeup if @thread&.alive?
            @thread&.join(2.0)
            log('LOG_CLOSE') unless @io.closed?
            @mutex.synchronize do
              @io.flush unless @io.closed?
              @io.close unless @io.closed?
            end
          rescue ThreadError
            @thread&.join(2.0)
            retry
          end

          private

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

          def monotonic_time
            Process.clock_gettime(Process::CLOCK_MONOTONIC)
          end
        end

        module_function

        def policy_hash
          {
            weak_vertex_limit: WEAK_VERTEX_LIMIT,
            inner_loop_limit: INNER_LOOP_LIMIT,
            total_boundary_vertex_limit: TOTAL_BOUNDARY_VERTEX_LIMIT,
            ear_work_limit: EAR_WORK_LIMIT
          }
        end

        def face_complexity(normalizer, face)
          loops = face.loops.map do |loop|
            normalizer.send(
              :compact_integer_loop,
              loop.vertices.map do |vertex|
                normalizer.send(:source_precision_indices, vertex.position)
              end
            )
          end
          inner_loop_count = [loops.length - 1, 0].max
          total_boundary_vertex_count = loops.sum(&:length)
          weak_vertex_count =
            total_boundary_vertex_count + (2 * inner_loop_count)
          ear_work_estimate = weak_vertex_count * weak_vertex_count
          reasons = []
          reasons << :weak_vertex_limit if
            weak_vertex_count > WEAK_VERTEX_LIMIT
          reasons << :inner_loop_limit if
            inner_loop_count > INNER_LOOP_LIMIT
          reasons << :total_boundary_vertex_limit if
            total_boundary_vertex_count > TOTAL_BOUNDARY_VERTEX_LIMIT
          reasons << :ear_work_limit if
            ear_work_estimate > EAR_WORK_LIMIT

          {
            loop_count: loops.length,
            inner_loop_count: inner_loop_count,
            total_boundary_vertex_count: total_boundary_vertex_count,
            weak_vertex_count: weak_vertex_count,
            ear_work_estimate: ear_work_estimate,
            complex: !reasons.empty?,
            reasons: reasons
          }
        end

        def mesh_triangle_records(normalizer, face, source_face_key)
          source_normal = normalizer.send(:vector_components, face.normal)
          mesh = face.mesh(0)
          records = mesh.polygons.each_with_index.flat_map do |polygon, polygon_index|
            points = polygon.map { |index| mesh.point_at(index.abs) }
            normalizer.send(:triangulate_polygon, points).map.with_index do |triangle, part|
              {
                points: triangle,
                source_normal: source_normal,
                material: face.material,
                back_material: face.back_material,
                layer: face.layer,
                source_face_key: source_face_key,
                source_polygon_index: [polygon_index, part],
                source_mesh_triangle_preserving: true
              }
            end
          end
          if records.empty?
            raise ComplexFaceMeshValidationError,
                  "Complex source Face mesh returned no triangles: " \
                  "face=#{source_face_key.inspect}"
          end
          records
        end

        def run
          model = Sketchup.active_model
          original_selection = model.selection.to_a
          target = select_target(model, original_selection)
          raise 'Select one or more top-level manifold solids first' unless target

          core = ULOL::Indoor3DGmlModeler::IndoorCore
          if core::LocalVertexNormalizer.ancestors.include?(Implementation)
            raise 'Complex Face triangle-preserving probe is already installed'
          end
          core::LocalVertexNormalizer.prepend(Implementation)

          log_path = build_log_path(model)
          FileUtils.mkdir_p(File.dirname(log_path))
          log = SyncLog.new(log_path, worker_thread: Thread.current)
          log.start_heartbeat

          source_signature = brep_signature(target)
          root_before = model_root_signature(model)
          metadata = target_metadata(target)
          log.context = metadata.merge(stage: 'starting')
          log.log(
            'RUN_BEGIN',
            metadata.merge(
              policy: policy_hash,
              model_path: model.respond_to?(:path) ? model.path.to_s : nil,
              ruby_version: RUBY_VERSION,
              sketchup_version:
                Sketchup.respond_to?(:version) ? Sketchup.version.to_s : nil
            )
          )

          puts '=' * 112
          puts ' LVN Phase 5.5.2 — Complex Face Triangle-Preserving Probe'
          puts '=' * 112
          puts format('target                : %s', metadata[:label])
          puts format(
            'source geometry       : F=%d E=%d V=%d',
            metadata[:faces],
            metadata[:edges],
            metadata[:vertices]
          )
          puts format('policy                : %s', policy_hash.inspect)
          puts 'complex source Face   : exact-validated SketchUp mesh'
          puts 'coplanar cleanup      : skipped only when complex Face is present'
          puts 'candidate lifetime    : fresh unique copy; outer operation aborted'
          puts format('log file              : %s', log_path)
          puts '-' * 112

          result = {
            target: metadata,
            passed: false,
            source_restored: false,
            root_restored: false
          }
          operation_started = false
          begin
            operation_started = model.start_operation(
              "LVN complex Face triangle-preserving PID=#{metadata[:pid]}",
              true
            )
            raise 'SketchUp start_operation returned false' if operation_started == false

            candidate = copy_source_instance(target, model, metadata[:pid])
            result[:candidate_fresh] =
              brep_signature(candidate) == source_signature
            result[:definition_isolated] =
              candidate.definition != target.definition
            log.context = metadata.merge(stage: 'normalizing')

            started = monotonic_time
            report = core::LocalVertexNormalizer.normalize(
              candidate,
              core::LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
              manage_operation: false
            )
            result[:elapsed_s] = monotonic_time - started
            result[:report_complete] =
              report.is_a?(Hash) &&
              report[:normalization_complete] == true &&
              report[:manifold] == true
            result[:candidate_manifold] =
              candidate.valid? &&
              candidate.respond_to?(:manifold?) &&
              candidate.manifold? == true
            result[:candidate_normalized] =
              core::LocalVertexNormalizer.normalized?(
                candidate,
                core::LocalVertexNormalizer::DEFAULT_TOLERANCE_MM
              )
            result[:normalization_strategy] =
              report[:normalization_strategy] if report.is_a?(Hash)
            result[:max_grid_residual_mm] =
              report[:max_grid_residual_mm] if report.is_a?(Hash)
            result[:triangle_preserving] =
              report[:complex_face_triangle_preserving] if report.is_a?(Hash)
            result[:coplanar_cleanup] = report[:axis_plane_merge] if
              report.is_a?(Hash)
            result[:counts] = geometry_counts(candidate)
            result[:passed] =
              result[:candidate_fresh] &&
              result[:definition_isolated] &&
              result[:report_complete] &&
              result[:candidate_manifold] &&
              result[:candidate_normalized] &&
              result.dig(:triangle_preserving, :enabled) == true &&
              result.dig(
                :triangle_preserving,
                :coplanar_cleanup_skipped
              ) == true
          rescue Exception => error # rubocop:disable Lint/RescueException
            result[:error_class] = error.class.name
            result[:error_message] = error.message
            result[:backtrace] = Array(error.backtrace).first(30)
          ensure
            if operation_started
              begin
                aborted = model.abort_operation
                raise 'SketchUp abort_operation returned false' if aborted == false
              rescue Exception => abort_error # rubocop:disable Lint/RescueException
                result[:abort_error_class] = abort_error.class.name
                result[:abort_error_message] = abort_error.message
                result[:passed] = false
              end
            end
          end

          result[:source_restored] = brep_signature(target) == source_signature
          result[:root_restored] = model_root_signature(model) == root_before
          result[:selection_restored] =
            restore_selection(model, original_selection)
          result[:passed] &&=
            result[:source_restored] &&
            result[:root_restored] &&
            result[:selection_restored]
          log.log('RUN_END', result, level: result[:passed] ? 'INFO' : 'ERROR')

          puts format('elapsed               : %.3f s', result[:elapsed_s].to_f)
          puts format(
            'complex Faces         : %d',
            result.dig(:triangle_preserving, :face_count).to_i
          )
          puts format(
            'coplanar skipped      : %s',
            result.dig(
              :triangle_preserving,
              :coplanar_cleanup_skipped
            ).inspect
          )
          puts format('candidate manifold    : %s', result[:candidate_manifold].inspect)
          puts format('candidate normalized  : %s', result[:candidate_normalized].inspect)
          puts format('source restored       : %s', result[:source_restored].inspect)
          puts format('model root restored   : %s', result[:root_restored].inspect)
          puts format('selection restored    : %s', result[:selection_restored].inspect)
          if result[:error_class]
            puts format(
              'error                 : %s: %s',
              result[:error_class],
              result[:error_message]
            )
          end
          puts format('result                : %s', result[:passed] ? 'PASS' : 'FAIL')
          puts '=' * 112
          result[:passed]
        rescue Exception => error # rubocop:disable Lint/RescueException
          log&.log(
            'RUN_FATAL',
            {
              error_class: error.class.name,
              error_message: error.message,
              backtrace: Array(error.backtrace).first(30)
            },
            level: 'ERROR'
          )
          warn "[LVN COMPLEX FACE] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(20).join("\n")
          false
        ensure
          restore_selection(model, original_selection) if
            defined?(model) && model &&
            defined?(original_selection) && original_selection
          log&.close
        end

        def select_target(model, selection)
          Array(selection).select do |entity|
            entity.respond_to?(:valid?) &&
              entity.valid? &&
              entity.respond_to?(:definition) &&
              entity.definition&.valid? &&
              entity.parent == model &&
              entity.respond_to?(:manifold?) &&
              entity.manifold? == true
          end.max_by do |entity|
            [
              entity.definition.entities.grep(Sketchup::Face).count(&:valid?),
              persistent_id(entity)
            ]
          end
        end

        def target_metadata(entity)
          counts = geometry_counts(entity)
          {
            label: entity_label(entity),
            pid: persistent_id(entity),
            faces: counts[:faces],
            edges: counts[:edges],
            vertices: counts[:vertices],
            manifold: counts[:manifold]
          }
        end

        def copy_source_instance(source, model, pid)
          candidate = EntityCopyHelper.copy_instance(
            source: source,
            target_entities: model.entities,
            transformation: source.transformation,
            convert_to_group: :source_group,
            make_unique: true,
            copy_attributes: %i[name material layer visible]
          )
          raise 'Candidate copy is invalid' unless candidate&.valid?
          if candidate.definition == source.definition
            raise 'Candidate copy did not receive a unique definition'
          end
          candidate.name = "LVN_COMPLEX_FACE_TEMP_#{pid}" if
            candidate.respond_to?(:name=)
          candidate
        end

        def geometry_counts(entity)
          entities = entity.definition.entities
          faces = entities.grep(Sketchup::Face).select(&:valid?)
          edges = entities.grep(Sketchup::Edge).select(&:valid?)
          {
            faces: faces.length,
            edges: edges.length,
            vertices: edges.flat_map(&:vertices).uniq.length,
            manifold:
              entity.respond_to?(:manifold?) ? entity.manifold? : nil
          }
        end

        def brep_signature(entity)
          edges = entity.definition.entities.grep(Sketchup::Edge)
                        .select(&:valid?)
                        .map do |edge|
            canonical_edge(
              exact_point_key(edge.start.position),
              exact_point_key(edge.end.position)
            )
          end.sort
          faces = entity.definition.entities.grep(Sketchup::Face)
                        .select(&:valid?)
                        .map do |face|
            face.loops.map do |loop|
              vertices = loop.vertices
              vertices.each_index.map do |index|
                canonical_edge(
                  exact_point_key(vertices[index].position),
                  exact_point_key(
                    vertices[(index + 1) % vertices.length].position
                  )
                )
              end.sort
            end.sort
          end.sort
          Digest::SHA256.hexdigest(Marshal.dump([edges, faces]))
        end

        def exact_point_key(point)
          [point.x.to_f, point.y.to_f, point.z.to_f]
        end

        def canonical_edge(first, second)
          (first <=> second) <= 0 ? [first, second] : [second, first]
        end

        def model_root_signature(model)
          model.entities.to_a.filter_map do |entity|
            next unless entity.respond_to?(:valid?) && entity.valid?

            [entity.class.name, persistent_id(entity)]
          end.sort
        end

        def restore_selection(model, entities)
          model.selection.clear
          expected = []
          Array(entities).each do |entity|
            next unless entity.respond_to?(:valid?) && entity.valid?

            model.selection.add(entity)
            expected << persistent_id(entity)
          end
          model.selection.to_a.map { |entity| persistent_id(entity) }.sort ==
            expected.sort
        rescue StandardError
          false
        end

        def persistent_id(entity)
          entity.respond_to?(:persistent_id) ?
            entity.persistent_id.to_i : entity.object_id
        end

        def entity_label(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          name = entity.class.name if name.empty?
          "#{name} [PID=#{persistent_id(entity)}]"
        end

        def build_log_path(model)
          directory = if model.respond_to?(:path) && !model.path.to_s.empty?
                        File.dirname(model.path)
                      else
                        Dir.tmpdir
                      end
          timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
          pid = Process.respond_to?(:pid) ? Process.pid : 'unknown'
          File.join(
            directory,
            "lvn_complex_face_triangle_preserving_#{timestamp}_pid#{pid}.log"
          )
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::
  LvnComplexFaceTrianglePreservingProbe.run

nil
