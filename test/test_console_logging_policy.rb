# frozen_string_literal: true

require 'minitest/autorun'

class ConsoleLoggingPolicyTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_user_runtime_logging_is_disabled_by_default
    definition = File.read(File.join(ROOT, 'indoor3d/definition.rb'))
    logger = File.read(File.join(ROOT, 'indoor3d/utils/logger.rb'))

    assert_includes definition, 'LOGGING_ENABLED = false'
    assert_includes logger, 'return false unless logging_enabled?'
    refute_includes logger, 'return true if !logging_enabled?'
  end

  def test_cell_space_benchmark_uses_debug_logger
    policy = File.read(File.join(ROOT, 'indoor3d/application/cell_space_logging_policy.rb'))
    indoor_model = File.read(File.join(ROOT, 'indoor3d/application/indoor_model.rb'))

    assert_includes indoor_model, "require_relative 'cell_space_logging_policy'"
    assert_includes policy, '@logger.debug do'
    assert_includes policy, "format('  전체 시간                  : %.3f sec', metrics[:total_duration].to_f)"
    assert_operator policy.index('metrics[:total_duration]'), :<, policy.index('metrics[:preflight_duration]')
    assert_operator policy.index('metrics[:preflight_duration]'), :<, policy.index('metrics[:cell_space_state_duration]')
    assert_operator policy.index('metrics[:cell_space_state_duration]'), :<, policy.index('metrics[:adjacency_transition_duration]')
    refute_match(/^\s*puts\b/, policy)
  end

  def test_cell_space_result_message_includes_total_elapsed_time
    commands = File.read(File.join(ROOT, 'indoor3d/ui/commands/cell_space_commands.rb'))

    assert_includes commands, 'result.metrics&.[](:total_duration)'
    assert_includes commands, "Total elapsed: #{'#{'}format('%.3f', elapsed)} sec"
  end
end
