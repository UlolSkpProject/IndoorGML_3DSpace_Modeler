# frozen_string_literal: true

# Compatibility launcher for Phase 6 corpus A/B regression.
#
# v4 removed the terminal autorun together with the module-closing tail and
# accidentally left one module unclosed. v5 never rewrites Ruby structure. It
# replaces exactly one standalone `BASE.run` line with a no-op, preserving every
# surrounding `end` byte-for-byte, then evaluates the corrected v4 launcher.
base_path = File.join(__dir__, 'lvn_corpus_ab_regression_probe_v4.rb')
source = File.binread(base_path).force_encoding(Encoding::UTF_8)
source = source.gsub("\r\n", "\n")

old_block = <<~'RUBY_SOURCE'
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
RUBY_SOURCE

new_block = <<~'RUBY_SOURCE'
      face_detail_autorun_pattern = /^[ \t]*BASE\.run[ \t]*$/
      face_detail_autorun_count =
        face_detail_source.scan(face_detail_autorun_pattern).length
      unless face_detail_autorun_count == 1
        raise(
          "Expected exactly one standalone BASE.run in #{face_detail_path}; " \
          "found #{face_detail_autorun_count}"
        )
      end
      face_detail_without_run = face_detail_source.sub(
        face_detail_autorun_pattern,
        '        nil # BASE.run suppressed by corpus A/B launcher'
      )
RUBY_SOURCE

unless source.include?(old_block)
  raise "Could not locate v4 face-detail autorun rewrite in #{base_path}"
end

patched = source.sub(old_block, new_block)
RubyVM::InstructionSequence.compile(patched, base_path)
TOPLEVEL_BINDING.eval(patched, base_path, 1)
