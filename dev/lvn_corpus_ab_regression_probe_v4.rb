# frozen_string_literal: true

# Compatibility launcher for Phase 6 corpus A/B regression.
#
# v4 adds two preflight guarantees:
# 1. Refuse before loading any dependency when the corpus selection is empty.
# 2. Preload the face-detail diagnostic definition with its terminal BASE.run
#    removed, preventing an unrelated large-solid diagnostic from auto-running
#    while the optimized bridge/ear dependency stack is installed.
model = Sketchup.active_model
if model.selection.empty?
  raise <<~MESSAGE.strip
    LVN corpus A/B probe requires the selected corpus before loading. Select the
    LVN-unprocessed solids (expected corpus: 1,618 entities) and run this launcher
    once in a fresh SketchUp session.
  MESSAGE
end

base_path = File.join(__dir__, 'lvn_corpus_ab_regression_probe.rb')
source = File.binread(base_path).force_encoding(Encoding::UTF_8)
source = source.gsub("\r\n", "\n")

old_reference_block = <<~'RUBY_SOURCE'
  reference_remove_coplanar =
    normalizer_class.instance_method(:remove_coplanar_shared_edges)
  reference_source_location = reference_remove_coplanar.source_location
RUBY_SOURCE

new_reference_block = <<~'RUBY_SOURCE'
  direct_class_method = lambda do |klass, name|
    method = klass.instance_method(name)
    chain = []
    while method
      chain << {
        owner: method.owner,
        source_location: method.source_location
      }
      break if method.owner == klass
      method = method.super_method
    end
    unless method && method.owner == klass
      raise(
        "Could not resolve #{klass}##{name} below prepended wrappers: " \
        "#{chain.map { |entry| [entry[:owner].to_s, entry[:source_location]] }.inspect}"
      )
    end
    method
  end

  reference_remove_coplanar =
    direct_class_method.call(normalizer_class, :remove_coplanar_shared_edges)
  reference_source_location = reference_remove_coplanar.source_location
RUBY_SOURCE

old_dependency_block = <<~'RUBY_SOURCE'
  dependency_model = Sketchup.active_model
  dependency_selection = dependency_model.selection.to_a
  dependency_stdout = $stdout
  dependency_stderr = $stderr
  begin
    dependency_model.selection.clear
    $stdout = StringIO.new
    $stderr = StringIO.new
    load File.join(__dir__, 'lvn_coplanar_incremental_topology_probe_v2.rb')
  ensure
    $stdout = dependency_stdout
    $stderr = dependency_stderr
    dependency_model.selection.clear
    dependency_selection.each do |entity|
      dependency_model.selection.add(entity) if
        entity.respond_to?(:valid?) && entity.valid?
    end
  end
RUBY_SOURCE

new_dependency_block = <<~'RUBY_SOURCE'
  dependency_model = Sketchup.active_model
  dependency_selection = dependency_model.selection.to_a
  dependency_stdout = $stdout
  dependency_stderr = $stderr
  begin
    dependency_model.selection.clear
    $stdout = StringIO.new
    $stderr = StringIO.new

    face_detail_path =
      File.join(__dir__, 'lvn_large_solid_face_detail_log_probe.rb')
    unless core.const_defined?(:LvnLargeSolidFaceDetailLogProbe, false)
      face_detail_source =
        File.binread(face_detail_path)
            .force_encoding(Encoding::UTF_8)
            .gsub(/\r\n?/, "\n")
      face_detail_autorun_pattern = %r{
        \n\s*reset_progress\s*\n\s*BASE\.run\s*\n
        \s*end\s*\n\s*end\s*\n\s*end\s*\n\s*end\s*\z
      }mx
      face_detail_without_run =
        face_detail_source.sub(face_detail_autorun_pattern, <<~'TAIL')

              reset_progress
            end
          end
        end
      TAIL
      if face_detail_without_run == face_detail_source
        raise "Could not suppress default run in #{face_detail_path}"
      end
      RubyVM::InstructionSequence.compile(
        face_detail_without_run,
        face_detail_path
      )
      TOPLEVEL_BINDING.eval(face_detail_without_run, face_detail_path, 1)
    end

    load File.join(__dir__, 'lvn_coplanar_incremental_topology_probe_v2.rb')
  ensure
    $stdout = dependency_stdout
    $stderr = dependency_stderr
    dependency_model.selection.clear
    dependency_selection.each do |entity|
      dependency_model.selection.add(entity) if
        entity.respond_to?(:valid?) && entity.valid?
    end
  end
RUBY_SOURCE

old_optimized_block = <<~'RUBY_SOURCE'
  optimized_remove_coplanar =
    normalizer_class.instance_method(:remove_coplanar_shared_edges)
  optimized_source_location = optimized_remove_coplanar.source_location
  if optimized_source_location == reference_source_location
    raise 'Incremental coplanar implementation was not installed'
  end
RUBY_SOURCE

new_optimized_block = <<~'RUBY_SOURCE'
  incremental_implementation =
    core::LvnCoplanarIncrementalTopologyProbe::Implementation
  incremental_methods =
    incremental_implementation.private_instance_methods(false)
  required_incremental_methods = %i[
    remove_coplanar_shared_edges incremental_coplanar_affected_before
    incremental_coplanar_affected_after incremental_coplanar_incident
    incremental_coplanar_unique incremental_coplanar_face_context
    incremental_coplanar_faces_after incremental_coplanar_edge_counts
    incremental_coplanar_apply_delta incremental_coplanar_reference!
  ]
  missing_incremental_methods =
    required_incremental_methods - incremental_methods
  unless missing_incremental_methods.empty?
    raise(
      "Incremental coplanar methods missing after dependency load: " \
      "#{missing_incremental_methods.inspect}"
    )
  end

  normalizer_class.class_eval do
    incremental_methods.each do |name|
      define_method(name, incremental_implementation.instance_method(name))
      private name
    end
  end

  optimized_remove_coplanar =
    incremental_implementation.instance_method(:remove_coplanar_shared_edges)
  optimized_source_location = optimized_remove_coplanar.source_location
  installed_remove_coplanar =
    direct_class_method.call(normalizer_class, :remove_coplanar_shared_edges)
  installed_source_location = installed_remove_coplanar.source_location
  unless installed_source_location == optimized_source_location
    raise(
      "Incremental coplanar underlying implementation verification failed: " \
      "implementation=#{optimized_source_location.inspect} " \
      "installed=#{installed_source_location.inspect} " \
      "production=#{reference_source_location.inspect}"
    )
  end
RUBY_SOURCE

unless source.include?(old_reference_block)
  raise "Could not locate production method capture block in #{base_path}"
end
unless source.include?(old_dependency_block)
  raise "Could not locate dependency load block in #{base_path}"
end
unless source.include?(old_optimized_block)
  raise "Could not locate optimized installation block in #{base_path}"
end

patched = source.sub(old_reference_block, new_reference_block)
patched = patched.sub(old_dependency_block, new_dependency_block)
patched = patched.sub(old_optimized_block, new_optimized_block)
RubyVM::InstructionSequence.compile(patched, base_path)
TOPLEVEL_BINDING.eval(patched, base_path, 1)
