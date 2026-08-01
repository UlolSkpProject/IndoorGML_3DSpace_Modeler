# frozen_string_literal: true

# Development-only launcher for diagnosing blocker-aware ear-heap exhaustion.
#
# The blocker probe remains unchanged. This launcher applies two conservative
# fixes before evaluating it:
# 1. Qualify ReconstructionError through LocalVertexNormalizer.
# 2. When the optimized heap is exhausted, run the established full-reference
#    selector. Continue only with that exact reference ear; if the reference
#    also finds no ear, fail explicitly.
module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module LvnBridgeBlockedEarRecoveryProbe
        module_function

        def normalized_source(path)
          File.binread(path)
              .force_encoding(Encoding::UTF_8)
              .gsub(/\r\n?/, "\n")
        end
      end
    end
  end
end

blocked_probe_path = File.join(__dir__, 'lvn_bridge_blocked_ear_probe.rb')
source =
  ULOL::Indoor3DGmlModeler::IndoorCore::
    LvnBridgeBlockedEarRecoveryProbe.normalized_source(blocked_probe_path)

old_exhaustion = <<-'RUBY'
              unless selected
                raise ReconstructionError,
                      "Could not triangulate exact coplanar patch boundary: " \
                      "#{remaining.inspect}"
              end
RUBY

new_exhaustion = <<-'RUBY'
              unless selected
                stats[:exhaustion_reference_checks] =
                  stats[:exhaustion_reference_checks].to_i + 1
                recovery_reference = reference
                unless recovery_reference
                  recovery_reference = incremental_ear_reference_selection(
                    remaining,
                    projected,
                    remaining_ids,
                    drop_axis
                  )
                  stats[:reference_checks] += 1
                  stats[:reference_quality_evaluations] +=
                    recovery_reference[:candidate_count]
                  stats[:reference_exact_ear_calls] +=
                    recovery_reference[:exact_ear_calls]
                end

                recovery_id = recovery_reference[:vertex_id]
                recovery_index = recovery_id && index_by_id[recovery_id]
                if recovery_id && recovery_index
                  selected = [
                    recovery_reference[:quality],
                    recovery_id,
                    versions[recovery_id],
                    recovery_index
                  ]
                  reference = recovery_reference
                  stats[:exhaustion_reference_recoveries] =
                    stats[:exhaustion_reference_recoveries].to_i + 1
                  probe.log(
                    'BLOCKED_EAR_EXHAUSTION_REFERENCE_RECOVERY',
                    {
                      clipped_triangle_count: attempts,
                      remaining_vertex_count: remaining.length,
                      selected_vertex_id: recovery_id,
                      selected_polygon_index: recovery_index,
                      reference_candidate_count:
                        recovery_reference[:candidate_count],
                      reference_exact_ear_calls:
                        recovery_reference[:exact_ear_calls],
                      blocked_entry_count: blocked_entries.length
                    }
                  )
                else
                  stats[:exhaustion_reference_misses] =
                    stats[:exhaustion_reference_misses].to_i + 1
                  probe.log(
                    'BLOCKED_EAR_EXHAUSTION_REFERENCE_MISS',
                    {
                      clipped_triangle_count: attempts,
                      remaining_vertex_count: remaining.length,
                      reference_candidate_count:
                        recovery_reference[:candidate_count],
                      reference_exact_ear_calls:
                        recovery_reference[:exact_ear_calls],
                      blocked_entry_count: blocked_entries.length
                    },
                    level: 'ERROR'
                  )
                  raise LocalVertexNormalizer::ReconstructionError,
                        'Full reference also found no exact ear after blocker ' \
                        "heap exhaustion: remaining=#{remaining.length} " \
                        "blocked=#{blocked_entries.length}"
                end
              end
RUBY

unless source.include?(old_exhaustion)
  raise "Could not locate blocker heap exhaustion block in #{blocked_probe_path}"
end

patched = source.sub(old_exhaustion, new_exhaustion)
patched = patched.gsub(
  /raise ReconstructionError,/,
  'raise LocalVertexNormalizer::ReconstructionError,'
)

RubyVM::InstructionSequence.compile(patched, blocked_probe_path)
TOPLEVEL_BINDING.eval(patched, blocked_probe_path, 1)
