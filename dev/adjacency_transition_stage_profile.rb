# frozen_string_literal: true

# One-shot profiler for the normal bulk Adjacency/Transition synchronization path.
#
# core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
# root = File.expand_path('..', File.dirname(core_file))
# load File.join(root, 'dev', 'adjacency_transition_stage_profile.rb')
#
# Then run the normal Local Grid CellSpace Create once.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      unless const_defined?(:AdjacencyTransitionStageProfile, false)
        module AdjacencyTransitionStageProfile
          CLOCK = Process::CLOCK_MONOTONIC
          LOG_PATH = File.join(
            ENV['TEMP'] || ENV['TMP'] || '.',
            'IndoorGML_Adjacency_Transition_Stage_Profile.log'
          ).freeze

          class << self
            def install!
              raise 'AdjacencyService is unavailable' unless defined?(IndoorCore::AdjacencyService)
              raise 'Utils::Geometry is unavailable' unless defined?(Utils::Geometry)

              service = IndoorCore::AdjacencyService
              service.prepend(ServiceProbe) unless service.ancestors.include?(ServiceProbe)

              geometry_singleton = Utils::Geometry.singleton_class
              geometry_singleton.prepend(GeometryProbe) unless geometry_singleton.ancestors.include?(GeometryProbe)

              arm!
              puts '[ADJACENCY/TRANSITION STAGE PROFILE] armed for the next synchronize_all'
              puts "Log: #{LOG_PATH}"
              true
            rescue StandardError => e
              warn_error('install', e)
              false
            end

            def arm!
              @armed = true
              true
            end

            def consume_arm!
              return false unless @armed == true

              @armed = false
              true
            end

            def active?
              @active == true
            end

            def begin_run!
              @mutex ||= Mutex.new
              @stats = {}
              @counts = {}
              @active = true
              @run_started_at = now
              true
            end

            def finish_run!(service, result, error = nil)
              elapsed = @run_started_at ? now - @run_started_at : 0.0
              @active = false
              report = build_report(service, result, elapsed, error)
              print_report(report)
              write_log(report)
              report
            rescue StandardError => profile_error
              warn_error('finish', profile_error)
              nil
            ensure
              @active = false
            end

            def measure(name)
              return yield unless active?

              started = now
              result = yield
              result
            ensure
              record(name, now - started) if started
            end

            def record(name, elapsed)
              @mutex ||= Mutex.new
              @mutex.synchronize do
                stat = (@stats ||= {})[name] ||= { calls: 0, total: 0.0, max: 0.0 }
                stat[:calls] += 1
                stat[:total] += elapsed
                stat[:max] = elapsed if elapsed > stat[:max]
              end
            end

            def set_count(name, value)
              @mutex ||= Mutex.new
              @mutex.synchronize { (@counts ||= {})[name] = value.to_i }
            end

            def increment_count(name)
              @mutex ||= Mutex.new
              @mutex.synchronize { (@counts ||= {})[name] = (@counts[name] || 0) + 1 }
            end

            def stat(name)
              (@stats || {})[name] || { calls: 0, total: 0.0, max: 0.0 }
            end

            def count(name)
              (@counts || {})[name].to_i
            end

            def now
              Process.clock_gettime(CLOCK)
            end

            def build_report(service, result, elapsed, error)
              entries = count(:entries)
              possible_pairs = entries > 1 ? (entries * (entries - 1)) / 2 : 0
              candidates = count(:candidate_pairs)
              pair_results = count(:pair_results)
              metrics = service.respond_to?(:last_metrics) ? service.last_metrics : {}

              {
                error: error,
                result: result,
                elapsed: elapsed,
                service_total: metrics[:total_duration].to_f,
                service_detailed: metrics[:adjacency_detailed_computation].to_f,
                service_candidate_count: metrics[:pair_comparison_count].to_i,
                entries: entries,
                possible_pairs: possible_pairs,
                candidates: candidates,
                pair_results: pair_results,
                cull_percent: possible_pairs.zero? ? 0.0 : (1.0 - candidates.to_f / possible_pairs) * 100.0,
                stats: (@stats || {}).transform_values(&:dup),
                counts: (@counts || {}).dup
              }
            end

            def print_report(report)
              lines = report_lines(report)
              puts
              lines.each { |line| puts line }
              puts "Log: #{LOG_PATH}"
            end

            def write_log(report)
              File.write(LOG_PATH, report_lines(report).join("\n") + "\n")
            rescue StandardError => e
              warn_error('log write', e)
            end

            def report_lines(report)
              snapshot_entries = report_stat(report, :snapshot_entries)
              geometry_snapshot = report_stat(report, :geometry_snapshot)
              pair_compute = report_stat(report, :compute_pair_results)
              broad_phase = report_stat(report, :candidate_pair_indices)
              pair_chunk = report_stat(report, :compute_pair_chunk)
              detailed_axis = report_stat(report, :geometry_axis_from_snapshots)
              apply_results = report_stat(report, :apply_pair_results)
              stale_keys = report_stat(report, :stale_pair_keys)
              transition_build = report_stat(report, :transition_builder)
              transition_erase = report_stat(report, :transition_eraser)

              lines = []
              lines << '=' * 112
              lines << 'Adjacency / Transition Stage Profile'
              lines << '=' * 112
              lines << "Entries                    : #{report[:entries]}"
              lines << "All possible pairs         : #{report[:possible_pairs]}"
              lines << "Broad-phase candidates     : #{report[:candidates]}"
              lines << "Confirmed adjacency pairs  : #{report[:pair_results]}"
              lines << format('Broad-phase rejection      : %.3f%%', report[:cull_percent])
              lines << "Service pair metric        : #{report[:service_candidate_count]}"
              lines << '-' * 112
              lines << stage_line('synchronize_all wrapper', report[:elapsed], 1, report[:elapsed])
              lines << stage_line('01 snapshot entries', snapshot_entries[:total], snapshot_entries[:calls], snapshot_entries[:max])
              lines << stage_line('   geometry adjacency_snapshot', geometry_snapshot[:total], geometry_snapshot[:calls], geometry_snapshot[:max])
              lines << stage_line('02 pair computation total', pair_compute[:total], pair_compute[:calls], pair_compute[:max])
              lines << stage_line('   broad phase candidate pairs', broad_phase[:total], broad_phase[:calls], broad_phase[:max])
              lines << stage_line('   detailed pair chunk', pair_chunk[:total], pair_chunk[:calls], pair_chunk[:max])
              lines << stage_line('   geometry axis accumulated', detailed_axis[:total], detailed_axis[:calls], detailed_axis[:max])
              lines << stage_line('03 apply pair results', apply_results[:total], apply_results[:calls], apply_results[:max])
              lines << stage_line('   stale pair lookup', stale_keys[:total], stale_keys[:calls], stale_keys[:max])
              lines << stage_line('   Transition builder', transition_build[:total], transition_build[:calls], transition_build[:max])
              lines << stage_line('   Transition eraser', transition_erase[:total], transition_erase[:calls], transition_erase[:max])
              lines << '-' * 112
              lines << format('Service reported total     : %10.3f sec', report[:service_total])
              lines << format('Service reported detailed  : %10.3f sec', report[:service_detailed])

              snapshot_residual = snapshot_entries[:total] - geometry_snapshot[:total]
              compute_residual = pair_compute[:total] - broad_phase[:total] - pair_chunk[:total]
              apply_residual = apply_results[:total] - stale_keys[:total] - transition_build[:total] - transition_erase[:total]
              lifecycle_residual = report[:elapsed] - snapshot_entries[:total] - pair_compute[:total] - apply_results[:total]
              lines << format('Snapshot iteration residual: %10.3f sec', [snapshot_residual, 0.0].max)
              lines << format('Pair orchestration residual: %10.3f sec', [compute_residual, 0.0].max)
              lines << format('Apply/registry residual    : %10.3f sec', [apply_residual, 0.0].max)
              lines << format('Top-level residual         : %10.3f sec', [lifecycle_residual, 0.0].max)
              lines << '-' * 112
              if report[:error]
                lines << "PROFILED CALL FAILED       : #{report[:error].class}: #{report[:error].message}"
              else
                lines << 'PROFILED CALL COMPLETED'
              end
              lines << '=' * 112
              lines
            end

            def report_stat(report, name)
              report[:stats][name] || { calls: 0, total: 0.0, max: 0.0 }
            end

            def stage_line(name, total, calls, max)
              avg = calls.to_i.zero? ? 0.0 : total.to_f / calls.to_i
              format('%-36s %8d calls %11.3f sec  avg=%9.6f  max=%9.3f', name, calls, total, avg, max)
            end

            def wrap_builder(builder)
              lambda do |cell1, cell2|
                increment_count(:transition_builder_calls)
                measure(:transition_builder) { builder.call(cell1, cell2) }
              end
            end

            def wrap_eraser(eraser)
              lambda do |pair_key|
                increment_count(:transition_eraser_calls)
                measure(:transition_eraser) { eraser.call(pair_key) }
              end
            end

            def warn_error(stage, error)
              puts "[ADJACENCY/TRANSITION STAGE PROFILE] #{stage} failed: #{error.class}: #{error.message}"
              puts error.backtrace.first(15).join("\n")
            end
          end

          module ServiceProbe
            def synchronize_all(*args, **kwargs, &block)
              return super unless AdjacencyTransitionStageProfile.consume_arm!

              AdjacencyTransitionStageProfile.begin_run!
              result = nil
              error = nil
              begin
                result = super
              rescue StandardError => e
                error = e
                raise
              ensure
                AdjacencyTransitionStageProfile.finish_run!(self, result, error)
              end
              result
            end

            private

            def adjacency_snapshot_entries(*args, **kwargs, &block)
              result = AdjacencyTransitionStageProfile.measure(:snapshot_entries) { super }
              AdjacencyTransitionStageProfile.set_count(:entries, result.length)
              result
            end

            def compute_pair_results(*args, **kwargs, &block)
              result = AdjacencyTransitionStageProfile.measure(:compute_pair_results) { super }
              AdjacencyTransitionStageProfile.set_count(:pair_results, result.length)
              result
            end

            def candidate_pair_indices(*args, **kwargs, &block)
              result = AdjacencyTransitionStageProfile.measure(:candidate_pair_indices) { super }
              AdjacencyTransitionStageProfile.set_count(:candidate_pairs, result.length)
              result
            end

            def compute_pair_chunk(*args, **kwargs, &block)
              AdjacencyTransitionStageProfile.measure(:compute_pair_chunk) { super }
            end

            def apply_pair_results(entries, pair_results, transition_builder:, transition_eraser:, stale_pair_keys: nil)
              wrapped_builder = AdjacencyTransitionStageProfile.wrap_builder(transition_builder)
              wrapped_eraser = AdjacencyTransitionStageProfile.wrap_eraser(transition_eraser)
              AdjacencyTransitionStageProfile.measure(:apply_pair_results) do
                super(
                  entries,
                  pair_results,
                  transition_builder: wrapped_builder,
                  transition_eraser: wrapped_eraser,
                  stale_pair_keys: stale_pair_keys
                )
              end
            end

            def stale_pair_keys(*args, **kwargs, &block)
              AdjacencyTransitionStageProfile.measure(:stale_pair_keys) { super }
            end
          end

          module GeometryProbe
            def adjacency_snapshot(*args, **kwargs, &block)
              AdjacencyTransitionStageProfile.measure(:geometry_snapshot) { super }
            end

            def adjacency_axis_from_snapshots(*args, **kwargs, &block)
              AdjacencyTransitionStageProfile.measure(:geometry_axis_from_snapshots) { super }
            end
          end
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::AdjacencyTransitionStageProfile.install!
