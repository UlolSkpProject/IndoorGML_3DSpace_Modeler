# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class ValidationRunWorkspace
          attr_reader :root_dir
          attr_reader :gml_path
          attr_reader :report_json_path
          attr_reader :report_dir
          attr_reader :report_html_path

          def self.create(base_dir: GmlExporter.output_root)
            parent = File.join(base_dir, 'validation-runs')
            FileUtils.mkdir_p(parent)
            token_prefix = "run-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{$$}-"
            new(Dir.mktmpdir(token_prefix, parent))
          end

          def initialize(root_dir)
            @root_dir = File.expand_path(root_dir)
            @gml_path = File.join(@root_dir, 'input.gml')
            @report_json_path = File.join(@root_dir, 'report.json')
            @report_dir = File.join(@root_dir, 'report')
            @report_html_path = File.join(@report_dir, 'report.html')
            @cleaned = false
          end

          def cleanup
            return false if @cleaned

            FileUtils.rm_rf(@root_dir)
            @cleaned = true
            true
          end

          def cleaned?
            @cleaned == true
          end
        end
      end
    end
  end
end
