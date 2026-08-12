# frozen_string_literal: true

require_relative 'crash_isolation'
require_relative 'crash_state'

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
          [:crash_scan, '유형별 val3dity crash 탐색 (4 processes)'],
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
              정밀검사는 Room 전체, Stair 전반 50%, Stair 후반 50%, Door/Elevator/Window/Anchor의 4개 geometry-only 묶음을 val3dity 프로세스로 검사합니다.
              Crash가 발생한 묶음은 4분할하여 원인 CellSpace를 찾고, 해당 CellSpace만 Normalize한 뒤 전체 모델을 overlap_tol 0.01 mm로 검사합니다.
              Crash 목록과 LVN 결과에서 각각 '다음'을 눌러야 다음 단계가 시작됩니다.

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
            state[:crash_scan_running] = false
            state[:crash_scan_report] = nil
            state[:precision_waiting_for] = nil
            state[:precision_crash_cell_spaces] = nil
            state
          end

          def perform_check_validity(session)
            return super unless precision_validation_session?(session)

            state = session.state
            progress = session.progress
            state[:overlap_tol] = IndoorGmlConverter::Val3dityRunner::STRICT_OVERLAP_TOL
            state[:overlap_tol_mm] = PRECISION_OVERLAP_TOLERANCE_MM
            state[:crash_scan_running] = true
            state[:val_running] = true
            progress.running(:crash_scan)
            progress.detail(
              :crash_scan,
              percent: 0,
              phase: 'Category crash scan',
              message: 'Preparing geometry-only CellSpace groups'
            )

            generation = session.generation
            all_cell_spaces = Array(session.indoor_model&.cell_spaces)
            cached_checked_cells = all_cell_spaces.select { |cell_space| CrashState.checked?(cell_space) }
            cached_crash_cells = cached_checked_cells.select { |cell_space| CrashState.crashed?(cell_space) }
            probe_cell_spaces = all_cell_spaces.reject { |cell_space| CrashState.checked?(cell_space) }
            coordinator = CrashIsolationCoordinator.new(
              indoor_model: session.indoor_model,
              cell_spaces: probe_cell_spaces,
              cached_checked_cell_spaces: cached_checked_cells,
              cached_crash_cell_spaces: cached_crash_cells,
              work_dir: File.join(session.workspace.root_dir, 'crash-probes'),
              overlap_tol_mm: PRECISION_OVERLAP_TOLERANCE_MM,
              logger: Logger
            )
            session.assign_val_session(coordinator)
            progress.cancellable(true) if progress.respond_to?(:cancellable)
            coordinator.start(
              active: proc { session.active_generation?(generation) },
              on_progress: proc { |snapshot| precision_crash_scan_progress(progress, snapshot) }
            ) do |result|
              next unless session.active_generation?(generation)
              next if state[:cancelled]

              state[:crash_scan_running] = false
              state[:val_running] = false
              session.assign_val_session(nil)
              progress.cancellable(false) if progress.respond_to?(:cancellable)
              if result.error?
                precision_validation_failed(session, :crash_scan, result.error)
                next
              end

              new_crash_cells = result.crash_cell_spaces.reject do |cell_space|
                cached_crash_cells.include?(cell_space)
              end
              if session.indoor_model.respond_to?(:mark_precision_crash_check_results)
                session.indoor_model.mark_precision_crash_check_results(
                  checked_cell_spaces: probe_cell_spaces,
                  crash_cell_spaces: new_crash_cells
                )
              end

              state[:crash_scan_report] = {
                crash_cell_space_ids: result.crash_cell_spaces.map(&:id),
                cached_checked_cell_space_count: cached_checked_cells.length,
                cached_crash_cell_space_count: cached_crash_cells.length,
                records: result.records,
                progress: result.progress
              }
              progress.detail(
                :crash_scan,
                percent: 100,
                phase: 'Category crash scan',
                message: "Crash CellSpace #{result.crash_cell_spaces.length}개 식별",
                current: precision_crash_scan_detail(result.progress)
              )
              progress.complete(:crash_scan)
              await_precision_lvn_confirmation(session, result.crash_cell_spaces)
            end
          rescue StandardError => error
            precision_validation_failed(session, :crash_scan, error)
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
            crash_summary = precision_crash_scan_summary(session.state[:crash_scan_report])
            process = precision_process_summary(result)
            session.progress&.set_result_message([crash_summary, summary, process].compact.join("\n"))
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

          def precision_crash_scan_summary(report)
            ids = Array(report && report[:crash_cell_space_ids])
            headline = "Crash 탐색: 대상 #{ids.length}개#{ids.empty? ? '' : " (#{ids.join(', ')})"}"
            detail = precision_crash_scan_detail(report && report[:progress])
            [headline, detail].reject(&:empty?).join("\n")
          end

          def precision_crash_scan_progress(progress, snapshot)
            completed = snapshot[:completed].to_i
            total = snapshot[:total_jobs].to_i
            percent = total.zero? ? 0 : ((completed.to_f / total) * 100).round
            progress&.detail(
              :crash_scan,
              percent: [percent, 99].min,
              phase: '4-process type buckets / quarter isolation',
              message: "전체 job #{completed}/#{total}, 실행 #{snapshot[:active]}, 대기 #{snapshot[:pending]}, crash 후보 #{snapshot[:crash_cell_count]}",
              current: precision_crash_scan_detail(snapshot)
            )
          end

          def precision_crash_scan_detail(snapshot)
            rows = Array(snapshot && snapshot[:categories])
            return '' if rows.empty?

            rows.each_with_index.map do |row, index|
              status = precision_crash_bucket_status(row[:status])
              job = "job #{row[:completed_jobs].to_i}/#{row[:total_jobs].to_i}"
              activity = "실행 #{row[:active_jobs].to_i}, 대기 #{row[:pending_jobs].to_i}"
              split = if row[:split_count].to_i.positive?
                        "분할 #{row[:split_count]}회, 하위 job #{row[:split_completed_jobs]}/#{row[:split_total_jobs]}, depth #{row[:max_depth]}"
                      else
                        '분할 0회'
                      end
              crash = "격리 #{row[:crash_cell_count].to_i}개"
              cache = "cache 통과 #{row[:cached_passed_count].to_i}, crash #{row[:cached_crash_count].to_i}"
              aabb = "AABB 통과 CellSpace #{row[:aabb_passed_cell_space_count].to_i}개"
              "#{index + 1}. #{row[:category]} [#{status}] CellSpace #{row[:cell_space_count]} (검사 #{row[:probe_cell_space_count]}, #{cache}) | #{job} (#{activity}) | #{split} | #{aabb} | #{crash}"
            end.join("\n")
          end

          def precision_crash_bucket_status(status)
            {
              empty: '대상 없음',
              waiting: '대기',
              checking: '검사 중',
              passed: 'crash 없음',
              splitting: 'crash 발생 / 분할 중',
              crashed: 'crash 발생 / 격리 완료',
              cached_passed: 'cache 통과 / 검사 생략',
              cached_crashed: 'cache crash / 검사 생략'
            }[status.to_sym] || status.to_s
          rescue StandardError
            status.to_s
          end

          def await_precision_lvn_confirmation(session, crash_cells)
            cells = Array(crash_cells)
            if cells.empty?
              report = empty_precision_lvn_report
              session.state[:lvn_report] = report
              session.progress.complete(:lvn)
              session.progress.detail(
                :lvn,
                percent: 100,
                phase: 'Crash CellSpace Normalize',
                message: 'Crash CellSpace 없음 - LVN 대상 없음'
              )
              await_precision_val3dity_confirmation(session, report)
              return
            end

            state = session.state
            state[:precision_waiting_for] = :lvn
            state[:precision_crash_cell_spaces] = cells
            session.progress.result(
              status: :neutral,
              title: 'Crash CellSpace 확인',
              message: [
                precision_crash_scan_detail(state.dig(:crash_scan_report, :progress)),
                precision_crash_cell_list_message(cells)
              ].reject(&:empty?).join("\n\n"),
              actions: [:next]
            )
            session.progress.on_next do
              next unless state[:precision_waiting_for] == :lvn
              next if state[:cancelled]

              state[:precision_waiting_for] = nil
              targets = state.delete(:precision_crash_cell_spaces) || cells
              session.progress.clear_result
              normalize_precision_crash_cells_and_continue(session, targets)
            end
          end

          def precision_crash_cell_list_message(crash_cells)
            ids = Array(crash_cells).map { |cell_space| cell_space.id.to_s }
            rows = ids.map { |id| "- #{id}" }.join("\n")
            "Crash 발생 CellSpace (#{ids.length}개)\n#{rows}\n\n다음을 누르면 이 CellSpace만 LVN을 실행합니다."
          end

          def normalize_precision_crash_cells_and_continue(session, crash_cells)
            state = session.state
            progress = session.progress
            state[:lvn_running] = true
            progress.running(:lvn)
            progress.detail(
              :lvn,
              percent: 0,
              phase: 'Crash CellSpace Normalize',
              message: "Crash CellSpace #{Array(crash_cells).length}개 Normalize 준비"
            )

            report = with_precision_lvn_progress(session) do
              if Array(crash_cells).empty?
                empty_precision_lvn_report
              else
                session.indoor_model.local_vertex_normalize(
                  LocalVertexNormalizer::DEFAULT_TOLERANCE_MM,
                  cell_spaces: crash_cells,
                  activate_edit_context: false,
                  failure_policy: :continue
                )
              end
            end
            state[:lvn_report] = report
            state[:lvn_running] = false
            progress.detail(
              :lvn,
              percent: 100,
              phase: 'Crash CellSpace Normalize',
              message: precision_lvn_summary(report)
            )
            progress.complete(:lvn)
            await_precision_val3dity_confirmation(session, report)
          rescue StandardError => error
            precision_validation_failed(session, :lvn, error)
          end

          def await_precision_val3dity_confirmation(session, report)
            state = session.state
            state[:precision_waiting_for] = :val3dity
            crash_detail = precision_crash_scan_detail(state.dig(:crash_scan_report, :progress))
            session.progress.result(
              status: :neutral,
              title: 'LVN 완료',
              message: [
                crash_detail,
                precision_lvn_summary(report),
                '다음을 누르면 전체 모델 val3dity 검사를 실행합니다.'
              ].reject(&:empty?).join("\n\n"),
              actions: [:next]
            )
            session.progress.on_next do
              next unless state[:precision_waiting_for] == :val3dity
              next if state[:cancelled]

              state[:precision_waiting_for] = nil
              session.progress.clear_result
              start_precision_final_validation(session)
            end
          end

          def start_precision_final_validation(session)
            session.state[:after_temp_export] = proc do |temp_path|
              start_val3dity_validation(session, temp_path)
            end
            start_temp_file_creation(
              session,
              output_path: session.workspace&.gml_path,
              step: :temp_file
            )
          end

          def empty_precision_lvn_report
            {
              target_cell_space_count: 0,
              cell_space_count: 0,
              already_normalized_cell_space_count: 0,
              normalization_failed_cell_space_count: 0,
              skipped_previous_failure_cell_space_count: 0,
              failed_cell_space_ids: [],
              cell_spaces: []
            }
          end

          def with_precision_lvn_progress(session)
            unless defined?(ValidationLvnProgressAdapter) &&
                   defined?(LvnProgressTracker) &&
                   defined?(LvnProgressContext)
              return yield
            end

            tracker = LvnProgressTracker.new(
              ValidationLvnProgressAdapter.new(session.progress)
            )
            LvnProgressContext.with(tracker) { yield }
          end

          def precision_validation_failed(session, step, error)
            state = session&.state
            state[:crash_scan_running] = false if state
            state[:lvn_running] = false if state
            state[:val_running] = false if state
            state[:precision_waiting_for] = nil if state
            state[:precision_crash_cell_spaces] = nil if state
            state[:completed] = true if state
            @validation_operation_running = false
            session&.cancel(
              reason: :failed,
              close_dialog: false,
              terminate_process: true
            )
            session&.progress&.fail(step)
            session&.progress&.result(
              status: :error,
              title: 'IndoorGML precision validation failed',
              message: error.message,
              actions: [:close]
            )
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
          command.tooltip = '유형별 crash 격리 후 crash CellSpace만 Normalize하고 overlap_tol 0.01 mm로 검사'
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
