# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'stringio'
require 'tmpdir'
require 'time'

core = ULOL::Indoor3DGmlModeler::IndoorCore
normalizer_class = core::LocalVertexNormalizer

# A same-process rerun would capture an already patched method as the reference
# and contaminate the benchmark. Require a fresh SketchUp Ruby VM instead.
already_loaded = %i[
  LvnCoplanarIncrementalTopologyProbe
  LvnBridgeNearestFirstProbe
  LvnBridgeBlockedEarProbe
  LvnBridgeBlockedEarRecoveryProbe
  LvnLargeSolidDetailedLogProbe
  LvnLargeSolidFaceDetailLogProbe
].any? { |name| core.const_defined?(name, false) }
if already_loaded
  raise <<~MESSAGE.strip
    LVN corpus A/B probe requires a fresh SketchUp session. Completely exit
    SketchUp, reopen the LVN-unprocessed original model, select the corpus, and
    load this launcher once.
  MESSAGE
end

reference_remove_coplanar =
  normalizer_class.instance_method(:remove_coplanar_shared_edges)
reference_source_location = reference_remove_coplanar.source_location

# Install the dev-only optimized stack without triggering its default selected
# large-solid diagnostic. All user selection and console streams are restored.
dependency_model = Sketchup.active_model
dependency_selection = dependency_model.selection.to_a
dependency_stdout = $stdout
dependency_stderr = $stderr
begin
  dependency_model.selection.clear
  $stdout = StringIO.new
  $stderr = StringIO.new
  load File.join(__dir__, 'lvn_coplanar_incremental_topology_probe_v2.rb')
ensure
  $stdout = dependency_stdout
  $stderr = dependency_stderr
  dependency_model.selection.clear
  dependency_selection.each do |entity|
    dependency_model.selection.add(entity) if
      entity.respond_to?(:valid?) && entity.valid?
  end
end

optimized_remove_coplanar =
  normalizer_class.instance_method(:remove_coplanar_shared_edges)
