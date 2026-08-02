# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'
require 'tmpdir'
require 'time'
require_relative '../indoor3d/infrastructure/scene/entity_copy_helper'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Fresh-session corpus regression for the unmodified production LVN stack.
      # Every selected top-level solid is copied to an isolated definition inside
      # an outer operation, normalized through the public production API, checked,
      # and then discarded by aborting the operation.
      module LvnCorpusProductionRegressionProbe
        HEARTBEAT_SECONDS = 30.0
        STACK_DEPTH = 12
        EXPECTED_CORPUS_SIZE = 1_618
        DEV_CONSTANTS = %i[
          LvnCoplanarIncrementalTopologyProbe
          LvnBridgeNearestFirstProbe
          LvnBridgeBlockedEarProbe
          LvnBridgeBlockedEarRecoveryProbe
          LvnLargeSolidDetailedLogProbe
          LvnLargeSolidFaceDetailLogProbe
          LvnCorpusAbRegressionProbe
        ].freeze

        class SyncLog
          attr_reader :path

          def initialize(path, worker_thread: Thread.current)
            @path = path
            @worker_thread = worker_thread
            @started_at = monotonic_time
            @mutex = Mutex.new
            @context = {}
            @stop_heartbeat = false
            @io = File.open(path, 'wb')
            @io.set_encoding(Encoding::UTF_8)
            @io.sync = true
          end

          def log(event, data = nil, level: 'INFO')
            data = {} if data.nil?
            data = { value: data } unless data.is_a?(Hash)
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
            true
          rescue StandardError => error
            warn "[LVN PRODUCTION CORPUS] log failed: #{error.class}: #{error.message}"
            false
          end

          def context=(value)
            @mutex.synchronize { @context = normalize_payload(value || {}) }
          end

          def start_heartbeat
            return if @heartbeat_thread&.alive?

            @stop_heartbeat = false
            @heartbeat_thread = Thread.new do
              Thread.current.name = 'lvn-production-corpus-heartbeat' if
                Thread.current.respond_to?(:name=)
              loop do
                sleep HEARTBEAT_SECONDS
                break if @stop_heartbeat

                write_heartbeat
              end
            rescue StandardError => error
              log(
                'HEARTBEAT_THREAD_ERROR',
                {
                  error_class: error.class.name,
                  error_message: error.message
                },
                level: 'ERROR'
              )
            end
          end

          def stop_heartbeat
            @stop_heartbeat = true
            thread = @heartbeat_thread
            return unless thread

            thread.wakeup if thread.alive?
            thread.join(2.0)
          rescue ThreadError
            thread.join(2.0) if thread
          ensure
            @heartbeat_thread = nil
          end

          def close
            stop_heartbeat
            log('LOG_CLOSE') if @io && !@io.closed?
            @mutex.synchronize do
              @io.flush unless @io.closed?
              @io.close unless @io.closed?
            end
          rescue StandardError => error
            warn "[LVN PRODUCTION CORPUS] log close failed: #{error.class}: #{error.message}"
          end

          private

          def write_heartbeat
            context = @mutex.synchronize { @context.dup }
            locations = @worker_thread&.backtrace_locations
            stack = Array(locations).first(STACK_DEPTH).map do |location|
              path = location.absolute_path || location.path
              "#{File.basename(path.to_s)}:#{location.lineno}:in `#{location.label}'"
            end
            gc = GC.stat
            log(
              'HEARTBEAT',
              context.merge(
                worker_status: @worker_thread&.status,
                worker_stack: stack,
                gc: {
                  heap_live_slots: gc[:heap_live_slots],
                  heap_available_slots: gc[:heap_available_slots],
                  total_allocated_objects: gc[:total_allocated_objects],
                  total_freed_objects: gc[:total_freed_objects],
                  minor_gc_count: gc[:minor_gc_count],
                  major_gc_count: gc[:major_gc_count]
                }
              )
            )
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

        def run
          model = Sketchup.active_model
          original_selection = model.selection.to_a
          validate_preflight!(model, original_selection)

          root_before = model_root_signature(model)
          targets, skipped = inventory_targets(model, original_selection)
          log_path = build_log_path(model)
          FileUtils.mkdir_p(File.dirname(log_path))
          log = SyncLog.new(log_path, worker_thread: Thread.current)
          log.start_heartbeat

          puts '=' * 116
          puts ' LVN Phase 6.1 — Production Incremental Coplanar Corpus Regression'
          puts '=' * 116
          puts format('log file              : %s', log_path)
          puts format('selected entities     : %d', original_selection.length)
          puts format('qualifying solids     : %d', targets.length)
          puts 'execution path         : production LocalVertexNormalizer only'
          puts 'candidate lifetime     : fresh unique copy; enclosing operation aborted'
          puts 'source mutation        : none'
          print_skipped(skipped)
          puts '-' * 116

          log.log(
            'RUN_BEGIN',
            {
              probe: name,
              selected_entities: original_selection.length,
              qualifying_solids: targets.length,
              skipped: skipped,
              expected_corpus_size: EXPECTED_CORPUS_SIZE,
              model_path: model.respond_to?(:path) ? model.path.to_s : nil,
              ruby_version: RUBY_VERSION,
              sketchup_version:
                Sketchup.respond_to?(:version) ? Sketchup.version.to_s : nil,
              tolerance_mm: LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
              remove_coplanar_source_location:
                direct_class_method(
                  LocalVertexNormalizer,
                  :remove_coplanar_shared_edges
                ).source_location
            }
          )

          if targets.empty?
            log.log(
              'RUN_END',
              { result: 'FAIL', reason: 'no_qualifying_solid' },
              level: 'ERROR'
            )
            puts 'result                : FAIL (no qualifying selected solid)'
            return false
          end

          results = []
          stop_reason = nil
          targets.each_with_index do |target, index|
            result = run_target(model, target, index, targets.length, log)
            results << result
            print_progress(result, index + 1, targets.length)

            next if result[:source_restored] && result[:root_restored]

            stop_reason = :restoration_failure
            log.log(
              'RUN_STOP',
              {
                reason: stop_reason,
                target: target_metadata(target),
                result: result
              },
              level: 'ERROR'
            )
            break
          end

          selection_restored = restore_selection(model, original_selection)
          root_restored = model_root_signature(model) == root_before
          tested_all = results.length == targets.length
          passed = results.count { |result| result[:passed] }
          failed = results.length - passed
          success =
            stop_reason.nil? &&
            tested_all &&
            failed.zero? &&
            selection_restored &&
            root_restored

          summary = {
            result: success ? 'PASS' : 'FAIL',
            qualifying_solids: targets.length,
            tested_solids: results.length,
            passed_solids: passed,
            failed_solids: failed,
            stop_reason: stop_reason,
            model_root_restored: root_restored,
            selection_restored: selection_restored
          }
          log.log('RUN_END', summary, level: success ? 'INFO' : 'ERROR')

          puts '-' * 116
          puts format('tested solids         : %d/%d', results.length, targets.length)
          puts format('passed/failed         : %d/%d', passed, failed)
          puts format('model root restored   : %s', root_restored)
          puts format('selection restored    : %s', selection_restored)
          puts format('result                : %s', success ? 'PASS' : 'FAIL')
          puts format('log file              : %s', log_path)
          puts '=' * 116
          success
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
          warn "[LVN PRODUCTION CORPUS] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(20).join("\n")
          false
        ensure
          begin
            restore_selection(model, original_selection) if
              defined?(model) && model &&
              defined?(original_selection) && original_selection
          rescue StandardError => restore_error
            log&.log(
              'FINAL_SELECTION_RESTORE_ERROR',
              {
                error_class: restore_error.class.name,
                error_message: restore_error.message
              },
              level: 'ERROR'
            )
          end
          log&.close
        end

        def validate_preflight!(model, selection)
          if selection.empty?
            raise <<~MESSAGE.strip
              LVN production corpus probe requires the selected corpus before
              loading. Select the LVN-unprocessed solids and run this file once
              in a fresh SketchUp session.
            MESSAGE
          end

          core = ULOL::Indoor3DGmlModeler::IndoorCore
          loaded = DEV_CONSTANTS.select { |name| core.const_defined?(name, false) }
          unless loaded.empty?
            raise <<~MESSAGE.strip
              LVN production corpus probe requires a fresh SketchUp session.
              Dev probe constants are already loaded: #{loaded.inspect}
            MESSAGE
          end

          method = direct_class_method(
            LocalVertexNormalizer,
            :remove_coplanar_shared_edges
          )
          path = Array(method.source_location).first.to_s.tr('\\', '/')
          unless path.end_with?(
            '/indoor3d/application/local_vertex_normalizer/coplanar_shared_edge_groups.rb'
          )
            raise(
              "Production coplanar method is not installed: " \
              "#{method.owner} #{method.source_location.inspect}"
            )
          end

          return if model.respond_to?(:start_operation) &&
                    model.respond_to?(:abort_operation)

          raise 'SketchUp model operation API is unavailable'
        end

        def inventory_targets(model, selection)
          skipped = Hash.new(0)
          targets = []
          selection.each do |entity|
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

            counts = geometry_counts(entity)
            if counts[:faces].zero? || counts[:edges].zero?
              skipped[:empty_geometry] += 1
              next
            end

            targets << {
              entity: entity,
              pid: persistent_id(entity),
              label: entity_label(entity),
              counts: counts
            }
          rescue StandardError
            skipped[:inventory_error] += 1
          end
          [targets, skipped]
        end

        def run_target(model, target, index, total, log)
          source = target[:entity]
          source_signature = brep_signature(source)
          root_before = model_root_signature(model)
          metadata = target_metadata(target).merge(index: index + 1, total: total)
          log.context = metadata.merge(stage: 'starting')
          log.log('SOLID_BEGIN', metadata)

          result = {
            index: index + 1,
            total: total,
            label: target[:label],
            pid: target[:pid],
            source_counts: target[:counts],
            passed: false,
            source_restored: false,
            root_restored: false
          }
          operation_started = false

          begin
            operation_started = model.start_operation(
              "LVN production corpus PID=#{target[:pid]}",
              true
            )
            raise 'SketchUp start_operation returned false' if operation_started == false

            candidate = copy_source_instance(source, model, target[:pid])
            result[:candidate_fresh] = brep_signature(candidate) == source_signature
            result[:definition_isolated] = candidate.definition != source.definition
            log.context = metadata.merge(stage: 'normalizing')

            started = monotonic_time
            report = LocalVertexNormalizer.normalize(
              candidate,
              LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
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
            result[:candidate_normalized] = LocalVertexNormalizer.normalized?(
              candidate,
              LocalVertexNormalizer::DEFAULT_TOLERANCE_MM
            )
            result[:normalization_strategy] = report[:normalization_strategy] if
              report.is_a?(Hash)
            result[:max_grid_residual_mm] = report[:max_grid_residual_mm] if
              report.is_a?(Hash)
            result[:counts] = geometry_counts(candidate)
            result[:signature] = brep_signature(candidate)
            result[:volume_mm3] = solid_volume_mm3(candidate)
            result[:passed] =
              result[:candidate_fresh] &&
              result[:definition_isolated] &&
              result[:report_complete] &&
              result[:candidate_manifold] &&
              result[:candidate_normalized]
          rescue Exception => error # rubocop:disable Lint/RescueException
            result[:error_class] = error.class.name
            result[:error_message] = error.message
            result[:backtrace] = Array(error.backtrace).first(20)
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

          result[:source_restored] = brep_signature(source) == source_signature
          result[:root_restored] = model_root_signature(model) == root_before
          result[:passed] &&= result[:source_restored] && result[:root_restored]
          log.log('SOLID_END', result, level: result[:passed] ? 'INFO' : 'ERROR')
          result
        ensure
          log.context = {}
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

          candidate.name = "LVN_PRODUCTION_CORPUS_TEMP_#{pid}" if
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
            manifold: entity.respond_to?(:manifold?) ? entity.manifold? : nil
          }
        end

        def brep_signature(entity)
          edges = entity.definition.entities.grep(Sketchup::Edge).select(&:valid?).map do |edge|
            canonical_edge(
              exact_point_key(edge.start.position),
              exact_point_key(edge.end.position)
            )
          end.sort
          faces = entity.definition.entities.grep(Sketchup::Face).select(&:valid?).map do |face|
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

        def solid_volume_mm3(entity)
          entity.volume.to_f * (LocalVertexNormalizer::MM_PER_INCH**3)
        rescue StandardError
          nil
        end

        def model_root_signature(model)
          model.entities.to_a.filter_map do |entity|
            next unless entity.respond_to?(:valid?) && entity.valid?

            [entity.class.name, persistent_id(entity)]
          end.sort_by { |entry| [entry[0], entry[1]] }
        end

        def restore_selection(model, entities)
          model.selection.clear
          expected = []
          Array(entities).each do |entity|
            next unless entity.respond_to?(:valid?) && entity.valid?

            model.selection.add(entity)
            expected << persistent_id(entity)
          end
          actual = model.selection.to_a.map { |entity| persistent_id(entity) }
          actual.sort == expected.sort
        rescue StandardError
          false
        end

        def direct_class_method(klass, name)
          method = klass.instance_method(name)
          chain = []
          while method
            chain << [method.owner.to_s, method.source_location]
            return method if method.owner == klass

            method = method.super_method
          end
          raise(
            "Could not resolve #{klass}##{name} below prepended wrappers: " \
            "#{chain.inspect}"
          )
        end

        def persistent_id(entity)
          if entity.respond_to?(:persistent_id)
            entity.persistent_id.to_i
          else
            entity.object_id
          end
        end

        def entity_label(entity)
          name = entity.respond_to?(:name) ? entity.name.to_s : ''
          name = entity.class.name if name.empty?
          "#{name}[PID=#{persistent_id(entity)}]"
        end

        def target_metadata(target)
          {
            label: target[:label],
            pid: target[:pid],
            faces: target.dig(:counts, :faces),
            edges: target.dig(:counts, :edges),
            vertices: target.dig(:counts, :vertices),
            manifold: target.dig(:counts, :manifold)
          }
        end

        def build_log_path(model)
          directory = if model.respond_to?(:path) && !model.path.to_s.empty?
                        File.dirname(model.path.to_s)
                      else
                        Dir.tmpdir
                      end
          timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
          File.join(
            directory,
            "lvn_corpus_production_regression_#{timestamp}_pid#{Process.pid}.log"
          )
        end

        def print_progress(result, index, total)
          return unless !result[:passed] || index == 1 || index == total ||
                        (index % 50).zero?

          puts format(
            '[%4d/%4d] %-4s %8.3fs %s',
            index,
            total,
            result[:passed] ? 'PASS' : 'FAIL',
            result[:elapsed_s].to_f,
            result[:label]
          )
          if result[:error_class]
            puts format(
              '             %s: %s',
              result[:error_class],
              result[:error_message]
            )
          end
        end

        def print_skipped(skipped)
          active = skipped.select { |_key, count| count.to_i.positive? }
          puts format('skipped                : %s', active.empty? ? 'none' : active.inspect)
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::
  LvnCorpusProductionRegressionProbe.run
