# frozen_string_literal: true

# Dev-only profiler for bulk CellSpace creation.
#
# Purpose:
# - split the remaining CellSpaceLifecycleService self time by wrapping the
#   actual callback objects stored in lifecycle contexts;
# - split AttributeSerializer persistence cost;
# - write progress and the final report to a .log file without relying on the
#   Ruby Console or modal UI timing.
#
# Usage from SketchUp Ruby Console after restarting SketchUp:
#   load 'C:/path/to/IndoorGML_3DSpace_Modeler/dev/cell_space_create_stage2_profile.rb'
# Then run the normal bulk CellSpace Create command once.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceCreateStage2Profile
        CLOCK = Process::CLOCK_MONOTONIC
        LOG_PATH = File.join(
          ENV['TEMP'] || ENV['TMP'] || '.',
          'IndoorGML_CellSpace_Create_Profile_Stage2.log'
        ).freeze
        PROGRESS_EVERY = 50
        SLOW_SECONDS = 0.5

        class << self
          attr_reader :completed_count, :failed_count

          def install!
            reset!
            open_log!
            install_wrappers!
            install_callback_probes!

            puts
            puts '[CELLSPACE CREATE STAGE2 PROFILE] installed'
            puts "Log: #{LOG_PATH}"
            puts '이제 평소와 동일하게 전체 CellSpace Create를 실행하세요.'
            true
          rescue StandardError => e
            puts "[CELLSPACE CREATE STAGE2 PROFILE] install failed: #{e.class}: #{e.message}"
            puts e.backtrace.first(10).join("\n")
            false
          end

          def reset!
            @stats = {}
            @stack = []
            @completed_count = 0
            @failed_count = 0
            @started_at = nil
            @finished = false
            @wrapped_callback_ids = {}
          end

          def open_log!
            @log&.close rescue nil
            @log = File.open(LOG_PATH, 'w')
            @log.sync = true
            log_line('=' * 118)
            log_line('IndoorGML CellSpace Create Stage2 Profile')
            log_line("Started: #{Time.now}")
            log_line("Log: #{LOG_PATH}")
            log_line('=' * 118)
          end

          def stats
            @stats ||= {}
          end

          def stack
            @stack ||= []
          end

          def now
            Process.clock_gettime(CLOCK)
          end

          def ensure_started!
            return if @started_at

            @started_at = now
            log_line('')
            log_line("[CREATE START] #{Time.now}")
          end

          def measure(name, label = nil)
            ensure_started!
            started = now
            frame = { child: 0.0 }
            stack << frame

            result = yield
            result
          ensure
            if started
              elapsed = now - started
              stack.pop
              self_time = elapsed - frame[:child]
              self_time = 0.0 if self_time.negative?
              stack.last[:child] += elapsed unless stack.empty?
              record(name, elapsed, self_time, label)
            end
          end

          def record(name, elapsed, self_time, label)
            stat = stats[name] ||= {
              count: 0,
              total: 0.0,
              self_time: 0.0,
              max: 0.0,
              max_label: nil
            }
            stat[:count] += 1
            stat[:total] += elapsed
            stat[:self_time] += self_time
            if elapsed > stat[:max]
              stat[:max] = elapsed
              stat[:max_label] = label
            end

            return unless elapsed >= SLOW_SECONDS

            log_line(
              format(
                '[SLOW] %-48s %9.3f sec%s',
                name,
                elapsed,
                label ? " | #{label}" : ''
              )
            )
          end

          def entity_label(value)
            return nil if value.nil?

            if value.respond_to?(:sketchup_group)
              group = value.sketchup_group
              id = safe_call { value.id }
              entity_id = safe_call { group.entityID }
              return "cell=#{id} entity=#{entity_id}"
            end

            if value.respond_to?(:entityID)
              entity_id = safe_call { value.entityID }
              name = safe_call { value.name.to_s }
              return "entity=#{entity_id} name=#{name}"
            end

            nil
          rescue StandardError
            nil
          end

          def safe_call
            yield
          rescue StandardError
            nil
          end

          def cell_finished(success:)
            @completed_count = @completed_count.to_i + 1
            @failed_count = @failed_count.to_i + 1 unless success
            progress_snapshot if (@completed_count % PROGRESS_EVERY).zero?
          end

          def elapsed
            return 0.0 unless @started_at

            now - @started_at
          end

          def progress_snapshot
            log_line('')
            log_line(
              format(
                '[PROGRESS] cells=%d failed=%d elapsed=%.3f sec',
                @completed_count,
                @failed_count,
                elapsed
              )
            )
            sorted_stats.first(12).each do |name, stat|
              log_line(
                format(
                  '  %-48s self=%9.3f total=%9.3f calls=%d',
                  name,
                  stat[:self_time],
                  stat[:total],
                  stat[:count]
                )
              )
            end
          end

          def finish!(application_message = nil)
            return if @finished

            @finished = true
            log_line('')
            log_line("[CREATE FINISH SIGNAL] #{Time.now}")
            log_line(format('Profile elapsed: %.3f sec', elapsed))

            unless application_message.to_s.empty?
              log_line('')
              log_line('[APPLICATION RESULT]')
              application_message.to_s.each_line { |line| log_line(line.chomp) }
            end

            log_line('')
            write_report(@log)
            @log.flush
            true
          rescue StandardError => e
            log_line("[PROFILE FINISH ERROR] #{e.class}: #{e.message}")
            false
          end

          def sorted_stats
            stats.sort_by { |_name, stat| -stat[:self_time] }
          end

          def write_report(io)
            io.puts '=' * 118
            io.puts 'CellSpace Create Stage2 Deep Profile'
            io.puts '=' * 118
            io.puts format('Profile elapsed : %.3f sec', elapsed)
            io.puts format('Cell executions : %d', @completed_count.to_i)
            io.puts format('Failed          : %d', @failed_count.to_i)
            io.puts
            io.puts format(
              '%-52s %7s %12s %12s %11s %11s',
              '구간', 'Calls', 'Total', 'Self', 'Avg', 'Max'
            )
            io.puts '-' * 118

            sorted_stats.each do |name, stat|
              count = stat[:count].to_i
              io.puts format(
                '%-52s %7d %11.3f %11.3f %10.4f %10.3f',
                name,
                count,
                stat[:total],
                stat[:self_time],
                count.zero? ? 0.0 : stat[:total] / count,
                stat[:max]
              )
              if stat[:max_label] && stat[:max] >= SLOW_SECONDS
                io.puts "    slowest: #{stat[:max_label]}"
              end
            end

            io.puts '-' * 118
            io.puts 'Total = 계측된 하위 호출 포함'
            io.puts 'Self  = 이 profiler가 계측한 하위 호출 시간을 제외한 값'
            io.puts '=' * 118
          end

          def log_line(text)
            @log&.puts(text)
          rescue StandardError
            nil
          end

          def install_wrappers!
            CellSpaceLifecycleService.prepend(Stage2LifecycleProbe) unless
              CellSpaceLifecycleService.ancestors.include?(Stage2LifecycleProbe)

            CellSpace.prepend(Stage2CellSpaceProbe) unless
              CellSpace.ancestors.include?(Stage2CellSpaceProbe)

            AttributeSerializer.prepend(Stage2AttributeSerializerProbe) unless
              AttributeSerializer.ancestors.include?(Stage2AttributeSerializerProbe)

            NavigationSemanticResolver.singleton_class.prepend(Stage2NavigationResolverProbe) if
              defined?(NavigationSemanticResolver) &&
              !NavigationSemanticResolver.singleton_class.ancestors.include?(Stage2NavigationResolverProbe)

            UiFeedback.singleton_class.prepend(Stage2UiFeedbackProbe) unless
              UiFeedback.singleton_class.ancestors.include?(Stage2UiFeedbackProbe)
          end

          def install_callback_probes!
            model = IndoorModel.current

            # Recreate services so their callback Method objects reflect the current
            # runtime and then wrap the actual callback objects held by each context.
            model.instance_variable_set(:@cell_space_lifecycle_service, nil)
            model.instance_variable_set(:@cell_space_lifecycle_service_local_grid, nil)

            services = []
            services << safe_call { model.send(:cell_space_lifecycle_service) }
            services << safe_call { model.send(:cell_space_lifecycle_service_local_grid) }
            services.compact.uniq.each { |service| instrument_service_callbacks!(service) }

            log_line("[CALLBACK PROBES] services=#{services.compact.uniq.length}")
          end

          def instrument_service_callbacks!(service)
            source_preparer = service.instance_variable_get(:@source_preparer)
            context = service.instance_variable_get(:@context)

            wrap_callable_ivars!(source_preparer, {
              :@converted_group => 'S01 converted_group callback',
              :@type_resolver => 'S02 type_resolver callback',
              :@geometry_preparer => 'S03 geometry_preparer callback',
              :@tag_storey_resolver => 'S04 tag_storey callback',
              :@storey_resolver => 'S05 storey_resolver callback',
              :@storey_value_resolver => 'S06 storey_value callback'
            })

            wrap_callable_ivars!(context, {
              :@ensure_space_features_groups => 'C01 ensure_space_features_groups',
              :@place_cell_group => 'C02 place_cell_group',
              :@default_storey_name => 'C03 default_storey_name',
              :@fixed_state_height_offset => 'C04 fixed_state_height_offset',
              :@recenter_cell_space_geometry => 'C05 recenter_cell_space_geometry',
              :@coordinate_preparer => 'C06 coordinate_preparer(LocalGrid)',
              :@name_cell_space_entity => 'C07 name_cell_space_entity',
              :@apply_cell_space_material => 'C08 apply_cell_space_material',
              :@track_cell_space_entity => 'C09 track_cell_space_entity',
              :@register_cell_space => 'C10 register_cell_space',
              :@register_state => 'C11 register_state',
              :@write_attributes => 'C12 write_attributes callback',
              :@write_cell_space_attributes => 'C13 write_cell_space_attributes callback',
              :@apply_indoor_lock_policy => 'C14 apply_indoor_lock_policy',
              :@synchronize_adjacency_and_transitions_for_cell_space => 'C15 synchronize_single_cell_topology'
            })

            log_line(
              "[SERVICE] #{service.class} context=#{context&.class} source_preparer=#{source_preparer&.class}"
            )
          end

          def wrap_callable_ivars!(object, mapping)
            return unless object

            mapping.each do |ivar, metric_name|
              next unless object.instance_variable_defined?(ivar)

              callable = object.instance_variable_get(ivar)
              next unless callable.respond_to?(:call)
              next if @wrapped_callback_ids[callable.object_id]

              wrapped = proc do |*args, **kwargs, &block|
                label = entity_label(args.first)
                measure(metric_name, label) do
                  callable.call(*args, **kwargs, &block)
                end
              end

              object.instance_variable_set(ivar, wrapped)
              @wrapped_callback_ids[callable.object_id] = true
              log_line("[WRAP] #{object.class} #{ivar} -> #{metric_name}")
            end
          end
        end

        module Stage2LifecycleProbe
          def create_from_group_deferred(*args, **kwargs, &block)
            result = nil
            success = false
            begin
              result = CellSpaceCreateStage2Profile.measure(
                'L00 create_from_group_deferred',
                CellSpaceCreateStage2Profile.entity_label(args.first)
              ) { super }
              success = !result.nil?
              result
            ensure
              CellSpaceCreateStage2Profile.cell_finished(success: success)
            end
          end

          private

          def create_from_group_internal(*args, **kwargs, &block)
            CellSpaceCreateStage2Profile.measure(
              'L01 create_from_group_internal',
              CellSpaceCreateStage2Profile.entity_label(args.first)
            ) { super }
          end
        end

        module Stage2CellSpaceProbe
          def initialize(*args, **kwargs, &block)
            CellSpaceCreateStage2Profile.measure(
              'D01 CellSpace#initialize',
              CellSpaceCreateStage2Profile.entity_label(args.first)
            ) { super }
          end

          def set_storey(*args, **kwargs, &block)
            CellSpaceCreateStage2Profile.measure('D02 CellSpace#set_storey') { super }
          end

          def create_duality_state(*args, **kwargs, &block)
            CellSpaceCreateStage2Profile.measure(
              'D03 CellSpace#create_duality_state',
              CellSpaceCreateStage2Profile.entity_label(self)
            ) { super }
          end
        end

        module Stage2AttributeSerializerProbe
          def write_cell_space_and_state(*args, **kwargs, &block)
            CellSpaceCreateStage2Profile.measure(
              'P01 Serializer#write_cell_space_and_state',
              CellSpaceCreateStage2Profile.entity_label(args.first)
            ) { super }
          end

          def write_cell_space(*args, **kwargs, &block)
            CellSpaceCreateStage2Profile.measure(
              'P02 Serializer#write_cell_space',
              CellSpaceCreateStage2Profile.entity_label(args.first)
            ) { super }
          end

          private

          def write_attributes(*args, **kwargs, &block)
            CellSpaceCreateStage2Profile.measure(
              'P03 Serializer#write_attributes wrapper',
              CellSpaceCreateStage2Profile.entity_label(args.first)
            ) { super }
          end

          def write_navigation_attributes(*args, **kwargs, &block)
            CellSpaceCreateStage2Profile.measure(
              'P04 Serializer#write_navigation_attributes',
              CellSpaceCreateStage2Profile.entity_label(args.first)
            ) { super }
          end

          def write_optional_attribute(*args, **kwargs, &block)
            CellSpaceCreateStage2Profile.measure('P05 Serializer#write_optional_attribute') { super }
          end
        end

        module Stage2NavigationResolverProbe
          def resolve(*args, **kwargs, &block)
            CellSpaceCreateStage2Profile.measure(
              'P06 NavigationSemanticResolver.resolve',
              CellSpaceCreateStage2Profile.entity_label(args.first)
            ) { super }
          end
        end

        module Stage2UiFeedbackProbe
          def publish_result(message, errors: nil)
            if message.to_s.include?('Create CellSpace 시간 요약')
              CellSpaceCreateStage2Profile.finish!(message)
            end
            super
          end
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceCreateStage2Profile.install!
