# frozen_string_literal: true

# Verifies that the LocalVertexNormalizer runtime loaded in SketchUp matches the
# current aggregate loader on disk before a benchmark mutates any model state.
#
# The check is intentionally generic:
# - every direct require_relative entry in the aggregate loader must exist;
# - every corresponding feature must already be present in $LOADED_FEATURES;
# - every LocalVertexNormalizer* layer installed with bare `prepend` must still
#   be present in the current LocalVertexNormalizer ancestor chain.
#
# This catches stale SketchUp sessions after git checkout/pull operations as well
# as class recreation that leaves previously loaded prepend modules detached.
module LvnRuntimePreflight
  LOADER_SUFFIX = '/indoor3d/application/local_vertex_normalizer.rb'
  REQUIRE_RELATIVE_PATTERN =
    /^\s*require_relative\s*(?:\(\s*)?['"]([^'"]+)['"]\s*\)?/
  PREPEND_PATTERN =
    /^\s*prepend\s+([A-Z]\w*(?:::[A-Z]\w*)*)\b/

  class RuntimeMismatch < StandardError
    attr_reader :report

    def initialize(message, report)
      @report = report
      super(message)
    end
  end

  module_function

  def verify!(
    loader_path: nil,
    loaded_features: $LOADED_FEATURES,
    target_class: default_target_class,
    constant_root: default_constant_root
  )
    report = inspect_runtime(
      loader_path: loader_path,
      loaded_features: loaded_features,
      target_class: target_class,
      constant_root: constant_root
    )

    return report if report[:valid]

    raise RuntimeMismatch.new(failure_message(report), report)
  end

  def inspect_runtime(
    loader_path: nil,
    loaded_features: $LOADED_FEATURES,
    target_class: default_target_class,
    constant_root: default_constant_root
  )
    features = Array(loaded_features).map(&:to_s)
    loader_candidates = find_loader_candidates(features)
    resolved_loader = loader_path && File.expand_path(loader_path.to_s)
    resolved_loader ||= loader_candidates.first if loader_candidates.length == 1

    loader_exists = resolved_loader && File.file?(resolved_loader)
    normalized_loaded = features.each_with_object({}) do |path, index|
      index[normalize_path(path)] = true
    end
    loader_loaded =
      resolved_loader && normalized_loaded.key?(normalize_path(resolved_loader))

    expected_features =
      loader_exists ? aggregate_required_features(resolved_loader) : []
    missing_files = expected_features.reject { |path| File.file?(path) }
    missing_features = expected_features.reject do |path|
      normalized_loaded.key?(normalize_path(path))
    end

    layer_records = discover_prepend_layers(
      expected_features,
      target_class: target_class,
      constant_root: constant_root
    )
    missing_layer_constants = layer_records.select do |record|
      !record[:constant_exists]
    end
    uninstalled_layers = layer_records.select do |record|
      record[:constant_exists] && !record[:installed]
    end

    valid =
      loader_candidates.length <= 1 &&
      !resolved_loader.nil? &&
      loader_exists &&
      loader_loaded &&
      !expected_features.empty? &&
      missing_files.empty? &&
      missing_features.empty? &&
      missing_layer_constants.empty? &&
      uninstalled_layers.empty?

    {
      valid: valid,
      loader_path: resolved_loader,
      loader_candidates: loader_candidates,
      loader_exists: !!loader_exists,
      loader_loaded: !!loader_loaded,
      expected_feature_count: expected_features.length,
      expected_features: expected_features,
      missing_files: missing_files,
      missing_features: missing_features,
      prepend_layer_count: layer_records.length,
      prepend_layers: layer_records,
      missing_layer_constants: missing_layer_constants,
      uninstalled_layers: uninstalled_layers
    }
  end

  def print_report(report, io: $stdout)
    io.puts '=== LVN RUNTIME PREFLIGHT ==='
    io.puts "loader=#{report[:loader_path]}"
    io.puts "loader_loaded=#{report[:loader_loaded]}"
    io.puts "expected_features=#{report[:expected_feature_count]}"
    io.puts "missing_files=#{report[:missing_files].length}"
    io.puts "missing_features=#{report[:missing_features].length}"
    io.puts "prepend_layers=#{report[:prepend_layer_count]}"
    io.puts "missing_layer_constants=#{report[:missing_layer_constants].length}"
    io.puts "uninstalled_layers=#{report[:uninstalled_layers].length}"
    io.puts(report[:valid] ? 'LVN_RUNTIME_PREFLIGHT_OK' : 'LVN_RUNTIME_PREFLIGHT_FAILED')
    report
  end

  def find_loader_candidates(loaded_features)
    suffix = normalize_path_suffix(LOADER_SUFFIX)
    Array(loaded_features).filter_map do |path|
      expanded = File.expand_path(path.to_s)
      expanded if normalize_path(expanded).end_with?(suffix)
    rescue StandardError
      nil
    end.uniq
  end

  def aggregate_required_features(loader_path)
    directory = File.dirname(loader_path)
    File.readlines(loader_path, chomp: true).filter_map do |line|
      match = line.match(REQUIRE_RELATIVE_PATTERN)
      next unless match

      relative_path = match[1]
      relative_path += '.rb' if File.extname(relative_path).empty?
      File.expand_path(relative_path, directory)
    end.uniq
  end

  def discover_prepend_layers(features, target_class:, constant_root:)
    return [] unless target_class && constant_root

    records = {}

    Array(features).each do |path|
      next unless File.file?(path)

      File.foreach(path).with_index(1) do |line, line_number|
        match = line.match(PREPEND_PATTERN)
        next unless match

        constant_name = match[1]
        short_name = constant_name.split('::').last
        next unless short_name.start_with?('LocalVertexNormalizer')

        records[constant_name] ||= {
          name: constant_name,
          source_path: path,
          source_line: line_number
        }
      end
    end

    records.values.map do |record|
      exists, layer = resolve_constant(constant_root, record[:name])
      record.merge(
        constant_exists: exists,
        installed: exists && target_class.ancestors.include?(layer)
      )
    end
  end

  def resolve_constant(root, name)
    parts = name.sub(/^::/, '').split('::')
    roots = name.start_with?('::') || parts.first == 'ULOL' ? [Object] : [root, Object]

    roots.each do |candidate_root|
      current = candidate_root
      resolved = true

      parts.each do |part|
        unless current.const_defined?(part, false)
          resolved = false
          break
        end
        current = current.const_get(part, false)
      end

      return [true, current] if resolved
    rescue NameError
      next
    end

    [false, nil]
  end

  def failure_message(report)
    problems = []

    if report[:loader_candidates].length > 1
      problems << "multiple aggregate loaders are loaded: #{report[:loader_candidates].inspect}"
    end
    problems << 'aggregate loader could not be resolved' unless report[:loader_path]
    problems << "aggregate loader is missing: #{report[:loader_path]}" if
      report[:loader_path] && !report[:loader_exists]
    problems << "aggregate loader is not loaded: #{report[:loader_path]}" if
      report[:loader_path] && !report[:loader_loaded]
    problems << 'aggregate loader has no direct require_relative entries' if
      report[:loader_exists] && report[:expected_feature_count].zero?

    report[:missing_files].each do |path|
      problems << "required file is missing: #{path}"
    end
    report[:missing_features].each do |path|
      problems << "required feature is not loaded: #{path}"
    end
    report[:missing_layer_constants].each do |record|
      problems << "prepend layer constant is missing: #{record[:name]}"
    end
    report[:uninstalled_layers].each do |record|
      problems << "prepend layer is not installed: #{record[:name]}"
    end

    [
      'LVN runtime preflight failed before benchmark operation.',
      *problems.map { |problem| "- #{problem}" },
      '- Restart SketchUp after completing all Git checkout/pull operations.'
    ].join("\n")
  end

  def normalize_path(path)
    expanded = File.expand_path(path.to_s).tr('\\', '/')
    case_insensitive_paths? ? expanded.downcase : expanded
  rescue StandardError
    fallback = path.to_s.tr('\\', '/')
    case_insensitive_paths? ? fallback.downcase : fallback
  end

  def normalize_path_suffix(path)
    normalized = path.to_s.tr('\\', '/')
    case_insensitive_paths? ? normalized.downcase : normalized
  end

  def case_insensitive_paths?
    File::ALT_SEPARATOR == '\\' || RUBY_PLATFORM.match?(/mswin|mingw|cygwin/i)
  end

  def default_target_class
    ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
  rescue NameError
    nil
  end

  def default_constant_root
    ULOL::Indoor3DGmlModeler::IndoorCore
  rescue NameError
    nil
  end
end

nil
