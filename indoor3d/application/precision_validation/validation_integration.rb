# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        PROFILE_THREAD_KEY = :ulol_indoor_gml_validation_profile
        FAST_PROFILE = :fast
        PRECISION_PROFILE = :precision
        PRECISION_OVERLAP_TOLERANCE_MM = 0.01
        PRECISION_OVERLAP_TOLERANCE = PRECISION_OVERLAP_TOLERANCE_MM

        FAST_STEPS = [
          [:temp_file, '임시파일 생성'],
          [:val3dity, 'val3dity 실행 (version2.2.0)'],
          [:extension_recheck, '2차 overlap recheck'],
          [:report, 'Report 생성']
        ].freeze

        PRECISION_STEPS = [
          [:lvn, 'CellSpace Normalize'],
          [:temp_file, '임시파일 생성'],
          [:val3dity, 'val3dity 실행 (overlap_tol 0.01 mm)'],
          [:report, 'Report 생성']
        ].freeze

        class Val3dityProcessExitError < RuntimeError
          attr_reader :exit_code

          def initialize(exit_code)
            @exit_code = exit_code.to_i
            unsigned = @exit_code & 0xFFFFFFFF
            super(
              format(
                'val3dity process exited abnormally: exit code %d (0x%08X)',
                @exit_code,
                unsigned
              )
            )
          end
        end

        class Val3dityPostProcessError < RuntimeError
          attr_reader :exit_code, :original_error

          def initialize(error, exit_code:)
            @exit_code = exit_code.to_i
            @original_error = error
            super("val3dity post-processing failed after exit code #{@exit_code}: #{error.message}")
            set_backtrace(error.backtrace)
          end
        end

        module_function

        def current_profile
          Thread.current[PROFILE_THREAD_KEY] || FAST_PROFILE
        rescue StandardError
          FAST_PROFILE
        end

        def with_profile(profile)
          previous = Thread.current[PROFILE_THREAD_KEY]
          Thread.current[PROFILE_THREAD_KEY] = normalize_profile(profile)
          yield
        ensure
          Thread.current[PROFILE_THREAD_KEY] = previous
        end

        def normalize_profile(profile)
          profile.to_sym == PRECISION_PROFILE ? PRECISION_PROFILE : FAST_PROFILE
        rescue StandardError
          FAST_PROFILE
        end

        def precision_profile?(profile = current_profile)
          normalize_profile(profile) == PRECISION_PROFILE
        end

        def steps_for(profile = current_profile)
          precision_profile?(profile) ? PRECISION_STEPS : FAST_STEPS
        end

        module ExportProgressDialogPatch
          def initialize(*_args, **_options)
            @validation_profile = PrecisionValidation.current_profile
            super()
          end

          private

          def init_script
            steps = PrecisionValidation.steps_for(@validation_profile).map do |key, label|
              "{key: #{key.to_s.inspect}, label: #{label.inspect}}"
            end.join(', ')
            "init([#{steps}]);"
          end
        end

        module Val3dityResultPatch
          attr_reader :exit_code, :process_status

          def assign_process_outcome(exit_code:, process_status:)
            @exit_code = exit_code
            @process_status = process_status
            self
          end
        end

        module Val3dityRunnerPatch
          def initialize(*args, **options)
            @validation_profile = PrecisionValidation.current_profile
            super(*args, **options)
          end

          def start(
            progress: nil,
            progress_step: :val3dity,
            recheck_step: :extension_recheck,
            report_step: :report,
            active: nil,
            &callback
          )
            effective_recheck_step = precision_validation_profile? ? nil : recheck_step
            super(
              progress: progress,
              progress_step: progress_step,
              recheck_step: effective_recheck_step,
              report_step: report_step,
              active: active,
              &callback
            )
          end

          private

          def precision_validation_profile?
            PrecisionValidation.precision_profile?(@validation_profile)
          end

          def preserve_strict_validation!(raw_report)
            return raw_report if precision_validation_profile?

            super
          end

          def recheck_overlap_errors!(raw_report, progress: nil, progress_step: nil)
            return raw_report if precision_validation_profile?

            super
          end

          def build_result_after_process(
            exit_code,
            progress = nil,
            recheck_step: :extension_recheck,
            report_step: :report
          )
            raise Val3dityProcessExitError.new(exit_code) unless exit_code.to_i.zero?

            result = super
            result.assign_process_outcome(
              exit_code: exit_code.to_i,
              process_status: :completed
            )
          rescue Val3dityProcessExitError
            raise
          rescue StandardError => error
            raise Val3dityPostProcessError.new(error, exit_code: exit_code)
          end

          def error_result(error)
            result = super
            if error.is_a?(Val3dityProcessExitError)
              return result.assign_process_outcome(
                exit_code: error.exit_code,
                process_status: :crashed
              )
            end
            if error.is_a?(Val3dityPostProcessError)
              return result.assign_process_outcome(
                exit_code: error.exit_code,
                process_status: :postprocess_error
              )
            end
            if error.message.to_s == 'val3dity validation was canceled.'
              return result.assign_process_outcome(
                exit_code: nil,
                process_status: :cancelled
              )
            end

            result.assign_process_outcome(
              exit_code: nil,
              process_status: :runner_error
            )
          end
        end

        module CommandDispatcherPatch
          def check_precision_validity
            return if validation_operation_running?

            message = <<~MESSAGE
              정밀검사는 CellSpace Normalize를 시도한 뒤 0.01 mm를 GML 좌표 단위로 변환해 val3dity --overlap_tol에 전달합니다.
              Normalize 성공 CellSpace의 geometry는 유지되며, 실패 CellSpace는 원복 후 lvn_failed=true로 표시하고 검사를 계속합니다.

              계속하시겠습니까?
            MESSAGE
            UiFeedback.confirm(message, MB_YESNO) do |result|
              next unless result == IDYES

              PrecisionValidation.with_profile(PRECISION_PROFILE) do
                check_validity
              end
            end
            true
          end

          private

          def validation_close_state
            state = super
            state[:validation_profile] = PrecisionValidation.current_profile
            state[:lvn_running] = false
            state[:lvn_report] = nil
            state
          end

          def perform_check_validity(session)
            return super unless precision_validation_session?(session)

            state = session.state
            progress = session.progress
            state[:overlap_tol] = IndoorGmlConverter::Val3dityRunner::STRICT_OVERLAP_TOL
            state[:overlap_tol_mm] = PRECISION_OVERLAP_TOLERANCE_MM
            state[:lvn_running] = true
            progress.running(:lvn)
            progress.detail(
              :lvn,
              percent: 0,
              phase: 'CellSpace Normalize',
              message: 'Checking and normalizing CellSpaces'
            )

            report = session.indoor_model.local_vertex_normalize(
              LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
              activate_edit_context: false,
              failure_policy: :continue
            )
            state[:lvn_report] = report
            state[:lvn_running] = false
            progress.detail(
              :lvn,
              percent: 100,
              phase: 'CellSpace Normalize',
              message: precision_lvn_summary(report)
            )
            progress.complete(:lvn)

            super
          rescue StandardError => error
            state[:lvn_running] = false if state
            state[:completed] = true if state
            @validation_operation_running = false
            session.cancel(
              reason: :failed,
              close_dialog: false,
              terminate_process: true
            )
            progress&.fail(:lvn)
            progress&.result(
              status: :error,
              title: 'IndoorGML precision normalization failed',
              message: error.message,
              actions: [:close]
            )
          end

          def start_val3dity_validation(session, temp_path)
            profile = session.state[:validation_profile]
            PrecisionValidation.with_profile(profile) do
              super
            end
          end

          def handle_validation_result(session, result, temp_path)
            handled = super
            return handled unless precision_validation_session?(session)

            summary = precision_lvn_summary(session.state[:lvn_report])
            process = precision_process_summary(result)
            session.progress&.set_result_message([summary, process].compact.join("\n"))
            handled
          end

          def precision_validation_session?(session)
            PrecisionValidation.precision_profile?(
              session&.state&.[](:validation_profile)
            )
          end

          def precision_lvn_summary(report)
            data = report || {}
            normalized = data[:cell_space_count].to_i
            already = data[:already_normalized_cell_space_count].to_i
            failed = data[:normalization_failed_cell_space_count].to_i
            skipped = data[:skipped_previous_failure_cell_space_count].to_i
            "LVN 결과: 성공 #{normalized}, 기존 완료 #{already}, 실패 #{failed}, 이전 실패 생략 #{skipped}"
          end

          def precision_process_summary(result)
            return nil unless result

            code = result.respond_to?(:exit_code) ? result.exit_code : nil
            status = result.respond_to?(:process_status) ? result.process_status : nil
            code_text = code.nil? ? 'n/a' : code.to_s
            validity = if result.respond_to?(:error?) && result.error?
                         'error'
                       elsif result.respond_to?(:valid?) && result.valid?
                         'valid'
                       else
                         'invalid'
                       end
            "val3dity: overlap_tol=0.01 mm (converted to GML units), result=#{validity}, process=#{status || 'unknown'}, exit_code=#{code_text}"
          end
        end

        def self.install_validation!
          dialog_class = IndoorGmlConverter::ExportProgressDialog
          runner_class = IndoorGmlConverter::Val3dityRunner
          result_class = IndoorGmlConverter::Val3dityRunner::Val3dityResult

          dialog_class.prepend(ExportProgressDialogPatch) unless
            dialog_class.ancestors.include?(ExportProgressDialogPatch)
          result_class.prepend(Val3dityResultPatch) unless
            result_class.ancestors.include?(Val3dityResultPatch)
          runner_class.prepend(Val3dityRunnerPatch) unless
            runner_class.ancestors.include?(Val3dityRunnerPatch)
          CommandDispatcher.prepend(CommandDispatcherPatch) unless
            CommandDispatcher.ancestors.include?(CommandDispatcherPatch)

          install_precision_command!
          true
        end

        def self.install_precision_command!
          return if @precision_command_installed
          return unless defined?(UI)

          command = UI::Command.new('IndoorGML 정밀검사') do
            ULOL::Indoor3DGmlModeler.command_dispatcher.check_precision_validity
          end
          command.tooltip = 'CellSpace Normalize 후 val3dity overlap_tol 0.01 mm 정밀검사'
          command.status_bar_text = command.tooltip
          command.set_validation_proc do
            dispatcher = ULOL::Indoor3DGmlModeler.command_dispatcher
            dispatcher.validation_operation_running? ? MF_GRAYED : MF_ENABLED
          end
          UI.menu('Extensions').add_item(command)
          @precision_command_installed = true
        end
      end

      PrecisionValidation.install_validation!
    end
  end
end
