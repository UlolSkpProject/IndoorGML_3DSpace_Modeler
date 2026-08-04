# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../dev/lvn_runtime_preflight'

class LvnRuntimePreflightTest < Minitest::Test
  def setup
    @temporary_directory = Dir.mktmpdir('lvn-runtime-preflight')
    @application_directory = File.join(
      @temporary_directory,
      'indoor3d',
      'application'
    )
    @layer_directory = File.join(
      @application_directory,
      'local_vertex_normalizer'
    )
    FileUtils.mkdir_p(@layer_directory)

    @loader_path = File.join(
      @application_directory,
      'local_vertex_normalizer.rb'
    )
    @plain_feature_path = File.join(@layer_directory, 'plain_layer.rb')
    @prepend_feature_path = File.join(@layer_directory, 'prepend_layer.rb')

    File.write(
      @loader_path,
      <<~RUBY,
        require_relative 'local_vertex_normalizer/plain_layer'
        require_relative "local_vertex_normalizer/prepend_layer.rb"
      RUBY
      mode: 'w:UTF-8'
    )
    File.write(
      @plain_feature_path,
      "# no prepend layer\n",
      mode: 'w:UTF-8'
    )
    File.write(
      @prepend_feature_path,
      <<~RUBY,
        class LocalVertexNormalizer
          prepend LocalVertexNormalizerExampleLayer
        end
      RUBY
      mode: 'w:UTF-8'
    )

    @constant_root = Module.new
    @layer = Module.new
    @constant_root.const_set(:LocalVertexNormalizerExampleLayer, @layer)
    @target_class = Class.new
    @target_class.prepend(@layer)
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory)
  end

  def test_accepts_complete_runtime
    report = LvnRuntimePreflight.verify!(
      loader_path: @loader_path,
      loaded_features: complete_loaded_features,
      target_class: @target_class,
      constant_root: @constant_root
    )

    assert report[:valid]
    assert_equal 2, report[:expected_feature_count]
    assert_equal 1, report[:prepend_layer_count]
    assert_empty report[:missing_features]
    assert_empty report[:uninstalled_layers]
  end

  def test_rejects_missing_required_feature
    error = assert_raises(LvnRuntimePreflight::RuntimeMismatch) do
      LvnRuntimePreflight.verify!(
        loader_path: @loader_path,
        loaded_features: [@loader_path, @plain_feature_path],
        target_class: @target_class,
        constant_root: @constant_root
      )
    end

    assert_includes error.message, 'required feature is not loaded'
    assert_equal [@prepend_feature_path], error.report[:missing_features]
  end

  def test_rejects_detached_prepend_layer
    detached_class = Class.new

    error = assert_raises(LvnRuntimePreflight::RuntimeMismatch) do
      LvnRuntimePreflight.verify!(
        loader_path: @loader_path,
        loaded_features: complete_loaded_features,
        target_class: detached_class,
        constant_root: @constant_root
      )
    end

    assert_includes error.message, 'prepend layer is not installed'
    assert_equal 1, error.report[:uninstalled_layers].length
    assert_equal(
      'LocalVertexNormalizerExampleLayer',
      error.report[:uninstalled_layers].first[:name]
    )
  end

  def test_resolves_loader_from_loaded_features
    report = LvnRuntimePreflight.verify!(
      loaded_features: complete_loaded_features,
      target_class: @target_class,
      constant_root: @constant_root
    )

    assert_equal @loader_path, report[:loader_path]
    assert report[:loader_loaded]
  end

  private

  def complete_loaded_features
    [
      @plain_feature_path,
      @prepend_feature_path,
      @loader_path
    ]
  end
end
