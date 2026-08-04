# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module Val3dityV3Runtime
          DISABLE_ENV = 'INDOORGML_DISABLE_V3_RECHECK'

          class << self
            attr_reader :load_error

            def enabled?
              ENV[DISABLE_ENV].to_s != '1'
            end

            def available?
              enabled? && @loaded == true &&
                defined?(Val3dityRecheckV3MeshProxy::Rechecker)
            end

            def mark_loaded!
              @loaded = true
              @load_error = nil
            end

            def mark_failed!(error)
              @loaded = false
              @load_error = error
            end
          end
        end
      end
    end
  end
end

begin
  require_relative '../../dev/val3dity_recheck_v3_mesh_proxy_non_solid_fallback'
  ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityV3Runtime.mark_loaded!
rescue LoadError, SyntaxError, StandardError => e
  ULOL::Indoor3DGmlModeler::IndoorCore::IndoorGmlConverter::Val3dityV3Runtime.mark_failed!(e)
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityRunner
          class << self
            def v3_overlap_recheck_enabled?
              Val3dityV3Runtime.available?
            end

            def v3_overlap_recheck_load_error
              Val3dityV3Runtime.load_error
            end
          end

          unless private_method_defined?(:overlap_geometry_rechecker_without_v3)
            alias_method :overlap_geometry_rechecker_without_v3,
                         :overlap_geometry_rechecker
          end

          private

          def overlap_geometry_rechecker
            return overlap_geometry_rechecker_without_v3 unless
              Val3dityV3Runtime.available?

            indoor_model = @indoor_model || IndoorModel.current
            @overlap_geometry_rechecker ||=
              Val3dityRecheckV3MeshProxy::Rechecker.new(
                indoor_model: indoor_model,
                model: @model || indoor_model&.model,
                tolerance: OVERLAP_RECHECK_TOLERANCE,
                logger: IndoorCore::Logger
              )
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] v3 overlap rechecker initialization failed; " \
              "using original rechecker: #{e.class}: #{e.message}"
            )
            @overlap_geometry_rechecker = nil
            overlap_geometry_rechecker_without_v3
          end
        end

        if Val3dityV3Runtime.available?
          IndoorCore::Logger.puts(
            '[IndoorGML] val3dity 701/704 recheck mode: ' \
            'v3 clipped-mesh proxy with original full-recheck fallback'
          )
        elsif Val3dityV3Runtime.enabled?
          error = Val3dityV3Runtime.load_error
          IndoorCore::Logger.puts(
            '[IndoorGML] v3 overlap recheck unavailable; original rechecker retained' \
            "#{error ? ": #{error.class}: #{error.message}" : ''}"
          )
        else
          IndoorCore::Logger.puts(
            '[IndoorGML] v3 overlap recheck disabled by ' \
            "#{Val3dityV3Runtime::DISABLE_ENV}=1; original rechecker retained"
          )
        end
      end
    end
  end
end
