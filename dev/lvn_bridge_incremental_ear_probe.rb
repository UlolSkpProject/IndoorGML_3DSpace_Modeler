# frozen_string_literal: true

probe_path = File.join(__dir__, 'lvn_bridge_nearest_first_probe.rb')
source = File.binread(probe_path)
             .force_encoding(Encoding::UTF_8)
             .gsub(/\r\n?/, "\n")

old_install = <<-'RUBY'
        LocalVertexNormalizer.class_eval do
          define_method(
            :triangulate_exact_weak_polygon,
            IncrementalEarTriangulation.instance_method(
              :triangulate_exact_weak_polygon
            )
          )
          private :triangulate_exact_weak_polygon
        end
RUBY

new_install = <<-'RUBY'
        incremental_method_names =
          IncrementalEarTriangulation.private_instance_methods(false)
        required_incremental_method_names = [
          :triangulate_exact_weak_polygon,
          :incremental_ear_reference_due?,
          :incremental_ear_reference_selection,
          :incremental_ear_refresh_candidate!,
          :incremental_ear_heap_higher_priority?,
          :incremental_ear_heap_push!,
          :incremental_ear_heap_pop!
        ]
        missing_incremental_method_names =
          required_incremental_method_names - incremental_method_names
        unless missing_incremental_method_names.empty?
          raise "Incremental ear probe helper methods missing: " \
                "#{missing_incremental_method_names.inspect}"
        end

        LocalVertexNormalizer.class_eval do
          incremental_method_names.each do |method_name|
            define_method(
              method_name,
              IncrementalEarTriangulation.instance_method(method_name)
            )
            private method_name
          end
        end
RUBY

patched = source.sub(old_install, new_install)
if patched == source
  raise "Could not replace incremental ear installation block in #{probe_path}"
end

if defined?(RubyVM::InstructionSequence)
  RubyVM::InstructionSequence.compile(patched, probe_path)
end

TOPLEVEL_BINDING.eval(patched, probe_path, 1)
