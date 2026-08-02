# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ThreadedProgressInfrastructure
        class ScopedMethodOverride
          VALID_VISIBILITIES = %i[public protected private].freeze

          def initialize(target:, method_name:, visibility: nil, &replacement)
            raise ArgumentError, 'target is required' if target.nil?
            raise ArgumentError, 'replacement block is required' unless replacement

            @target = target
            @method_name = method_name.to_sym
            @replacement = replacement
            @requested_visibility = visibility&.to_sym
            if @requested_visibility && !VALID_VISIBILITIES.include?(@requested_visibility)
              raise ArgumentError, "unsupported visibility: #{@requested_visibility}"
            end
            unless @target.respond_to?(@method_name, true)
              raise ArgumentError, "target does not respond to #{@method_name}"
            end

            @active = false
          end

          def call
            raise 'ScopedMethodOverride is already active' if @active
            raise ArgumentError, 'block is required' unless block_given?

            install!
            yield
          ensure
            restore!
          end

          def active?
            @active == true
          end

          private

          def install!
            singleton = @target.singleton_class
            @singleton = singleton
            @original_visibility = singleton_visibility(singleton)
            @had_singleton_method = !@original_visibility.nil?
            @original_singleton_method = singleton.instance_method(@method_name) if @had_singleton_method
            visibility = @requested_visibility || inherited_visibility(singleton)

            singleton.send(:define_method, @method_name, &@replacement)
            singleton.send(visibility, @method_name)
            @active = true
            true
          end

          def restore!
            return false unless @active

            if @had_singleton_method
              @singleton.send(:define_method, @method_name, @original_singleton_method)
              @singleton.send(@original_visibility, @method_name)
            else
              @singleton.send(:remove_method, @method_name)
            end
            true
          rescue NameError
            false
          ensure
            @active = false
            @singleton = nil
            @original_singleton_method = nil
            @original_visibility = nil
            @had_singleton_method = false
          end

          def singleton_visibility(singleton)
            return :private if singleton.private_instance_methods(false).include?(@method_name)
            return :protected if singleton.protected_instance_methods(false).include?(@method_name)
            return :public if singleton.public_instance_methods(false).include?(@method_name)

            nil
          end

          def inherited_visibility(singleton)
            return :private if singleton.private_method_defined?(@method_name)
            return :protected if singleton.protected_method_defined?(@method_name)

            :public
          end
        end
      end
    end
  end
end
