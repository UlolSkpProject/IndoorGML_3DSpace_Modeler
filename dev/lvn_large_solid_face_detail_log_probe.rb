# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'
require 'time'

# Reuse the safe copy/rollback runner from the detailed probe, but suppress that
# file's automatic run so the face-level instrumentation can be installed first.
base_probe_path = File.join(__dir__, 'lvn_large_solid_detailed_log_probe.rb')
unless defined?(
  ULOL::Indoor3DGmlModeler::IndoorCore::LvnLargeSolidDetailedLogProbe
)
  source = File.binread(base_probe_path).force_encoding(Encoding::UTF_8)
  pattern = %r{
    \nULOL::Indoor3DGmlModeler::IndoorCore::\s*
    LvnLargeSolidDetailedLogProbe\.run\s*\z
  }mx
  stripped = source.sub(pattern, "\n")
  raise "Could not suppress default run in #{base_probe_path}" if stripped == source

  TOPLEVEL_BINDING.eval(stripped, base_probe_path, 1)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Development-only face/hole/candidate progress logger. Production LVN
      # methods are only wrapped and are always reached through +super+.
      module LvnLargeSolidFaceDetailLogProbe
        BASE = LvnLargeSolidDetailedLogProbe
        DETAIL_HEARTBEAT_SECONDS = 5.0
        SLOW_CANDIDATE_SECONDS = 1.0

        @progress = {}

        module_function

        def mono
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        def log(event, data = {}, level: 'INFO', **fields)
          payload = fields.empty? ? data : data.merge(fields)
          BASE.active_context&.log(event, payload, level: level)
        end

        def reset_progress
          @progress = {
            face: nil,
            polygon: nil,
            bridge: nil,
            candidate: nil,
            last_completed_face: nil,
            last_completed_polygon: nil,
            last_completed_bridge: nil
          }
        end

        def set_progress(key, value)
          (@progress ||= {})[key] = value
        end

        def progress_value(key)
          (@progress ||= {})[key]
        end

        def progress_snapshot
          now = mono
          result = {}
          %i[face polygon bridge candidate].each do |key|
            value = progress_value(key)&.dup
            if value && value[:started_at]
              value[:elapsed_s] = now - value.delete(:started_at)
            end
            result[key] = value
          end
          %i[last_completed_face last_completed_polygon last_completed_bridge].each do |key|
            result[key] = progress_value(key)&.dup
          end
          result
        rescue StandardError => error
          { progress_snapshot_error: "#{error.class}: #{error.message}" }
        end

        def begin_progress(key, metadata)
          set_progress(key, metadata.merge(started_at: mono))
        end

        def finish_progress(key, completed_key, metadata)
          set_progress(completed_key, metadata)
          set_progress(key, nil)
        end

        def face_metadata(instance, face, source_face_key)
          index_map = instance.instance_variable_get(
            :@lvn_face_detail_face_index_map
          ) || {}
          indexed = index_map[face.object_id] || {}
          loops = face.respond_to?(:loops) ? Array(face.loops) : []
          outer_loop = face.respond_to?(:outer_loop) ? face.outer_loop : nil
          loop_sizes = loops.map do |loop|
            loop.respond_to?(:vertices) ? Array(loop.vertices).length : nil
          end
          outer_index = outer_loop ? loops.index(outer_loop) : nil
          hole_sizes = loop_sizes.each_with_index.filter_map do |size, index|
            size unless index == outer_index
          end
          {
            face_index: indexed[:index],
            face_total: indexed[:total],
            face_pid: face.respond_to?(:persistent_id) ? face.persistent_id : nil,
            source_face_key: source_face_key,
            loop_count: loops.length,
            loop_vertex_counts: loop_sizes,
            sketchup_outer_loop_index: outer_index,
            sketchup_outer_vertex_count:
              outer_index ? loop_sizes[outer_index] : nil,
            sketchup_hole_count: hole_sizes.length,
            sketchup_hole_vertex_counts: hole_sizes,
            face_area: face.respond_to?(:area) ? face.area.to_f : nil,
            face_valid: face.respond_to?(:valid?) ? face.valid? : nil
          }
        rescue StandardError => error
          {
            source_face_key: source_face_key,
            face_metadata_error: "#{error.class}: #{error.message}"
          }
        end

        def cache_before(instance, outer, holes, drop_axis)
          cache = instance.instance_variable_get(
            :@local_vertex_normalizer_exact_polygon_cache_v2
          )
          stats = instance.instance_variable_get(
            :@local_vertex_normalizer_exact_polygon_cache_stats_v2
          )
          return { cache_enabled: false, cache_hit: false } unless cache && stats

          key = instance.send(
            :exact_polygon_ordered_cache_key_v2,
            outer,
            holes,
            drop_axis
          )
          {
            cache_enabled: true,
            cache_hit: cache.key?(key),
            cache_entries_before: cache.length,
            cache_hits_before: stats[:hits],
            cache_misses_before: stats[:misses]
          }
        rescue StandardError => error
          {
            cache_enabled: nil,
            cache_hit: nil,
            cache_error: "#{error.class}: #{error.message}"
          }
        end

        def cache_after(instance)
          cache = instance.instance_variable_get(
            :@local_vertex_normalizer_exact_polygon_cache_v2
          )
          stats = instance.instance_variable_get(
            :@local_vertex_normalizer_exact_polygon_cache_stats_v2
          )
          {
            cache_entries_after: cache&.length,
            cache_hits_after: stats && stats[:hits],
            cache_misses_after: stats && stats[:misses],
            cache_stored_triangle_count: stats && stats[:stored_triangle_count]
          }
        rescue StandardError => error
          { cache_after_error: "#{error.class}: #{error.message}" }
        end

        module FaceDetailInstrumentation
          private

          def triangle_snapshot(entities)
            faces = entities.grep(@face_class)
            @lvn_face_detail_face_index_map = {}
            faces.each_with_index do |face, index|
              @lvn_face_detail_face_index_map[face.object_id] = {
                index: index + 1,
                total: faces.length
              }
            end
            LvnLargeSolidFaceDetailLogProbe.log(
              'FACE_INVENTORY_READY',
              face_total: faces.length
            )
            super
          ensure
            @lvn_face_detail_face_index_map = nil
          end

          def source_boundary_triangle_records(face, source_face_key)
            probe = LvnLargeSolidFaceDetailLogProbe
            metadata = probe.face_metadata(self, face, source_face_key)
            started_at = probe.mono
            probe.begin_progress(:face, metadata)
            probe.set_progress(:polygon, nil)
            probe.set_progress(:bridge, nil)
            probe.set_progress(:candidate, nil)
            probe.log('FACE_TRIANGULATION_BEGIN', metadata)

            records = super
            completed = metadata.merge(
              duration_s: probe.mono - started_at,
              triangle_count: Array(records).length,
              result: 'boundary_loops'
            )
            probe.log('FACE_TRIANGULATION_END', completed)
            probe.finish_progress(:face, :last_completed_face, completed)
            records
          rescue Exception => error # rubocop:disable Lint/RescueException
            failed = metadata.merge(
              duration_s: probe.mono - started_at,
              result: 'mesh_fallback_expected',
              error_class: error.class.name,
              error_message: error.message,
              backtrace: Array(error.backtrace).first(12)
            )
            probe.log('FACE_BOUNDARY_TRIANGULATION_ERROR', failed, level: 'WARN')
            probe.finish_progress(:face, :last_completed_face, failed)
            raise
          end

          def triangulate_exact_polygon_with_holes(outer, holes, drop_axis)
            probe = LvnLargeSolidFaceDetailLogProbe
            holes = Array(holes)
            metadata = {
              outer_vertex_count: Array(outer).length,
              hole_count: holes.length,
              hole_vertex_counts: holes.map { |hole| Array(hole).length },
              total_boundary_vertex_count:
                Array(outer).length + holes.sum { |hole| Array(hole).length },
              drop_axis: drop_axis
            }.merge(probe.cache_before(self, outer, holes, drop_axis))
            @lvn_face_detail_bridge_index = 0
            started_at = probe.mono
            probe.begin_progress(:polygon, metadata)
            probe.set_progress(:bridge, nil)
            probe.set_progress(:candidate, nil)
            probe.log('EXACT_POLYGON_BEGIN', metadata)

            triangles = super
            completed = metadata.merge(probe.cache_after(self)).merge(
              duration_s: probe.mono - started_at,
              triangle_count: Array(triangles).length
            )
            probe.log('EXACT_POLYGON_END', completed)
            probe.finish_progress(:polygon, :last_completed_polygon, completed)
            triangles
          rescue Exception => error # rubocop:disable Lint/RescueException
            failed = metadata.merge(probe.cache_after(self)).merge(
              duration_s: probe.mono - started_at,
              error_class: error.class.name,
              error_message: error.message,
              backtrace: Array(error.backtrace).first(12)
            )
            probe.log('EXACT_POLYGON_ERROR', failed, level: 'ERROR')
            probe.finish_progress(:polygon, :last_completed_polygon, failed)
            raise
          ensure
            @lvn_face_detail_bridge_index = nil
          end

          def bridge_exact_hole(polygon, hole, outer_2d, holes_2d, drop_axis)
            probe = LvnLargeSolidFaceDetailLogProbe
            @lvn_face_detail_bridge_index =
              @lvn_face_detail_bridge_index.to_i + 1
            @lvn_face_detail_candidate_index = 0
            @lvn_face_detail_accepted = 0
            @lvn_face_detail_rejected = 0
            metadata = {
              bridge_index: @lvn_face_detail_bridge_index,
              bridge_total: Array(holes_2d).length,
              polygon_vertex_count_before: Array(polygon).length,
              hole_vertex_count: Array(hole).length,
              candidate_upper_bound: Array(polygon).length,
              all_loop_vertex_count:
                Array(polygon).length +
                  Array(holes_2d).sum { |loop| Array(loop).length },
              drop_axis: drop_axis
            }
            started_at = probe.mono
            probe.begin_progress(:bridge, metadata)
            probe.set_progress(:candidate, nil)
            probe.log('HOLE_BRIDGE_BEGIN', metadata)

            bridged = super
            completed = metadata.merge(
              duration_s: probe.mono - started_at,
              polygon_vertex_count_after: Array(bridged).length,
              visibility_calls: @lvn_face_detail_candidate_index,
              accepted_candidates: @lvn_face_detail_accepted,
              rejected_candidates: @lvn_face_detail_rejected
            )
            probe.log('HOLE_BRIDGE_END', completed)
            probe.finish_progress(:bridge, :last_completed_bridge, completed)
            bridged
          rescue Exception => error # rubocop:disable Lint/RescueException
            failed = metadata.merge(
              duration_s: probe.mono - started_at,
              visibility_calls: @lvn_face_detail_candidate_index,
              accepted_candidates: @lvn_face_detail_accepted,
              rejected_candidates: @lvn_face_detail_rejected,
              error_class: error.class.name,
              error_message: error.message,
              backtrace: Array(error.backtrace).first(12)
            )
            probe.log('HOLE_BRIDGE_ERROR', failed, level: 'ERROR')
            probe.finish_progress(:bridge, :last_completed_bridge, failed)
            raise
          ensure
            @lvn_face_detail_candidate_index = nil
            @lvn_face_detail_accepted = nil
            @lvn_face_detail_rejected = nil
          end

          def exact_bridge_visible?(point_a, point_b, loops, outer, holes)
            probe = LvnLargeSolidFaceDetailLogProbe
            @lvn_face_detail_candidate_index =
              @lvn_face_detail_candidate_index.to_i + 1
            metadata = {
              candidate_index: @lvn_face_detail_candidate_index,
              candidate_upper_bound:
                probe.progress_value(:bridge)&.dig(:candidate_upper_bound),
              point_a: Array(point_a),
              point_b: Array(point_b),
              loop_count: Array(loops).length,
              outer_vertex_count: Array(outer).length,
              hole_count: Array(holes).length
            }
            started_at = probe.mono
            probe.begin_progress(:candidate, metadata)

            visible = super
            if visible
              @lvn_face_detail_accepted = @lvn_face_detail_accepted.to_i + 1
            else
              @lvn_face_detail_rejected = @lvn_face_detail_rejected.to_i + 1
            end
            bridge = probe.progress_value(:bridge)
            if bridge
              bridge[:visibility_calls] = @lvn_face_detail_candidate_index
              bridge[:accepted_candidates] = @lvn_face_detail_accepted
              bridge[:rejected_candidates] = @lvn_face_detail_rejected
            end
            duration_s = probe.mono - started_at
            if duration_s >= LvnLargeSolidFaceDetailLogProbe::SLOW_CANDIDATE_SECONDS
              probe.log(
                'SLOW_BRIDGE_CANDIDATE',
                metadata.merge(duration_s: duration_s, visible: visible),
                level: 'WARN'
              )
            end
            probe.set_progress(:candidate, nil)
            visible
          rescue Exception => error # rubocop:disable Lint/RescueException
            probe.log(
              'BRIDGE_CANDIDATE_ERROR',
              metadata.merge(
                duration_s: probe.mono - started_at,
                error_class: error.class.name,
                error_message: error.message,
                backtrace: Array(error.backtrace).first(10)
              ),
              level: 'ERROR'
            )
            probe.set_progress(:candidate, nil)
            raise
          end
        end

        module FaceHeartbeatInstrumentation
          def start_heartbeat
            super
            return if @lvn_face_detail_thread&.alive?

            @lvn_face_detail_stop = false
            @lvn_face_detail_thread = Thread.new do
              Thread.current.name = 'lvn-face-detail-heartbeat' if
                Thread.current.respond_to?(:name=)
              loop do
                sleep LvnLargeSolidFaceDetailLogProbe::DETAIL_HEARTBEAT_SECONDS
                break if @lvn_face_detail_stop

                log(
                  'FACE_DETAIL_HEARTBEAT',
                  LvnLargeSolidFaceDetailLogProbe.progress_snapshot
                )
              end
            rescue StandardError => error
              log(
                'FACE_DETAIL_HEARTBEAT_ERROR',
                {
                  error_class: error.class.name,
                  error_message: error.message,
                  backtrace: Array(error.backtrace).first(12)
                },
                level: 'ERROR'
              )
            end
          end

          def stop_heartbeat
            @lvn_face_detail_stop = true
            thread = @lvn_face_detail_thread
            if thread
              begin
                thread.wakeup if thread.alive?
              rescue ThreadError
                nil
              end
              thread.join(2.0)
            end
            @lvn_face_detail_thread = nil
            super
          end
        end

        BASE::DiagnosticLog.prepend(FaceHeartbeatInstrumentation) unless
          BASE::DiagnosticLog.ancestors.include?(FaceHeartbeatInstrumentation)

        BASE.define_singleton_method(:install_instrumentation) do
          unless LocalVertexNormalizer.ancestors.include?(BASE::DetailedInstrumentation)
            LocalVertexNormalizer.prepend(BASE::DetailedInstrumentation)
          end
          detail = LvnLargeSolidFaceDetailLogProbe::FaceDetailInstrumentation
          LocalVertexNormalizer.prepend(detail) unless
            LocalVertexNormalizer.ancestors.include?(detail)
        end

        BASE.define_singleton_method(:build_log_path) do |model|
          model_path = model.respond_to?(:path) ? model.path.to_s : ''
          base_dir = if !model_path.empty? &&
                        File.directory?(File.dirname(model_path))
                       File.dirname(model_path)
                     else
                       Dir.tmpdir
                     end
          directory = File.join(base_dir, 'LVN_Diagnostic_Logs')
          File.join(
            directory,
            format(
              'lvn_large_face_detail_%s_pid%d.log',
              Time.now.strftime('%Y%m%d_%H%M%S'),
              Process.pid
            )
          )
        end

        reset_progress
        BASE.run
      end
    end
  end
end
