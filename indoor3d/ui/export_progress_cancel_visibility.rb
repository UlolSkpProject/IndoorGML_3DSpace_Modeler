# frozen_string_literal: true

require_relative 'export_progress_dialog'
require_relative '../validity/val3dity_runner'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        module ExportProgressCancellableIntegration
          def initialize(...)
            super
            @cancellable = false
          end

          def cancellable(value = true)
            @cancellable = value == true
            send(
              :execute_or_queue,
              "setCancellable(#{@cancellable ? 'true' : 'false'});"
            )
            @cancellable
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] Export progress cancellable update failed: #{e.class}: #{e.message}"
            )
            false
          end

          def result(**options)
            cancellable(false)
            super
          end

          def on_cancel(&block)
            return super unless block

            super do
              next false unless @cancellable == true

              block.call
            end
          end

          def close
            @cancellable = false
            super
          end

          private

          def reset_progress_state
            super
            @cancellable = false
          end

          def replay_state
            super
            @dialog.execute_script(
              "setCancellable(#{@cancellable == true ? 'true' : 'false'});"
            )
          end
        end

        module Val3dityCancellableProgressIntegration
          def start(progress: nil, **options, &callback)
            @validation_cancellable_progress = progress
            session = super
            set_validation_progress_cancellable(
              progress,
              cancellable_val3dity_session?(session)
            )
            session
          rescue StandardError
            set_validation_progress_cancellable(progress, false)
            raise
          end

          private

          def build_result_after_process(exit_code, progress = nil, **options)
            set_validation_progress_cancellable(progress, false)
            super
          end

          def error_result(error)
            set_validation_progress_cancellable(
              @validation_cancellable_progress,
              false
            )
            super
          end

          def cancellable_val3dity_session?(session)
            !session.nil? && session.respond_to?(:terminate)
          rescue StandardError
            false
          end

          def set_validation_progress_cancellable(progress, value)
            progress.cancellable(value == true) if progress&.respond_to?(:cancellable)
            @validation_cancellable_progress = nil unless value == true
            value == true
          rescue StandardError => e
            IndoorCore::Logger.puts(
              "[IndoorGML] val3dity cancel visibility update failed: #{e.class}: #{e.message}"
            )
            false
          end
        end

        unless ExportProgressDialog.ancestors.include?(ExportProgressCancellableIntegration)
          ExportProgressDialog.prepend(ExportProgressCancellableIntegration)
        end

        unless Val3dityRunner.ancestors.include?(Val3dityCancellableProgressIntegration)
          Val3dityRunner.prepend(Val3dityCancellableProgressIntegration)
        end
      end
    end
  end
end
