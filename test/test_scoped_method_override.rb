# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../dev/threaded_progress_infrastructure/scoped_method_override'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class ScopedMethodOverrideTest < Minitest::Test
        Override = ThreadedProgressInfrastructure::ScopedMethodOverride

        class Target
          def call_secret
            secret
          end

          private

          def secret
            :original
          end
        end

        def test_temporarily_overrides_inherited_private_method
          target = Target.new
          override = Override.new(
            target: target,
            method_name: :secret,
            visibility: :private
          ) { :replacement }

          assert_equal :original, target.call_secret
          result = override.call do
            assert override.active?
            assert_equal :replacement, target.call_secret
            :block_result
          end

          assert_equal :block_result, result
          refute override.active?
          assert_equal :original, target.call_secret
          refute target.respond_to?(:secret)
          assert target.respond_to?(:secret, true)
        end

        def test_restores_original_method_when_block_raises
          target = Target.new
          override = Override.new(
            target: target,
            method_name: :secret,
            visibility: :private
          ) { :replacement }

          assert_raises(RuntimeError) do
            override.call do
              assert_equal :replacement, target.call_secret
              raise 'expected failure'
            end
          end

          assert_equal :original, target.call_secret
          refute override.active?
        end

        def test_restores_preexisting_singleton_method_and_visibility
          target = Target.new
          singleton = target.singleton_class
          singleton.send(:define_method, :secret) { :singleton_original }
          singleton.send(:private, :secret)
          override = Override.new(
            target: target,
            method_name: :secret,
            visibility: :private
          ) { :replacement }

          assert_equal :singleton_original, target.call_secret
          override.call { assert_equal :replacement, target.call_secret }
          assert_equal :singleton_original, target.call_secret
          assert singleton.private_method_defined?(:secret)
        end

        def test_rejects_missing_target_method
          target = Target.new

          error = assert_raises(ArgumentError) do
            Override.new(target: target, method_name: :missing) { :replacement }
          end

          assert_match(/does not respond/, error.message)
        end
      end
    end
  end
end
