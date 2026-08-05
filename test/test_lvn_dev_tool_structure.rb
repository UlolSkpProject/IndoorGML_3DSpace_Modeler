# frozen_string_literal: true

require 'minitest/autorun'
require 'ripper'

class LvnDevToolStructureTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  RETAINED_TOOLS = {
    'dev/lvn_all_cell_spaces_regression.rb' => {
      module_name: 'LvnAllCellSpacesRegression',
      schema: 'ulol.lvn.all_cell_spaces_regression.v1'
    },
    'dev/lvn_selected_cell_spaces_regression.rb' => {
      module_name: 'LvnSelectedCellSpacesRegression',
      schema: 'ulol.lvn.selected_cell_spaces_regression.v2'
    },
    'dev/lvn_failure_recovery_regression.rb' => {
      module_name: 'LvnFailureRecoveryRegression',
      schema: 'ulol.lvn.failure_recovery_regression.v2'
    },
    'dev/lvn_undo_redo_regression.rb' => {
      module_name: 'LvnUndoRedoRegression',
      schema: 'ulol.lvn.undo_redo_regression.v2'
    },
    'dev/lvn_topology_change_diagnostic.rb' => {
      module_name: 'LvnTopologyChangeDiagnostic',
      schema: 'ulol.lvn.topology_change_diagnostic.v2'
    }
  }.freeze

  REMOVED_FILES = %w[
    dev/precision_validation_all_cell_spaces_lvn_smoke_test.rb
    dev/precision_validation_selected_cell_spaces_lvn_smoke_test.rb
    dev/precision_validation_lvn_failure_recovery_probe.rb
    dev/precision_validation_lvn_single_undo_probe.rb
    dev/precision_validation_transition_diff_probe.rb
    dev/lvn_corpus_ab_regression_probe_v5.rb
    dev/lvn_corpus_ab_regression_probe_v6.rb
  ].freeze

  REMOVED_IDENTIFIERS = %w[
    PrecisionValidationAllCellSpacesLvnSmokeTest
    PrecisionValidationSelectedCellSpacesLvnSmokeTest
    PrecisionValidationLvnFailureRecoveryProbe
    PrecisionValidationLvnSingleUndoProbe
    PrecisionValidationTransitionDiffProbe
  ].freeze

  def test_retained_tools_have_valid_syntax_and_neutral_contract_names
    RETAINED_TOOLS.each do |relative_path, contract|
      path = File.join(ROOT, relative_path)
      assert File.file?(path), "Missing retained LVN tool: #{relative_path}"

      source = File.read(path, encoding: 'UTF-8')
      refute_nil Ripper.sexp(source), "Invalid Ruby syntax: #{relative_path}"
      assert_includes source, "module #{contract[:module_name]}"
      assert_includes source, contract[:schema]
      refute_includes source, '[Precision Validation]'
      refute_includes source, 'ulol.precision_validation.'
      refute_includes source, 'indoor_gml_precision_'

      REMOVED_IDENTIFIERS.each do |identifier|
        refute_includes source, identifier, "Legacy identifier remains in #{relative_path}"
      end
    end
  end

  def test_removed_tools_do_not_remain_as_parallel_entry_points
    REMOVED_FILES.each do |relative_path|
      refute File.exist?(File.join(ROOT, relative_path)), "Dead or legacy tool remains: #{relative_path}"
    end
  end

  def test_maintenance_documentation_defines_naming_and_compatibility_policy
    path = File.join(ROOT, 'dev', 'LVN_TOOLS.md')
    assert File.file?(path), 'Missing dev/LVN_TOOLS.md'

    source = File.read(path, encoding: 'UTF-8')
    assert_includes source, '`regression`'
    assert_includes source, '`diagnostic`'
    assert_includes source, '`smoke`'
    assert_includes source, '`probe`'
    assert_includes source, '공개 API'
    assert_includes source, 'migration'
  end
end
