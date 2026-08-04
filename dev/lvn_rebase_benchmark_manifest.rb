# frozen_string_literal: true

require 'digest'
require 'json'
require 'time'
require_relative 'lvn_stage_detail_profile_benchmark'

# Rebuilds an existing LVN benchmark manifest against the currently opened,
# saved SketchUp model while preserving the exact target PID set and labels.
#
# The source manifest is never overwritten. This is intended for cases where the
# original benchmark model is no longer available but a stable replacement model
# must be used to compare multiple revisions on one identical geometry corpus.
module LvnRebaseBenchmarkManifest
  MANIFEST_SCHEMA = 'ulol.lvn.many_solids_benchmark.targets.v1'

  module_function

  def run(source_manifest_path:, output_path:, model: Sketchup.active_model)
    ensure_saved_model!(model)

    source_manifest_path = File.expand_path(source_manifest_path.to_s)
    output_path = File.expand_path(output_path.to_s)

    raise "Source manifest not found: #{source_manifest_path}" unless
      File.file?(source_manifest_path)
    if source_manifest_path.casecmp?(output_path)
      raise ArgumentError, 'output_path must differ from source_manifest_path'
    end

    manifest = JSON.parse(File.read(source_manifest_path, encoding: 'UTF-8'))
    unless manifest['schema'] == MANIFEST_SCHEMA
      raise "Unexpected manifest schema: #{manifest['schema'].inspect}"
    end

    source_targets = Array(manifest['targets'])
    raise 'Source manifest has no targets' if source_targets.empty?

    missing_pids = []
    targets = source_targets.map do |record|
      pid = record.fetch('pid').to_i
      entity = benchmark_helper(:resolve_top_level_entity, model, pid)
      unless entity
        missing_pids << pid
        next
      end

      updated = record.dup
      updated['pid'] = pid
      updated['geometry'] = geometry_summary(entity)
      updated['signature'] = benchmark_helper(:brep_signature, entity)
      updated
    end.compact

    unless missing_pids.empty?
      raise "Target entities missing from current model: #{missing_pids.inspect}"
    end

    rebased = manifest.dup
    rebased['model_path'] = model.path
    rebased['generated_at'] = Time.now.iso8601(3)
    rebased['targets'] = targets
    rebased['rebase'] = {
      'source_manifest_path' => source_manifest_path,
      'source_manifest_sha256' => Digest::SHA256.file(source_manifest_path).hexdigest,
      'rebased_at' => Time.now.iso8601(3),
      'target_count' => targets.length
    }

    directory = File.dirname(output_path)
    Dir.mkdir(directory) unless Dir.exist?(directory)
    File.open(output_path, 'w:UTF-8') do |file|
      file.write(JSON.pretty_generate(rebased))
      file.write("\n")
    end

    verification_targets = benchmark_helper(:manifest_targets, symbolize_keys(rebased))
    verification = benchmark_helper(:verify_target_set, model, verification_targets)
    unless verification[:missing_pids].empty? &&
           verification[:signature_mismatch_pids].empty?
      raise "Rebased manifest verification failed: #{verification.inspect}"
    end

    $lvn_rebased_manifest_path = output_path
    $lvn_rebased_manifest = rebased

    puts "[LVN MANIFEST REBASE] targets=#{targets.length}"
    puts "[LVN MANIFEST REBASE] model=#{model.path}"
    puts "[LVN MANIFEST REBASE] output=#{output_path}"
    puts '[LVN MANIFEST REBASE] verification=OK'
    nil
  rescue StandardError => error
    warn "[LVN MANIFEST REBASE] FAILED #{error.class}: #{error.message}"
    warn Array(error.backtrace).first(20).join("\n")
    nil
  end

  def benchmark_helper(name, *arguments)
    LvnStageDetailProfileBenchmark.send(name, *arguments)
  end
  private_class_method :benchmark_helper

  def ensure_saved_model!(model)
    path = model&.path.to_s
    raise 'Open and save the benchmark model first' if path.empty?
    raise "Model file not found: #{path}" unless File.file?(path)
  end
  private_class_method :ensure_saved_model!

  def geometry_summary(entity)
    entities = entity.definition.entities
    faces = entities.grep(Sketchup::Face).select(&:valid?)
    edges = entities.grep(Sketchup::Edge).select(&:valid?)
    vertices = edges.flat_map(&:vertices).select(&:valid?).uniq

    {
      'faces' => faces.length,
      'edges' => edges.length,
      'vertices' => vertices.length,
      'manifold' => entity.respond_to?(:manifold?) && entity.manifold? == true
    }
  end
  private_class_method :geometry_summary

  def symbolize_keys(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, item), result|
        result[key.to_sym] = symbolize_keys(item)
      end
    when Array
      value.map { |item| symbolize_keys(item) }
    else
      value
    end
  end
  private_class_method :symbolize_keys
end

nil
