# frozen_string_literal: true

require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

require_relative '../indoor3d/export/atomic_file_writer'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class AtomicFileWriterTest < Minitest::Test
          def setup
            @directory = Dir.mktmpdir('indoorgml-atomic-write-')
            @path = File.join(@directory, 'delivery.gml')
          end

          def teardown
            FileUtils.rm_rf(@directory)
          end

          def test_replaces_existing_file_after_complete_write
            File.write(@path, 'previous delivery')

            AtomicFileWriter.write(@path, 'new delivery')

            assert_equal 'new delivery', File.binread(@path)
            assert_empty temporary_files
          end

          def test_write_failure_preserves_existing_file_byte_for_byte
            original = "previous\x00delivery".b
            File.binwrite(@path, original)

            assert_raises(IOError) do
              AtomicFileWriter.write(@path, 'partial replacement', writer: lambda { |file, content|
                file.write(content.byteslice(0, 7))
                raise IOError, 'injected disk failure'
              })
            end

            assert_equal original, File.binread(@path)
            assert_empty temporary_files
          end

          private

          def temporary_files
            Dir.glob(File.join(@directory, '.indoorgml-*.tmp'))
          end
        end
      end
    end
  end
end