optimized_source_location = optimized_remove_coplanar.source_location
if optimized_source_location == reference_source_location
  raise 'Incremental coplanar implementation was not installed'
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # Phase 6 dev-only corpus regression runner.
      #
      # For ordinary solids (F <= 250), the only A/B variable is
      # remove_coplanar_shared_edges:
      #   A = captured production implementation
      #   B = incremental topology implementation
      # Bridge/ear probes are common to both paths so this isolates Phase 5.4.
      #
      # For larger solids, A is intentionally skipped because production's
      # per-group full geometry scans are already known to be impractical. B
      # still performs exact full geometry_counts references every 100 groups
      # and at every pass boundary; any mismatch raises and fails the solid.
      #
      # Every candidate is a fresh unique copy inside an aborted outer
      # operation. Source geometry, model-root inventory and selection must be
      # restored exactly.
      module LvnCorpusAbRegressionProbe
        AB_MAX_FACES = 250
        HEARTBEAT_SECONDS = 30.0
        STACK_DEPTH = 12
        RESIDUAL_EPSILON_MM = 1.0e-9
        COMPARISON_COUNT_KEYS = %i[faces edges vertices manifold].freeze
        PROBE_EVENT_PREFIX = 'COPLANAR_INCREMENTAL_'

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

          def log(event, data = nil, level: 'INFO', **fields)
            data = {} if data.nil?
            data = { value: data } unless data.is_a?(Hash)
            payload = normalize_payload(data.merge(fields))
            line = format(
              '[%s] +%0.3fs %-5s %-38s %s\n',
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
            warn "[LVN CORPUS A/B] log write failed: #{error.class}: #{error.message}"
            false
          end

          def context=(value)
            @mutex.synchronize { @context = normalize_payload(value || {}) }
          end

          def start_heartbeat
            return if @heartbeat_thread&.alive?

            @stop_heartbeat = false
            @heartbeat_thread = Thread.new do
              Thread.current.name = 'lvn-corpus-ab-heartbeat' if
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
            warn "[LVN CORPUS A/B] log close failed: #{error.class}: #{error.message}"
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

        # Bridge the existing probe logging to the corpus file while suppressing
        # detailed per-method and per-ear chatter. The incremental implementation
        # emits exact-reference results through this context.
        class FilteredProbeContext
          attr_reader :summary

          def initialize(log, solid:, mode:)
            @log = log
            @solid = solid
            @mode = mode
            @summary = {
              begin_count: 0,
              reference_match_count: 0,
              reference_mismatch_count: 0,
              progress_count: 0,
              end_count: 0,
              error_count: 0,
              end_metrics: nil
            }
          end

          def log(event, data = {}, level: 'INFO')
            name = event.to_s
            return true unless name.start_with?(PROBE_EVENT_PREFIX)

            case name
            when 'COPLANAR_INCREMENTAL_BEGIN'
              @summary[:begin_count] += 1
            when 'COPLANAR_INCREMENTAL_REFERENCE_MATCH'
              @summary[:reference_match_count] += 1
            when 'COPLANAR_INCREMENTAL_REFERENCE_MISMATCH'
              @summary[:reference_mismatch_count] += 1
            when 'COPLANAR_INCREMENTAL_PROGRESS'
              @summary[:progress_count] += 1
            when 'COPLANAR_INCREMENTAL_END'
              @summary[:end_count] += 1
              @summary[:end_metrics] = data
            when 'COPLANAR_INCREMENTAL_ERROR'
              @summary[:error_count] += 1
            end
            @log.log(
              name,
              data.merge(solid: @solid, mode: @mode),
              level: level
            )
          end

          def with_stage(_name, _metadata = nil, **_kwargs)
            yield
          end
        end

        class << self
          attr_accessor :reference_remove_coplanar,
                        :optimized_remove_coplanar,
                        :reference_source_location,
                        :optimized_source_location
        end

        module_function

        def run
          model = Sketchup.active_model
          phase1 = LvnPolygonPreservingFeasibilityProbe
          base = LvnPolygonCandidateReconstructionProbe
          fallback = LvnPolygonWholeSolidFallbackProbe
          original_selection = model.selection.to_a
          root_before = fallback.model_root_signature(model)
          log_path = build_log_path(model)
          FileUtils.mkdir_p(File.dirname(log_path))
          log = SyncLog.new(log_path, worker_thread: Thread.current)
          log.start_heartbeat

          puts '=' * 116
          puts ' LVN Phase 6 — Corpus Coplanar Incremental Topology A/B Regression'
          puts '=' * 116
          puts format('log file              : %s', log_path)
          puts format('selected entities     : %d', original_selection.length)
          puts format('A/B Face limit        : F <= %d', AB_MAX_FACES)
          puts 'A path                : production remove_coplanar_shared_edges'
          puts 'B path                : incremental topology + exact periodic references'
          puts 'large-solid policy    : B only; A skipped because full scans are impractical'
          puts 'source mutation       : none; every candidate operation is aborted'
          puts '-' * 116

          targets, skipped = inventory_targets(model, original_selection, phase1, base)
          ab_count = targets.count { |target| target[:counts][:faces] <= AB_MAX_FACES }
          optimized_only_count = targets.length - ab_count
          log.log(
            'RUN_BEGIN',
            {
              probe: name,
              selected_entities: original_selection.length,
              qualifying_solids: targets.length,
              ab_max_faces: AB_MAX_FACES,
              ab_solids: ab_count,
              optimized_only_solids: optimized_only_count,
              skipped: skipped,
              model_path: model.respond_to?(:path) ? model.path.to_s : nil,
              ruby_version: RUBY_VERSION,
              sketchup_version:
                Sketchup.respond_to?(:version) ? Sketchup.version.to_s : nil,
              tolerance_mm: phase1::DEFAULT_TOLERANCE_MM,
              reference_source_location: reference_source_location,
              optimized_source_location: optimized_source_location
            }
          )

          puts format('qualifying solids     : %d', targets.length)
          puts format('direct A/B solids     : %d', ab_count)
          puts format('optimized-only solids : %d', optimized_only_count)
          print_skipped(skipped)
          puts '-' * 116

          if targets.empty?
            log.log('RUN_END', { result: 'FAIL', reason: 'no_qualifying_solid' }, level: 'ERROR')
            puts 'result                : FAIL (no qualifying selected solid)'
            puts '=' * 116
            return false
          end

          results = []
          stop_reason = nil
          targets.each_with_index do |target, index|
            result = run_target(
              model,
              target,
              index,
              targets.length,
              phase1,
              base,
              fallback,
              log
            )
            results << result
            unless result[:source_restored] && result[:root_restored]
              stop_reason = :restoration_failure
              log.log(
                'RUN_STOP',
                {
                  reason: stop_reason,
                  target: inventory_entry(target),
                  result: result
                },
                level: 'ERROR'
              )
              break
            end
          end

          selection_restored = fallback.restore_selection(model, original_selection)
          root_restored = fallback.model_root_signature(model) == root_before
          tested_all = results.length == targets.length
          passed = results.count { |result| result[:passed] }
          failed = results.length - passed
          ab_results = results.select { |result| result[:mode] == :ab }
          optimized_only = results.select { |result| result[:mode] == :optimized_only }
          regressions = ab_results.count { |result| result[:regression] }
          ab_mismatches = ab_results.count { |result| !result[:equivalent] }
          optimized_failures = results.count do |result|
            !result.dig(:optimized, :passed)
          end
          success =
            stop_reason.nil? &&
            tested_all &&
            failed.zero? &&
            regressions.zero? &&
            ab_mismatches.zero? &&
            optimized_failures.zero? &&
            selection_restored &&
            root_restored

          summary = {
            result: success ? 'PASS' : 'FAIL',
            qualifying_solids: targets.length,
            tested_solids: results.length,
            passed_solids: passed,
            failed_solids: failed,
            ab_solids: ab_results.length,
            optimized_only_solids: optimized_only.length,
            regressions: regressions,
            ab_mismatches: ab_mismatches,
            optimized_failures: optimized_failures,
            stop_reason: stop_reason,
            model_root_restored: root_restored,
            selection_restored: selection_restored
          }
          log.log('RUN_END', summary, level: success ? 'INFO' : 'ERROR')

          puts '-' * 116
          puts format('tested solids         : %d/%d', results.length, targets.length)
          puts format('passed/failed         : %d/%d', passed, failed)
          puts format('A/B mismatches        : %d', ab_mismatches)
          puts format('regressions           : %d', regressions)
          puts format('optimized failures    : %d', optimized_failures)
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
          warn "[LVN CORPUS A/B] #{error.class}: #{error.message}"
          warn Array(error.backtrace).first(20).join("\n")
          false
        ensure
          begin
            install_remove_coplanar(:optimized)
          rescue StandardError => restore_error
            log&.log(
              'METHOD_RESTORE_ERROR',
              {
                error_class: restore_error.class.name,
                error_message: restore_error.message
              },
              level: 'ERROR'
            )
          end
          begin
            LvnLargeSolidDetailedLogProbe.active_context = nil if
              defined?(LvnLargeSolidDetailedLogProbe)
          rescue StandardError
            nil
          end
          begin
            fallback.restore_selection(model, original_selection) if
              defined?(fallback) && fallback && defined?(model) && model &&
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

        def run_target(model, target, index, total, phase1, base, fallback, log)
          source = target[:entity]
          source_signature = base.brep_signature(source)
          target_root_before = fallback.model_root_signature(model)
          metadata = inventory_entry(target).merge(index: index + 1, total: total)
          mode = target[:counts][:faces] <= AB_MAX_FACES ? :ab : :optimized_only
          started = monotonic_time
          log.context = metadata.merge(mode: mode, stage: 'solid')
          log.log('SOLID_BEGIN', metadata.merge(mode: mode))

          reference = nil
          if mode == :ab
            reference = run_mode(
              model,
              source,
              source_signature,
              target,
              :reference,
              phase1,
              base,
              fallback,
              log
            )
          end
          optimized = run_mode(
            model,
            source,
            source_signature,
            target,
            :optimized,
            phase1,
            base,
            fallback,
            log
          )

          comparison = reference ? compare_results(reference, optimized) : {
            equivalent: optimized[:passed],
            regression: !optimized[:passed],
            mismatches: optimized[:passed] ? {} : { optimized: 'failed' }
          }
          source_restored = base.brep_signature(source) == source_signature
          root_restored = fallback.model_root_signature(model) == target_root_before
          passed =
            optimized[:passed] &&
            source_restored &&
            root_restored &&
            (reference.nil? || (reference[:passed] && comparison[:equivalent]))
          result = {
            index: index + 1,
            total: total,
            label: target[:label],
            pid: target[:pid],
            faces: target[:counts][:faces],
            mode: mode,
            elapsed_s: monotonic_time - started,
            passed: passed,
            equivalent: comparison[:equivalent],
            regression: comparison[:regression],
            mismatches: comparison[:mismatches],
            reference: compact_mode_result(reference),
            optimized: compact_mode_result(optimized),
            source_restored: source_restored,
            root_restored: root_restored
          }
          log.log('SOLID_END', result, level: passed ? 'INFO' : 'ERROR')

          reference_time = reference ? format('%0.3fs', reference[:elapsed_s]) : 'SKIP'
          optimized_time = format('%0.3fs', optimized[:elapsed_s])
          puts format(
            '[%04d/%04d] %-4s F=%-5d PID=%-10s A=%-10s B=%-10s %s',
            index + 1,
            total,
            passed ? 'PASS' : 'FAIL',
            target[:counts][:faces],
            target[:pid],
            reference_time,
            optimized_time,
            target[:label]
          )
          result
        rescue Exception => error # rubocop:disable Lint/RescueException
          result = {
            index: index + 1,
            total: total,
            label: target[:label],
            pid: target[:pid],
            faces: target[:counts][:faces],
            mode: mode,
            elapsed_s: monotonic_time - started,
            passed: false,
            equivalent: false,
            regression: true,
            mismatches: { target_error: "#{error.class}: #{error.message}" },
            reference: compact_mode_result(reference),
            optimized: compact_mode_result(optimized),
            source_restored: base.brep_signature(source) == source_signature,
            root_restored: fallback.model_root_signature(model) == target_root_before,
            error_class: error.class.name,
            error_message: error.message
          }
          log.log('SOLID_END', result, level: 'ERROR')
          puts format(
            '[%04d/%04d] FAIL F=%-5d PID=%-10s %s (%s: %s)',
            index + 1,
            total,
            target[:counts][:faces],
            target[:pid],
            target[:label],
            error.class,
            error.message
          )
          result
        ensure
          log.context = {}
        end

        def run_mode(
          model,
          source,
          source_signature,
          target,
          mode,
          phase1,
          base,
          fallback,
          log
        )
          root_before = fallback.model_root_signature(model)
          metadata = inventory_entry(target).merge(mode: mode)
          log.context = metadata.merge(stage: 'normalize')
          log.log('MODE_BEGIN', metadata)
          started = monotonic_time
          operation_started = false
          candidate = nil
          report = nil
          error = nil
          result = nil
          probe_context = FilteredProbeContext.new(
            log,
            solid: inventory_entry(target),
            mode: mode
          )

          begin
            install_remove_coplanar(mode)
            LvnLargeSolidDetailedLogProbe.active_context = probe_context
            operation_started = model.start_operation(
              "LVN corpus #{mode} PID=#{target[:pid]}",
              true
            )
            raise 'SketchUp start_operation returned false' if operation_started == false

            candidate = fallback.copy_source_instance(
              source,
              model,
              phase1,
              mode == :reference ? 'LVN_CORPUS_A_TEMP' : 'LVN_CORPUS_B_TEMP'
            )
            candidate_fresh = base.brep_signature(candidate) == source_signature
            definition_isolated = candidate.definition != source.definition
            raise 'Fresh candidate B-rep differs from source' unless candidate_fresh
            raise 'Candidate definition is not isolated' unless definition_isolated

            report = LocalVertexNormalizer.normalize(
              candidate,
              phase1::DEFAULT_TOLERANCE_MM,
              manage_operation: false
            )
            candidate_manifold =
              candidate.valid? &&
              candidate.respond_to?(:manifold?) &&
              candidate.manifold? == true
            candidate_normalized = LocalVertexNormalizer.normalized?(
              candidate,
              phase1::DEFAULT_TOLERANCE_MM
            )
            report_complete =
              report.is_a?(Hash) &&
              report[:normalization_complete] == true &&
              report[:manifold] == true
            counts = base.geometry_counts(candidate)
            signature = base.brep_signature(candidate)
            volume_mm3 = base.solid_volume_mm3(candidate)
            result = {
              mode: mode,
              passed:
                candidate_fresh &&
                definition_isolated &&
                report_complete &&
                candidate_manifold &&
                candidate_normalized,
              candidate_fresh: candidate_fresh,
              definition_isolated: definition_isolated,
              report_complete: report_complete,
              candidate_manifold: candidate_manifold,
              candidate_normalized: candidate_normalized,
              normalization_strategy:
                report.is_a?(Hash) ? report[:normalization_strategy] : nil,
              max_grid_residual_mm:
                report.is_a?(Hash) ? report[:max_grid_residual_mm] : nil,
              counts: counts,
              signature: signature,
              volume_mm3: volume_mm3,
              coplanar: probe_context.summary
            }
          rescue Exception => caught # rubocop:disable Lint/RescueException
            error = caught
            result ||= {
              mode: mode,
              passed: false,
              coplanar: probe_context.summary
            }
            result[:error_class] = caught.class.name
            result[:error_message] = caught.message
            result[:backtrace] = Array(caught.backtrace).first(20)
          ensure
            LvnLargeSolidDetailedLogProbe.active_context = nil
            if operation_started
              begin
                aborted = model.abort_operation
                raise 'SketchUp abort_operation returned false' if aborted == false
              rescue Exception => abort_error # rubocop:disable Lint/RescueException
                error ||= abort_error
                result ||= { mode: mode, passed: false, coplanar: probe_context.summary }
                result[:passed] = false
                result[:abort_error_class] = abort_error.class.name
                result[:abort_error_message] = abort_error.message
              end
            end
          end

          result[:elapsed_s] = monotonic_time - started
          result[:source_restored] = base.brep_signature(source) == source_signature
          result[:root_restored] = fallback.model_root_signature(model) == root_before
          result[:passed] &&= result[:source_restored] && result[:root_restored]
          result[:error_class] ||= error&.class&.name
          result[:error_message] ||= error&.message
          log.log('MODE_END', compact_mode_result(result), level: result[:passed] ? 'INFO' : 'ERROR')
          result
        ensure
          LvnLargeSolidDetailedLogProbe.active_context = nil
        end

        def compare_results(reference, optimized)
          mismatches = {}
          mismatches[:reference_passed] = [reference[:passed], optimized[:passed]] unless
            reference[:passed] == optimized[:passed]

          if reference[:passed] && optimized[:passed]
            reference_counts = comparison_counts(reference[:counts])
            optimized_counts = comparison_counts(optimized[:counts])
            mismatches[:counts] = [reference_counts, optimized_counts] unless
              reference_counts == optimized_counts
            mismatches[:signature] = [reference[:signature], optimized[:signature]] unless
              reference[:signature] == optimized[:signature]
            mismatches[:normalization_strategy] = [
              reference[:normalization_strategy],
              optimized[:normalization_strategy]
            ] unless reference[:normalization_strategy] == optimized[:normalization_strategy]
            residual_a = reference[:max_grid_residual_mm].to_f
            residual_b = optimized[:max_grid_residual_mm].to_f
            if (residual_a - residual_b).abs > RESIDUAL_EPSILON_MM
              mismatches[:max_grid_residual_mm] = [residual_a, residual_b]
            end
          end

          {
            equivalent: reference[:passed] && optimized[:passed] && mismatches.empty?,
            regression: reference[:passed] &&
              (!optimized[:passed] || !mismatches.empty?),
            mismatches: mismatches
          }
        end

        def compact_mode_result(result)
          return nil unless result

          {
            mode: result[:mode],
            passed: result[:passed],
            elapsed_s: result[:elapsed_s],
            candidate_fresh: result[:candidate_fresh],
            definition_isolated: result[:definition_isolated],
            report_complete: result[:report_complete],
            candidate_manifold: result[:candidate_manifold],
            candidate_normalized: result[:candidate_normalized],
            normalization_strategy: result[:normalization_strategy],
            max_grid_residual_mm: result[:max_grid_residual_mm],
            counts: comparison_counts(result[:counts]),
            signature: result[:signature],
            volume_mm3: result[:volume_mm3],
            coplanar: result[:coplanar],
            source_restored: result[:source_restored],
            root_restored: result[:root_restored],
            error_class: result[:error_class],
            error_message: result[:error_message]
          }
        end

        def comparison_counts(counts)
          return nil unless counts.is_a?(Hash)

          COMPARISON_COUNT_KEYS.each_with_object({}) do |key, result|
            result[key] = counts[key]
          end
        end

        def install_remove_coplanar(mode)
          method = case mode
                   when :reference then reference_remove_coplanar
                   when :optimized then optimized_remove_coplanar
                   else raise ArgumentError, "Unknown coplanar mode: #{mode.inspect}"
                   end
          raise "Missing #{mode} remove_coplanar_shared_edges method" unless method

          LocalVertexNormalizer.class_eval do
            define_method(:remove_coplanar_shared_edges, method)
            private :remove_coplanar_shared_edges
          end
          true
        end

        def inventory_targets(model, selection, phase1, base)
          skipped = Hash.new(0)
          targets = []
          selection.each do |entity|
            unless entity.respond_to?(:valid?) && entity.valid?
              skipped[:invalid_entity] += 1
              next
            end
            unless entity.parent == model
              skipped[:not_top_level] += 1
              next
            end
            unless entity.respond_to?(:definition) && entity.definition&.valid?
              skipped[:invalid_definition] += 1
              next
            end
            unless entity.respond_to?(:manifold?) && entity.manifold? == true
              skipped[:not_manifold] += 1
              next
            end

            counts = base.geometry_counts(entity)
            targets << {
              entity: entity,
              label: safe_label(phase1, entity),
              pid: entity_identity(entity),
              counts: counts
            }
          rescue StandardError => error
            skipped[:inventory_error] += 1
            skipped[:inventory_error_samples] ||= []
            if skipped[:inventory_error_samples].length < 20
              skipped[:inventory_error_samples] << {
                entity: entity.to_s,
                error: "#{error.class}: #{error.message}"
              }
            end
          end

          targets.sort_by! do |target|
            faces = target[:counts][:faces].to_i
            [faces > AB_MAX_FACES ? 1 : 0, faces, target[:pid].to_i]
          end
          [targets, skipped]
        end

        def inventory_entry(target)
          {
            label: target[:label],
            pid: target[:pid],
            faces: target[:counts][:faces],
            edges: target[:counts][:edges],
            vertices: target[:counts][:vertices],
            manifold: target[:counts][:manifold]
          }
        end

        def print_skipped(skipped)
          meaningful = skipped.reject do |key, value|
            key == :inventory_error_samples || value.to_i.zero?
          end
          return if meaningful.empty?

          puts 'skipped:'
          meaningful.each do |key, value|
            puts format('  %-24s %d', key, value)
          end
        end

        def build_log_path(model)
          model_path = model.respond_to?(:path) ? model.path.to_s : ''
          base_dir = if !model_path.empty? && File.directory?(File.dirname(model_path))
                       File.dirname(model_path)
                     else
                       Dir.tmpdir
                     end
          directory = File.join(base_dir, 'LVN_Diagnostic_Logs')
          filename = format(
            'lvn_corpus_ab_regression_%s_pid%d.log',
            Time.now.strftime('%Y%m%d_%H%M%S'),
            Process.pid
          )
          File.join(directory, filename)
        end

        def safe_label(phase1, entity)
          phase1.entity_label(entity)
        rescue StandardError
          entity.to_s
        end

        def entity_identity(entity)
          entity.respond_to?(:persistent_id) ? entity.persistent_id.to_i : entity.object_id
        end

        def monotonic_time
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end

probe = ULOL::Indoor3DGmlModeler::IndoorCore::LvnCorpusAbRegressionProbe
probe.reference_remove_coplanar = reference_remove_coplanar
probe.optimized_remove_coplanar = optimized_remove_coplanar
probe.reference_source_location = reference_source_location
probe.optimized_source_location = optimized_source_location
probe.run
