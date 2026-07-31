# frozen_string_literal: true

require 'rbconfig'

file = File.expand_path(ARGV.fetch(0))
base_name = File.basename(file)

load file

# Production loads Logger before IndoorModel runtime modules. A few focused unit
# tests load one runtime module directly, so reproduce the production dependency
# only when the test did not provide its own Logger stub.
if base_name == 'test_local_grid_runtime_refresh_policy_v2.rb'
  core = ULOL::Indoor3DGmlModeler::IndoorCore
  require_relative '../indoor3d/utils/logger' unless core.const_defined?(:Logger, false)
end

# Command-level tests verify that the application requests deferred feedback.
# The dispatcher/one-tick/modal behavior itself is covered separately by
# test_ui_feedback_policy.rb, so do not make these tests depend on a live timer.
if %w[
  test_display_commands_dual_overlay_scale.rb
  test_validation_focus_recheck_workspace_cleanup.rb
  test_validation_session.rb
].include?(base_name)
  feedback = ULOL::Indoor3DGmlModeler::IndoorCore::UiFeedback
  original_defer_modal = feedback.method(:defer_modal)
  feedback.define_singleton_method(:defer_modal) do |message, *arguments|
    if Object.const_defined?(:UI)
      ui = Object.const_get(:UI)
      if ui.respond_to?(:messages)
        messages = ui.messages
        messages << message if messages.respond_to?(:<<)
        next true
      end
    end

    original_defer_modal.call(message, *arguments)
  end
end

case base_name
when 'test_cell_space_copy_independence.rb'
  require_relative 'support/cell_space_copy_independence_policy'
when 'test_local_vertex_normalizer.rb'
  require_relative 'support/local_vertex_normalizer_source_sliver_policy'
end
