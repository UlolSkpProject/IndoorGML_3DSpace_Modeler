# frozen_string_literal: true

# Compatibility launcher for lvn_corpus_ab_regression_probe.rb.
#
# LocalVertexNormalizer has a prepended debug-profiler wrapper for
# remove_coplanar_shared_edges. Class#instance_method therefore resolves to the
# wrapper, not to the implementation below it. This launcher follows
# UnboundMethod#super_method until it reaches the LocalVertexNormalizer-owned
# implementation, captures that as path A, and swaps only that underlying class
# implementation for path B. The profiler wrapper stays common to both paths.
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
unless source.include?(old_optimized_block)
  raise "Could not locate optimized installation block in #{base_path}"
end

patched = source.sub(old_reference_block, new_reference_block)
patched = patched.sub(old_optimized_block, new_optimized_block)
RubyVM::InstructionSequence.compile(patched, base_path)
TOPLEVEL_BINDING.eval(patched, base_path, 1)
