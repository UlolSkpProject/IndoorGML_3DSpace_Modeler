# frozen_string_literal: true

# Dev-only A/B test for CellSpace batch copy placement.
#
# core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
# root = File.expand_path('..', File.dirname(core_file))
# load File.join(root, 'dev', 'cell_space_direct_copy_ab.rb')
#
# A: CellSpaceDirectCopyAB.legacy! -> run normal Local Grid V2 Create
# Reopen the same unconverted SKP without restarting SketchUp.
# B: CellSpaceDirectCopyAB.direct! -> run the same Create again.

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      unless const_defined?(:CellSpaceDirectCopyAB, false)
        module CellSpaceDirectCopyAB
          MODES = [:legacy, :direct].freeze
          CLOCK = Process::CLOCK_MONOTONIC
          LOG_PATH = File.join(
            ENV['TEMP'] || ENV['TMP'] || '.',
            'IndoorGML_CellSpace_Direct_Copy_AB.log'
          ).freeze

          class << self
            def install!
              service = IndoorCore::BulkCellSpaceConversionService
              service.prepend(InitializeProbe) unless service.ancestors.include?(InitializeProbe)
              service.prepend(CallProbe) unless service.ancestors.include?(CallProbe)
              @reports ||= {}
              puts '[CELLSPACE DIRECT COPY A/B] installed'
              puts 'A: ...::CellSpaceDirectCopyAB.legacy!'
              puts 'B: reopen the same source SKP, then ...::CellSpaceDirectCopyAB.direct!'
              puts "Log: #{LOG_PATH}"
              true
            rescue StandardError => e
              warn_error('install', e)
              false
            end

            def legacy! = arm!(:legacy)
            def direct! = arm!(:direct)
            def armed_mode = @armed_mode

            def arm!(mode)
              mode = mode.to_sym
              raise ArgumentError, "Unknown mode: #{mode.inspect}" unless MODES.include?(mode)

              @armed_mode = mode
              puts "[CELLSPACE DIRECT COPY A/B] armed #{label_mode(mode)} for next bulk Create"
              true
            end

            def reset!
              @armed_mode = nil
              @reports = {}
              File.delete(LOG_PATH) if File.file?(LOG_PATH)
              puts '[CELLSPACE DIRECT COPY A/B] reset'
              true
            rescue StandardError
              true
            end

            def prepare_kwargs(mode, kwargs)
              return kwargs unless mode == :legacy

              model = kwargs[:model] || Sketchup.active_model
              raise 'Could not resolve model for legacy A/B mode' unless model

              kwargs.merge(target_entities: model.entities)
            end

            def capture(service, mode)
              return yield unless @armed_mode == mode

              @armed_mode = nil
              model = service.instance_variable_get(:@model) || Sketchup.active_model
              jobs = Array(service.instance_variable_get(:@jobs))
              before = snapshot(model)
              started = Process.clock_gettime(CLOCK)
              result = yield
              elapsed = Process.clock_gettime(CLOCK) - started

              begin
                report = report_for(mode, model, jobs, before, result, elapsed)
                @reports[mode] = report
                print_report(report)
                compare! if @reports[:legacy] && @reports[:direct]
                write_log
              rescue StandardError => e
                warn_error('report', e)
              end
              result
            rescue StandardError => e
              warn_error("#{mode} conversion", e)
              raise
            end

            def compare!
              a = @reports && @reports[:legacy]
              b = @reports && @reports[:direct]
              unless a && b
                puts '[CELLSPACE DIRECT COPY A/B] both A and B results are required'
                return false
              end

              same_input = a[:jobs] == b[:jobs] && same_model?(a, b)
              create_delta = b[:create] - a[:create]
              adjacency_delta = b[:adjacency] - a[:adjacency]
              total_delta = b[:total] - a[:total]
              create_pct = percent(create_delta, a[:create])
              adjacency_pct = percent(adjacency_delta, a[:adjacency])
              total_pct = percent(total_delta, a[:total])

              lines = []
              lines << '=' * 104
              lines << 'CellSpace Direct Copy A/B Comparison'
              lines << '=' * 104
              lines << "Same model/jobs           : #{pf(same_input)}"
              lines << "Legacy functional result  : #{pf(a[:passed])}"
              lines << "Direct functional result  : #{pf(b[:passed])}"
              lines << '-' * 104
              lines << format('%-26s %13s %13s %14s %11s', 'Metric', 'Legacy A', 'Direct B', 'B - A', 'Change')
              lines << metric_line('CellSpace/State', a[:create], b[:create], create_delta, create_pct)
              lines << metric_line('Adjacency/Transition', a[:adjacency], b[:adjacency], adjacency_delta, adjacency_pct)
              lines << metric_line('Total metric', a[:total], b[:total], total_delta, total_pct)
              lines << '-' * 104
              lines << format('Direct Create speedup     : %.3fx', b[:create].positive? ? a[:create] / b[:create] : 0.0)
              lines << format('Adjacency environment drift: %.1f%%', adjacency_pct.abs)
              lines << 'WARNING: run a reverse-order pair if adjacency drift exceeds 15%.' if adjacency_pct.abs > 15.0
              verdict = if !same_input || !a[:passed] || !b[:passed]
                          'INVALID COMPARISON'
                        elsif b[:create] < a[:create]
                          'DIRECT FASTER'
                        elsif b[:create] > a[:create]
                          'LEGACY FASTER'
                        else
                          'TIE'
                        end
              lines << "CREATE VERDICT             : #{verdict}"
              lines << '=' * 104
              puts
              lines.each { |line| puts line }
              @comparison_lines = lines
              write_log
              true
            end

            private

            def snapshot(model)
              primal = primal_group(model)
              {
                cells: cells(primal).map { |e| key(e) },
                components: components(primal).map { |e| key(e) }
              }
            end

            def report_for(mode, model, jobs, before, result, elapsed)
              primal = primal_group(model)
              all_cells = cells(primal)
              new_cells = all_cells.reject { |e| before[:cells].include?(key(e)) }
              new_components = components(primal).reject { |e| before[:components].include?(key(e)) }
              direct = new_cells.count do |group|
                begin
                  Utils::Transformation.direct_child_of_root?(group, primal)
                rescue StandardError
                  primal&.valid? && primal.entities.to_a.include?(group)
                end
              end
              metrics = result&.metrics || {}
              converted = result&.converted_count.to_i
              errors = Array(result&.errors)

              {
                mode: mode,
                model_path: model.respond_to?(:path) ? model.path.to_s : '',
                model_title: model.respond_to?(:title) ? model.title.to_s : '',
                jobs: jobs.length,
                converted: converted,
                errors: errors,
                new_cells: new_cells.length,
                direct_cells: direct,
                new_components: new_components.length,
                preflight: metrics[:preflight_duration].to_f,
                create: metrics[:cell_space_state_duration].to_f,
                adjacency: metrics[:adjacency_transition_duration].to_f,
                total: metrics[:total_duration].to_f,
                elapsed: elapsed,
                pairs: metrics[:pair_comparison_count].to_i,
                passed: converted == jobs.length && errors.empty? &&
                        new_cells.length == converted && direct == new_cells.length &&
                        new_components.empty?
              }
            end

            def print_report(r)
              lines = []
              lines << '=' * 104
              lines << "CellSpace Direct Copy A/B — #{label_mode(r[:mode])}"
              lines << '=' * 104
              lines << "Jobs / Converted / Errors : #{r[:jobs]} / #{r[:converted]} / #{r[:errors].length}"
              lines << "New CellSpaces            : #{r[:new_cells]}/#{r[:converted]} #{pf(r[:new_cells] == r[:converted])}"
              lines << "Direct Primal children    : #{r[:direct_cells]}/#{r[:new_cells]} #{pf(r[:direct_cells] == r[:new_cells])}"
              lines << "New ComponentInstances    : #{r[:new_components]} #{pf(r[:new_components].zero?)}"
              lines << '-' * 104
              lines << format('Preflight                 : %10.3f sec', r[:preflight])
              lines << format('CellSpace/State           : %10.3f sec', r[:create])
              lines << format('Adjacency/Transition      : %10.3f sec', r[:adjacency])
              lines << format('Total metric              : %10.3f sec', r[:total])
              lines << format('Wrapper elapsed           : %10.3f sec', r[:elapsed])
              lines << "Pair comparisons          : #{r[:pairs]}"
              lines << '-' * 104
              lines << (r[:passed] ? 'OVERALL: PASS' : 'OVERALL: FAIL')
              lines << '=' * 104
              puts
              lines.each { |line| puts line }
              r[:lines] = lines
            end

            def write_log
              lines = []
              [:legacy, :direct].each do |mode|
                report = @reports && @reports[mode]
                next unless report

                lines.concat(report[:lines] || [])
                lines << ''
              end
              lines.concat(@comparison_lines || [])
              File.write(LOG_PATH, lines.join("\n") + "\n")
            rescue StandardError => e
              warn_error('log', e)
            end

            def primal_group(model)
              return nil unless model
              dict = IndoorModel::ATTRIBUTE_DICTIONARY_NAME
              model.entities.grep(Sketchup::Group).find do |g|
                g&.valid? && (g.get_attribute(dict, 'feature') == 'PrimalSpaceFeatures' ||
                              g.name.to_s == 'IndoorGML_PrimalSpaceFeatures')
              end
            rescue StandardError
              nil
            end

            def cells(primal)
              return [] unless primal&.valid?
              dict = IndoorModel::ATTRIBUTE_DICTIONARY_NAME
              primal.entities.grep(Sketchup::Group).select do |g|
                g&.valid? && g.get_attribute(dict, 'feature') == 'CellSpace'
              end
            rescue StandardError
              []
            end

            def components(primal)
              return [] unless primal&.valid? && defined?(Sketchup::ComponentInstance)
              primal.entities.grep(Sketchup::ComponentInstance).select(&:valid?)
            rescue StandardError
              []
            end

            def key(entity)
              pid = entity.persistent_id if entity.respond_to?(:persistent_id)
              return [:pid, pid] if pid && pid != 0
              return [:eid, entity.entityID] if entity.respond_to?(:entityID)
              [:object, entity.object_id]
            rescue StandardError
              [:object, entity.object_id]
            end

            def same_model?(a, b)
              ap = a[:model_path].to_s
              bp = b[:model_path].to_s
              return a[:model_title].to_s == b[:model_title].to_s if ap.empty? || bp.empty?
              File.expand_path(ap).casecmp?(File.expand_path(bp))
            end

            def percent(delta, baseline)
              baseline.to_f.zero? ? 0.0 : delta.to_f / baseline.to_f * 100.0
            end

            def metric_line(name, a, b, delta, pct)
              format('%-26s %10.3f s %10.3f s %+11.3f s %+9.1f%%', name, a, b, delta, pct)
            end

            def pf(value) = value ? 'PASS' : 'FAIL'
            def label_mode(mode) = mode == :legacy ? 'A: LEGACY TWO-COPY' : 'B: DIRECT ONE-COPY'

            def warn_error(stage, error)
              puts "[CELLSPACE DIRECT COPY A/B] #{stage} failed: #{error.class}: #{error.message}"
              puts error.backtrace.first(15).join("\n")
            end
          end

          module InitializeProbe
            def initialize(*args, **kwargs, &block)
              mode = CellSpaceDirectCopyAB.armed_mode
              @__cell_space_direct_copy_ab_mode = mode if mode
              kwargs = CellSpaceDirectCopyAB.prepare_kwargs(mode, kwargs) if mode
              super(*args, **kwargs, &block)
            end
          end

          module CallProbe
            def call
              mode = instance_variable_get(:@__cell_space_direct_copy_ab_mode)
              return super unless mode
              CellSpaceDirectCopyAB.capture(self, mode) { super }
            end
          end
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceDirectCopyAB.install!
