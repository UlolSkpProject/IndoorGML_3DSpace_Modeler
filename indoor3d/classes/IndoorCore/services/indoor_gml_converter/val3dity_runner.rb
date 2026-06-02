# frozen_string_literal: true

require 'fileutils'
require 'fiddle'
require 'json'
require 'rbconfig'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class Val3dityRunner
          VENDOR_ROOT = File.expand_path('../../../../assets/vendor/val3dity-windows-x64-v2.2.0', __dir__)

          attr_reader :report_json_path, :report_html_path

          def initialize(gml_path)
            @gml_path = File.expand_path(gml_path)
            @work_dir = TempExporter.output_root
            @report_json_path = File.join(@work_dir, 'report.json')
            @report_dir = File.join(@work_dir, 'report')
            @report_html_path = File.join(@report_dir, 'report.html')
          end

          def validate(progress: nil)
            ensure_runtime_files!
            FileUtils.rm_f(@report_json_path)
            progress&.running(:val3dity)
            run_val3dity!
            progress&.complete(:val3dity)
            normalize_report_encoding
            progress&.running(:report)
            raw_report = JSON.parse(File.read(@report_json_path, encoding: 'UTF-8'))
            progress&.complete(:report)
            progress&.running(:report_view)
            prepare_html_report(raw_report)
            progress&.complete(:report_view)
            raw_report['validity'] == true
          end

          private

          def ensure_runtime_files!
            raise "val3dity.exe was not found:\n#{exe_path}" unless File.exist?(exe_path)
            raise "val3dity report template was not found:\n#{report_template_dir}" unless Dir.exist?(report_template_dir)
            raise "GML file was not found:\n#{@gml_path}" unless File.exist?(@gml_path)

            FileUtils.mkdir_p(@work_dir)
          end

          def run_val3dity!
            Dir.chdir(VENDOR_ROOT) do
              run_hidden([exe_path, @gml_path, '--verbose', '-r', @report_json_path])
            end
            return if File.exist?(@report_json_path)

            raise 'val3dity failed to create report.json.'
          end

          def normalize_report_encoding
            content = File.binread(@report_json_path)
            content = decode_report_content(content)
            File.write(@report_json_path, content, encoding: 'UTF-8')
          end

          def prepare_html_report(raw_report)
            FileUtils.rm_rf(@report_dir)
            FileUtils.cp_r(report_template_dir, @report_dir)
            File.write(File.join(@report_dir, 'report.js'), "var report = #{JSON.pretty_generate(to_report_js(raw_report))}\n", encoding: 'UTF-8')
          end

          def to_report_js(raw_report)
            features = Array(raw_report['features']).map do |feature|
              feature.merge(
                'errors_feature' => empty_to_nil(feature['errors']),
                'primitives' => convert_primitives(feature['primitives'])
              )
            end

            {
              'errors_dataset' => empty_to_nil(raw_report['dataset_errors']),
              'features' => features,
              'input_file' => raw_report['input_file'],
              'invalid_features' => invalid_count(raw_report['features_overview']),
              'invalid_primitives' => invalid_count(raw_report['primitives_overview']),
              'overlap_tol' => raw_report.dig('parameters', 'overlap_tol'),
              'overview_errors' => empty_to_nil(raw_report['all_errors']),
              'overview_features' => overview_types(raw_report['features_overview']),
              'overview_primitives' => overview_types(raw_report['primitives_overview']),
              'planarity_d2p_tol' => raw_report.dig('parameters', 'planarity_d2p_tol'),
              'planarity_n_tol' => raw_report.dig('parameters', 'planarity_n_tol'),
              'snap_tol' => raw_report.dig('parameters', 'snap_tol'),
              'time' => raw_report['time'],
              'total_features' => total_count(raw_report['features_overview']),
              'total_primitives' => total_count(raw_report['primitives_overview']),
              'type' => 'val3dity report',
              'val3dity_version' => raw_report['val3dity_version'],
              'valid_features' => valid_count(raw_report['features_overview']),
              'valid_primitives' => valid_count(raw_report['primitives_overview'])
            }
          end

          def convert_primitives(primitives)
            return nil if primitives.nil?

            primitives.map do |primitive|
              primitive.merge('errors' => empty_to_nil(primitive['errors']))
            end
          end

          def overview_types(overview)
            types = Array(overview).map { |item| item['type'] }
            types.empty? ? nil : types
          end

          def total_count(overview)
            Array(overview).sum { |item| item['total'].to_i }
          end

          def valid_count(overview)
            Array(overview).sum { |item| item['valid'].to_i }
          end

          def invalid_count(overview)
            total_count(overview) - valid_count(overview)
          end

          def empty_to_nil(value)
            value.respond_to?(:empty?) && value.empty? ? nil : value
          end

          def decode_report_content(content)
            utf8 = content.dup.force_encoding('UTF-8')
            return utf8 if utf8.valid_encoding?

            content.force_encoding(report_source_encoding).encode('UTF-8')
          rescue EncodingError
            content.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
          end

          def report_source_encoding
            @report_source_encoding ||= %w[CP949 Windows-949 EUC-KR].filter_map do |name|
              Encoding.find(name)
            rescue ArgumentError
              nil
            end.first || Encoding.default_external
          end

          def exe_path
            File.join(VENDOR_ROOT, 'val3dity.exe')
          end

          def report_template_dir
            File.join(VENDOR_ROOT, 'report')
          end

          def run_hidden(args)
            if windows?
              run_hidden_windows(args)
            else
              system(*args)
            end
          end

          def run_hidden_windows(args)
            command = wide_string(args.map { |arg| command_quote(arg) }.join(' '))
            current_dir = wide_string(VENDOR_ROOT)
            startup_info = [
              104, 0, 0, 0,
              0, 0, 0, 0, 0, 0, 0, 0x00000001,
              0, 0,
              0, 0, 0, 0
            ].pack('L<x4Q<Q<Q<L<L<L<L<L<L<L<L<S<Sx4Q<Q<Q<Q<')
            process_info = [0, 0, 0, 0].pack('Q<Q<L<L<')

            created = create_process_w.call(
              0,
              command,
              0,
              0,
              0,
              0x08000000,
              0,
              current_dir,
              startup_info,
              process_info
            )
            raise "CreateProcessW failed: #{Fiddle.last_error}" if created == 0

            process_handle, thread_handle = process_info.unpack('Q<Q<')
            wait_for_single_object.call(process_handle, -1)
          ensure
            close_handle.call(thread_handle) if thread_handle.to_i.positive?
            close_handle.call(process_handle) if process_handle.to_i.positive?
          end

          def create_process_w
            @create_process_w ||= Fiddle::Function.new(
              kernel32['CreateProcessW'],
              [
                Fiddle::TYPE_VOIDP,
                Fiddle::TYPE_VOIDP,
                Fiddle::TYPE_VOIDP,
                Fiddle::TYPE_VOIDP,
                Fiddle::TYPE_INT,
                Fiddle::TYPE_LONG,
                Fiddle::TYPE_VOIDP,
                Fiddle::TYPE_VOIDP,
                Fiddle::TYPE_VOIDP,
                Fiddle::TYPE_VOIDP
              ],
              Fiddle::TYPE_INT
            )
          end

          def wait_for_single_object
            @wait_for_single_object ||= Fiddle::Function.new(
              kernel32['WaitForSingleObject'],
              [Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG],
              Fiddle::TYPE_LONG
            )
          end

          def close_handle
            @close_handle ||= Fiddle::Function.new(
              kernel32['CloseHandle'],
              [Fiddle::TYPE_VOIDP],
              Fiddle::TYPE_INT
            )
          end

          def kernel32
            @kernel32 ||= Fiddle.dlopen('kernel32')
          end

          def command_quote(value)
            %("#{value.to_s.gsub('"', '\"')}")
          end

          def wide_string(value)
            "#{value}\x00".encode('UTF-16LE')
          end

          def windows?
            RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/i
          end
        end

      end
    end
  end
end
