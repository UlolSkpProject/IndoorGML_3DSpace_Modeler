# frozen_string_literal: true

require 'fileutils'
require 'tempfile'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class AtomicFileWriter
          def self.write(path, content, writer: nil)
            destination = File.expand_path(path)
            directory = File.dirname(destination)
            FileUtils.mkdir_p(directory)

            Tempfile.create(['.indoorgml-', '.tmp'], directory) do |file|
              file.binmode
              writer ? writer.call(file, content) : file.write(content)
              file.flush
              file.fsync
              file.close
              File.rename(file.path, destination)
            end
            destination
          end
        end
      end
    end
  end
end
