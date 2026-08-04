# frozen_string_literal: true

require_relative 'val3dity_recheck_v3_positive_control'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Corrects the positive-control verdict so it measures extension-policy
        # safety separately from SketchUp Boolean reproduction fidelity.
        #
        # A positive overlap that becomes :inconclusive is still retained in the
        # validation report because tolerated=false. It is therefore a Boolean
        # reproduction warning, not a false suppression or policy hard failure.
        module Val3dityRecheckV3PositiveControlPolicyFix
          private

          def run_case(*args)
            row = super
            original_policy = row['original_policy_701'] || {}
            v3_policy = row['v3_policy_701'] || {}

            original_false_suppression =
              original_policy['tolerated'] == true
            v3_false_suppression = v3_policy['tolerated'] == true
            reproduction_warning =
              row['original_positive_missed'] == true ||
              row['v3_positive_missed'] == true

            hard_failure =
              row['generator_complexity_preserved'] != true ||
              original_false_suppression ||
              v3_false_suppression ||
              row['volume_mismatch'] == true ||
              row['policy_disagreement'] == true ||
              row['unexpected_tolerance_candidate'] == true

            row.merge(
              'original_policy_false_suppression' =>
                original_false_suppression,
              'v3_policy_false_suppression' => v3_false_suppression,
              'policy_retained_positive' =>
                !original_false_suppression && !v3_false_suppression,
              'reproduction_warning' => reproduction_warning,
              'hard_failure' => hard_failure
            )
          end

          def summarize(rows)
            summary = super
            original_missed =
              rows.count { |row| row['original_positive_missed'] == true }
            v3_missed =
              rows.count { |row| row['v3_positive_missed'] == true }

            summary.merge(
              'policy_retained_positive_count' => rows.count do |row|
                row['policy_retained_positive'] == true
              end,
              'reproduction_warning_count' => rows.count do |row|
                row['reproduction_warning'] == true
              end,
              'policy_pass' => summary['hard_failure_count'].zero?,
              'reproduction_pass' =>
                original_missed.zero? && v3_missed.zero?
            )
          end

          public

          def print_report(report = @last_report)
            super
            summary = report.fetch('summary')
            puts format(
              '%42s : %s',
              'policy_retained_positive_count',
              summary['policy_retained_positive_count']
            )
            puts format(
              '%42s : %s',
              'reproduction_warning_count',
              summary['reproduction_warning_count']
            )
            puts format('%42s : %s', 'POLICY PASS', summary['policy_pass'])
            puts format(
              '%42s : %s',
              'REPRODUCTION PASS',
              summary['reproduction_pass']
            )
            nil
          end
        end

        singleton = class << Val3dityRecheckV3PositiveControl
                      self
                    end
        singleton.prepend(Val3dityRecheckV3PositiveControlPolicyFix) unless
          singleton.ancestors.include?(
            Val3dityRecheckV3PositiveControlPolicyFix
          )
      end
    end
  end
end
