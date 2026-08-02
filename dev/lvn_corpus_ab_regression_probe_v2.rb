# frozen_string_literal: true

# Compatibility launcher for lvn_corpus_ab_regression_probe.rb.
#
# The original runner inferred successful installation by comparing the
# production and optimized source_location values. That is not a reliable
# installation test when UnboundMethod bodies are copied with define_method and
# multiple dev launchers are evaluated in one dependency chain.
#
# This launcher preserves the production reference captured before dependency
# loading, but explicitly reinstalls every method from the incremental
# Implementation module and captures the optimized remove method directly from
# that module. The installed class method is then checked against the
# implementation source, not merely against the production source.
base_path = File.join(__dir__, 'lvn_corpus_ab_regression_probe.rb')
source = File.binread(base_path).force_encoding(Encoding::UTF_8)
source = source.gsub("\r\n", "\n")

old_block = <<~'RUBY'
  optimized_remove_coplanar =
    normalizer_class.instance_method(:remove_coplanar_shared_edges)
  optimized_source_location = optimized_remove_coplanar.source_location
  if optimized_source_location == reference_source_location
    raise 'Incremental coplanar implementation was not installed'
  end
RUBY

new_block = <<~'RUBY'
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
    normalizer_class.instance_method(:remove_coplanar_shared_edges)
  installed_source_location = installed_remove_coplanar.source_location
  unless installed_source_location == optimized_source_location
    raise(
      "Incremental coplanar implementation install verification failed: " \
      "implementation=#{optimized_source_location.inspect} " \
      "installed=#{installed_source_location.inspect} " \
      "production=#{reference_source_location.inspect}"
    )
  end
RUBY

unless source.include?(old_block)
  raise "Could not locate installation verification block in #{base_path}"
end

patched = source.sub(old_block, new_block)
RubyVM::InstructionSequence.compile(patched, base_path)
TOPLEVEL_BINDING.eval(patched, base_path, 1)
