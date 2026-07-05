# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../indoor3d/export/validation_run_workspace'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ValidationRunWorkspaceTest < Minitest::Test
          def setup
            @base_dir = Dir.mktmpdir('indoorgml-workspace-test-')
          end

          def teardown
            FileUtils.rm_rf(@base_dir)
          end

          def test_create_allocates_isolated_paths
            first = ValidationRunWorkspace.create(base_dir: @base_dir)
            second = ValidationRunWorkspace.create(base_dir: @base_dir)

            refute_equal first.root_dir, second.root_dir
            refute_equal first.gml_path, second.gml_path
            refute_equal first.report_json_path, second.report_json_path
            refute_equal first.report_html_path, second.report_html_path
            assert_match(/validation-runs/, first.root_dir)
            assert_equal File.join(first.root_dir, 'input.gml'), first.gml_path
            assert_equal File.join(first.root_dir, 'report.json'), first.report_json_path
            assert_equal File.join(first.root_dir, 'report', 'report.html'), first.report_html_path
          end

          def test_cleanup_is_idempotent_and_does_not_delete_other_runs
            first = ValidationRunWorkspace.create(base_dir: @base_dir)
            second = ValidationRunWorkspace.create(base_dir: @base_dir)
            FileUtils.mkdir_p(first.report_dir)
            FileUtils.mkdir_p(second.report_dir)
            File.write(first.report_html_path, 'first')
            File.write(second.report_html_path, 'second')

            assert first.cleanup
            refute first.cleanup

            refute File.exist?(first.root_dir)
            assert File.exist?(second.report_html_path)
            assert_equal 'second', File.read(second.report_html_path)
          end

          def test_cleanup_does_not_mark_cleaned_when_directory_remains
            workspace = ValidationRunWorkspace.create(base_dir: @base_dir)
            original = FileUtils.method(:rm_rf)
            FileUtils.define_singleton_method(:rm_rf) { |_path| nil }

            refute workspace.cleanup
            refute workspace.cleaned?
            assert File.exist?(workspace.root_dir)
          ensure
            FileUtils.define_singleton_method(:rm_rf) { |*args| original.call(*args) } if original
          end
        end
      end
    end
  end
end
