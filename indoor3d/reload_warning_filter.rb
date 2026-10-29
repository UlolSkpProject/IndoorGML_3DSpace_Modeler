# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    # Development reloads intentionally reopen classes and replace constants.
    # Keep unrelated Ruby warnings visible while hiding only the two-line
    # constant-redefinition warning emitted for files in this extension.
    module ReloadWarningFilter
      @plugin_root = File.expand_path('..', __dir__).tr('\\', '/').downcase

      module_function

      def suppress?(message)
        text = message.to_s.tr('\\', '/').downcase
        return false unless text.include?(@plugin_root)

        text.include?('already initialized constant') ||
          text.include?('previous definition of')
      end
    end
  end
end

module Warning
  class << self
    unless method_defined?(:indoorgml_warn_without_reload_filter)
      alias_method :indoorgml_warn_without_reload_filter, :warn
    end

    def warn(message, **options)
      return if ULOL::Indoor3DGmlModeler::ReloadWarningFilter.suppress?(message)

      indoorgml_warn_without_reload_filter(message, **options)
    end
  end
end
