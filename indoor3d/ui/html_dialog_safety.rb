# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module HtmlDialogSafety
        EXTERNAL_FILE_DROP_GUARD_PATH = File.join(
          __dir__,
          'html',
          'shared',
          'external_file_drop_guard.js'
        ).freeze

        class << self
          def external_file_drop_guard_script
            @external_file_drop_guard_script ||= File.read(
              EXTERNAL_FILE_DROP_GUARD_PATH,
              mode: 'r:BOM|UTF-8'
            ).freeze
          end

          def external_file_drop_guard_script_tag
            <<~HTML
              <script>
              #{external_file_drop_guard_script}
              initExternalFileDropGuard();
              </script>
            HTML
          end

          def inject_external_file_drop_guard(html)
            source = html.to_s
            guard = external_file_drop_guard_script_tag

            if source.include?('</head>')
              source.sub('</head>', "#{guard}</head>")
            elsif source.include?('</body>')
              source.sub('</body>', "#{guard}</body>")
            else
              "#{source}\n#{guard}"
            end
          end
        end
      end
    end
  end
end
