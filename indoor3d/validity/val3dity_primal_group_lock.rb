# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityPrimalGroupLock
          THREAD_KEY = :ulol_indoor_gml_val3dity_primal_group_lock

          module_function

          def current_guard
            Thread.current[THREAD_KEY]
          rescue StandardError
            nil
          end

          def with_guard(guard)
            previous = Thread.current[THREAD_KEY]
            Thread.current[THREAD_KEY] = guard
            yield
          ensure
            Thread.current[THREAD_KEY] = previous
          end

          def registry
            @registry ||= {}
          end

          def acquire(group, logger: IndoorCore::Logger)
            return nil unless lockable_group?(group)

            key = group.object_id
            entry = registry[key]
            if entry && entry[:group].equal?(group)
              entry[:count] += 1
              return key
            end

            originally_locked = group.locked? == true
            group.locked = true unless originally_locked
            registry[key] = {
              group: group,
              count: 1,
              originally_locked: originally_locked
            }
            key
          rescue StandardError => error
            log(logger, "val3dity primal_group lock failed: #{error.class}: #{error.message}")
            nil
          end

          def release(key, logger: IndoorCore::Logger)
            return false if key.nil?

            entry = registry[key]
            return false unless entry

            entry[:count] -= 1
            return true if entry[:count].positive?

            registry.delete(key)
            group = entry[:group]
            return true unless lockable_group?(group)

            original = entry[:originally_locked] == true
            group.locked = original unless group.locked? == original
            true
          rescue StandardError => error
            registry.delete(key) if key
            log(logger, "val3dity primal_group unlock failed: #{error.class}: #{error.message}")
            false
          end

          def lockable_group?(group)
            group&.valid? && group.respond_to?(:locked?) && group.respond_to?(:locked=)
          rescue StandardError
            false
          end

          def log(logger, message)
            logger.puts("[IndoorGML] #{message}") if logger&.respond_to?(:puts)
          rescue StandardError
            nil
          end

          class Guard
            def initialize(group, logger: IndoorCore::Logger)
              @group = group
              @logger = logger
              @registry_key = nil
              @acquired = false
            end

            def acquire
              return true if @acquired

              key = Val3dityPrimalGroupLock.acquire(@group, logger: @logger)
              return false if key.nil?

              @registry_key = key
              @acquired = true
              true
            end

            def release
              return false unless @acquired

              key = @registry_key
              @registry_key = nil
              @acquired = false
              Val3dityPrimalGroupLock.release(key, logger: @logger)
            end
          end

          module RunnerPatch
            def start(*arguments, **options, &callback)
              group = @indoor_model&.primal_group
              guard = Guard.new(group)
              Val3dityPrimalGroupLock.with_guard(guard) do
                super(*arguments, **options, &callback)
              end
            end
          end

          module ProcessAdapterPatch
            def initialize(*arguments, **options)
              @val3dity_primal_group_lock_guard = Val3dityPrimalGroupLock.current_guard
              super
            end

            def start(*arguments, **options)
              @val3dity_primal_group_lock_guard&.acquire
              super
            rescue StandardError
              release_val3dity_primal_group_lock
              raise
            end

            def finished?(*arguments, **options)
              finished = super
              release_val3dity_primal_group_lock if finished
              finished
            end

            def terminate(*arguments, **options)
              terminated = super
              release_val3dity_primal_group_lock if terminated
              terminated
            end

            def close(*arguments, **options)
              process_inactive = @finished == true || @process_handle.to_i <= 0
              result = super
              release_val3dity_primal_group_lock if process_inactive
              result
            end

            private

            def release_val3dity_primal_group_lock
              guard = @val3dity_primal_group_lock_guard
              @val3dity_primal_group_lock_guard = nil
              guard&.release
            end
          end

          def install!
            return false unless defined?(Val3dityRunner)
            return false unless defined?(Val3dityProcessAdapter)

            unless Val3dityRunner.ancestors.include?(RunnerPatch)
              Val3dityRunner.prepend(RunnerPatch)
            end
            unless Val3dityProcessAdapter.ancestors.include?(ProcessAdapterPatch)
              Val3dityProcessAdapter.prepend(ProcessAdapterPatch)
            end
            true
          end
        end

        Val3dityPrimalGroupLock.install!
      end
    end
  end
end
