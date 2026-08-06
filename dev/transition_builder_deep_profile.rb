# frozen_string_literal: true

# One-shot deep profiler for Transition builder work during bulk synchronize_all.
#
# core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
# root = File.expand_path('..', File.dirname(core_file))
# load File.join(root, 'dev', 'transition_builder_deep_profile.rb')
#
# Then run the normal Local Grid CellSpace Create once.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      unless const_defined?(:TransitionBuilderDeepProfile, false)
        module TransitionBuilderDeepProfile
          CLOCK = Process::CLOCK_MONOTONIC
          LOG_PATH = File.join(
            ENV['TEMP'] || ENV['TMP'] || '.',
            'IndoorGML_Transition_Builder_Deep_Profile.log'
          ).freeze

          REPORT_ORDER = [
            '00 builder total',
            '01 pair key',
            '01a Transition#initialize',
            '02 update_transition total',
            '02a Transition#update',
            '03 waypoint refresh total',
            '03a waypoint candidates total',
            '03a1 common face waypoint query',
            '03b state root position',
            '03c cell root transformation',
            '03d normalize waypoint candidate',
            '03e plausible waypoint check',
            '04 register with states total',
            '04a write state attributes',
            '04b State#add_transition',
            '05 write transition attributes',
            '06 overlay invalidation'
          ].freeze

          class << self
            def install!
              raise 'AdjacencyService is unavailable' unless defined?(IndoorCore::AdjacencyService)
              raise 'IndoorModel is unavailable' unless defined?(IndoorCore::IndoorModel)

              IndoorCore::AdjacencyService.prepend(ServiceProbe) unless
                IndoorCore::AdjacencyService.ancestors.include?(ServiceProbe)
              IndoorCore::IndoorModel.prepend(BuilderProbe) unless
                IndoorCore::IndoorModel.ancestors.include?(BuilderProbe)

              if defined?(IndoorCore::Transition)
                IndoorCore::Transition.prepend(TransitionProbe) unless
                  IndoorCore::Transition.ancestors.include?(TransitionProbe)
              end
              if defined?(IndoorCore::State)
                IndoorCore::State.prepend(StateProbe) unless
                  IndoorCore::State.ancestors.include?(StateProbe)
              end
              if defined?(IndoorCore::AdjacencyService::GeometryQuery)
                singleton = IndoorCore::AdjacencyService::GeometryQuery.singleton_class
                singleton.prepend(GeometryQueryProbe) unless singleton.ancestors.include?(GeometryQueryProbe)
              end

              arm!
              puts '[TRANSITION BUILDER DEEP PROFILE] armed for the next synchronize_all'
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
              @stats = {}
              @stack = []
              @active = true
              @started_at = now
              true
            end

            def measure(name)
              return yield unless active?

              started = now
              frame = { child: 0.0 }
              @stack << frame
              yield
            ensure
              if started
                elapsed = now - started
                @stack.pop
                self_time = elapsed - frame[:child]
                self_time = 0.0 if self_time.negative?
                @stack.last[:child] += elapsed unless @stack.empty?
                record(name, elapsed, self_time)
              end
            end

            def finish_run!(service, result, error = nil)
              elapsed = @started_at ? now - @started_at : 0.0
              @active = false
              report = build_report(service, result, elapsed, error)
              lines = report_lines(report)
              puts
              lines.each { |line| puts line }
              File.write(LOG_PATH, lines.join("\n") + "\n")
              report
            rescue StandardError => e
              warn_error('finish', e)
              nil
            ensure
              @active = false
            end

            private

            def now
              Process.clock_gettime(CLOCK)
            end

            def record(name, elapsed, self_time)
              stat = (@stats[name] ||= { count: 0, total: 0.0, self: 0.0, max: 0.0 })
              stat[:count] += 1
              stat[:total] += elapsed
              stat[:self] += self_time
              stat[:max] = elapsed if elapsed > stat[:max]
            end

            def build_report(service, result, elapsed, error)
              metrics = result.is_a?(Hash) ? result : {}
              {
                elapsed: elapsed,
                error: error,
                service_total: metrics[:total_duration].to_f,
                pair_count: metrics[:pair_comparison_count].to_i,
                detailed: metrics[:adjacency_detailed_computation].to_f,
                stats: @stats || {},
                transition_count: (@stats.dig('00 builder total', :count) || 0),
                registry_transition_count: registry_transition_count(service)
              }
            end

            def registry_transition_count(service)
              registry = service.instance_variable_get(:@registry)
              return registry.transitions.length if registry.respond_to?(:transitions)
              return registry.transition_pair_keys.length if registry.respond_to?(:transition_pair_keys)

              nil
            rescue StandardError
              nil
            end

            def report_lines(report)
              lines = []
              lines << '=' * 118
              lines << 'Transition Builder Deep Profile'
              lines << '=' * 118
              lines << "Transition builder calls  : #{report[:transition_count]}"
              lines << "Registry transitions      : #{report[:registry_transition_count] || 'n/a'}"
              lines << "Candidate pair metric     : #{report[:pair_count]}"
              lines << format('synchronize_all elapsed  : %10.3f sec', report[:elapsed])
              lines << format('Service reported total   : %10.3f sec', report[:service_total])
              lines << format('Service detailed geometry: %10.3f sec', report[:detailed])
              lines << "Error                     : #{report[:error].class}: #{report[:error].message}" if report[:error]
              lines << '-' * 118
              lines << format('%-42s %8s %12s %12s %11s %11s', 'Stage', 'Calls', 'Total', 'Self', 'Avg', 'Max')
              lines << '-' * 118

              REPORT_ORDER.each do |name|
                stat = report[:stats][name]
                next unless stat

                count = stat[:count]
                lines << format(
                  '%-42s %8d %11.3f %11.3f %10.5f %10.3f',
                  name,
                  count,
                  stat[:total],
                  stat[:self],
                  count.zero? ? 0.0 : stat[:total] / count,
                  stat[:max]
                )
              end

              unknown = report[:stats].keys - REPORT_ORDER
              unknown.sort.each do |name|
                stat = report[:stats][name]
                count = stat[:count]
                lines << format(
                  '%-42s %8d %11.3f %11.3f %10.5f %10.3f',
                  name,
                  count,
                  stat[:total],
                  stat[:self],
                  count.zero? ? 0.0 : stat[:total] / count,
                  stat[:max]
                )
              end

              builder = report[:stats]['00 builder total'] || {}
              lines << '-' * 118
              lines << format('Builder measured total   : %10.3f sec', builder[:total].to_f)
              lines << format('Builder unexplained self : %10.3f sec', builder[:self].to_f)
              lines << 'Total includes nested calls; Self excludes other profiled child calls.'
              lines << '=' * 118
              lines
            end

            def warn_error(stage, error)
              puts "[TRANSITION BUILDER DEEP PROFILE] #{stage} failed: #{error.class}: #{error.message}"
              puts error.backtrace.first(15).join("\n")
            end
          end

          module ServiceProbe
            def synchronize_all(*args, **kwargs, &block)
              return super unless TransitionBuilderDeepProfile.consume_arm!

              TransitionBuilderDeepProfile.begin_run!
              result = super
              TransitionBuilderDeepProfile.finish_run!(self, result)
              result
            rescue StandardError => e
              TransitionBuilderDeepProfile.finish_run!(self, nil, e)
              raise
            end
          end

          module BuilderProbe
            private

            def create_or_update_transition_for_pair(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('00 builder total') { super }
            end

            def cell_pair_key(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('01 pair key') { super }
            end

            def update_transition(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('02 update_transition total') { super }
            end

            def refresh_transition_waypoint_candidates(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('03 waypoint refresh total') { super }
            end

            def transition_waypoint_candidates(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('03a waypoint candidates total') { super }
            end

            def state_root_local_position(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('03b state root position') { super }
            end

            def cell_space_root_local_transformation(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('03c cell root transformation') { super }
            end

            def normalize_root_local_waypoint_candidate(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('03d normalize waypoint candidate') { super }
            end

            def plausible_root_local_waypoint?(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('03e plausible waypoint check') { super }
            end

            def register_transition_with_states(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('04 register with states total') { super }
            end

            def write_state_attributes(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('04a write state attributes') { super }
            end

            def write_transition_attributes(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('05 write transition attributes') { super }
            end

            def invalidate_overlay_transition_points(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('06 overlay invalidation') { super }
            end
          end

          module TransitionProbe
            def initialize(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('01a Transition#initialize') { super }
            end

            def update(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('02a Transition#update') { super }
            end
          end

          module StateProbe
            def add_transition(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('04b State#add_transition') { super }
            end
          end

          module GeometryQueryProbe
            def common_face_waypoint_candidates(*args, **kwargs, &block)
              TransitionBuilderDeepProfile.measure('03a1 common face waypoint query') { super }
            end
          end
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::TransitionBuilderDeepProfile.install!
