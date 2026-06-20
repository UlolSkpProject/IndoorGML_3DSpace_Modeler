# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module Utils
      module HtmlHelpers
        def escape_html(value)
          value.to_s
               .gsub('&', '&amp;')
               .gsub('<', '&lt;')
               .gsub('>', '&gt;')
              #  .gsub('"', '&quot;')
        end
      end
    end
  end
end
