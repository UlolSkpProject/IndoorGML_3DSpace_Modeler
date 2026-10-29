# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/reload_warning_filter'

class ReloadWarningFilterTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__).tr('\\', '/')

  def test_suppresses_both_lines_of_extension_constant_redefinition_warning
    _stdout, stderr = capture_io do
      Warning.warn("#{ROOT}/indoor3d/example.rb:1: warning: already initialized constant Example\n")
      Warning.warn("#{ROOT}/indoor3d/example.rb:1: warning: previous definition of Example was here\n")
    end

    assert_empty stderr
  end

  def test_preserves_unrelated_warnings
    _stdout, stderr = capture_io do
      Warning.warn("somewhere_else.rb:1: warning: unrelated warning\n")
    end

    assert_includes stderr, 'unrelated warning'
  end

  def test_reloading_definition_replaces_constants_without_warning
    definition_path = File.expand_path('../indoor3d/definition.rb', __dir__)

    _stdout, stderr = capture_io do
      load definition_path
      load definition_path
    end

    assert_empty stderr
    assert_equal '1.0.3', ULOL::Indoor3DGmlModeler::Definition::INDOOR_GML_STANDARD_VERSION
  end
end
