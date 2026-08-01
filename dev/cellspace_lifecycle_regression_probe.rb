# frozen_string_literal: true

require 'json'
require 'digest'
require 'tmpdir'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceLifecycleRegressionProbe
        BASELINE_PATH = File.join(
          ENV.fetch('TEMP', Dir.tmpdir),
          'IndoorGML_CellSpace_Lifecycle_Baseline.json'
        ).freeze
        LOG_PATH = File.join(
          ENV.fetch('TEMP', Dir.tmpdir),
          'IndoorGML_CellSpace_Lifecycle_Regression.log'
        ).freeze
        OVERLAY_ID = 'ulol.indoor3dgml_modeler.dual_graph_space_overlay'

        module_function

        def baseline!
          snapshot = capture_snapshot('created')
          File.write(BASELINE_PATH, JSON.pretty_generate(snapshot))
          append_report('BASELINE', snapshot, verdict: 'RECORDED')
          snapshot
        rescue StandardError => e
          report_error('baseline', e)
          nil
        end

        def check!(stage)
          stage = stage.to_sym
          current = capture_snapshot(stage.to_s)
          baseline = read_baseline
          verdict, differences = compare_stage(stage, baseline, current)
          append_report(stage.to_s.upcase, current, verdict: verdict, differences: differences)
          {
            stage: stage,
            verdict: verdict,
            differences: differences,
            current: current,
            baseline: baseline
          }
        rescue StandardError => e
          report_error(stage, e)
          nil
        end

        def status!(label = 'status')
          snapshot = capture_snapshot(label.to_s)
          append_report(label.to_s.upcase, snapshot, verdict: 'INFO')
          snapshot
        rescue StandardError => e
          report_error(label, e)
          nil
        end

        def capture_snapshot(label)
          indoor_model = IndoorCore::IndoorModel.current
          transitions = indoor_model.transitions.select { |item| valid_feature?(item) }
          {
            label: label,
            captured_at: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
            cell_spaces: indoor_model.cell_spaces.count { |item| valid_feature?(item) },
            states: indoor_model.states.count { |item| valid_feature?(item) },
            transitions: transitions.length,
            transition_geometry_sha256: transition_geometry_digest(transitions),
            overlay_visible: indoor_model.dual_overlay_visible? == true,
            overlay_registered: overlay_registered?,
            overlay_enabled: overlay_enabled?,
            active_path: active_path_kind(indoor_model),
            model_path: Sketchup.active_model.path.to_s
          }
        end

        def compare_stage(stage, baseline, current)
          return ['FAIL', ['baseline file missing']] unless baseline

          case stage
          when :undo
            differences = []
            differences << "cell_spaces expected=0 actual=#{current[:cell_spaces]}" unless current[:cell_spaces].zero?
            differences << "states expected=0 actual=#{current[:states]}" unless current[:states].zero?
            differences << "transitions expected=0 actual=#{current[:transitions]}" unless current[:transitions].zero?
            [differences.empty? ? 'PASS' : 'FAIL', differences]
          when :redo, :reopen
            keys = %i[
              cell_spaces
              states
              transitions
              transition_geometry_sha256
              overlay_visible
              overlay_registered
              overlay_enabled
            ]
            differences = keys.filter_map do |key|
              next if baseline[key] == current[key]

              "#{key} expected=#{baseline[key].inspect} actual=#{current[key].inspect}"
            end
            [differences.empty? ? 'PASS' : 'FAIL', differences]
          else
            ['INFO', []]
          end
        end

        def transition_geometry_digest(transitions)
          payload = transitions.map { |transition| transition_geometry_record(transition) }
                               .compact
                               .sort_by(&:to_s)
          Digest::SHA256.hexdigest(JSON.generate(payload))
        end

        def transition_geometry_record(transition)
          [
            rounded_point(transition.state1_point),
            rounded_point(transition.selected_waypoint),
            rounded_point(transition.state2_point),
            rounded_vector(transition.selected_waypoint_normal1),
            rounded_vector(transition.selected_waypoint_normal2)
          ]
        rescue StandardError
          nil
        end

        def rounded_point(point)
          return nil unless point.is_a?(Geom::Point3d)

          [point.x.to_f.round(8), point.y.to_f.round(8), point.z.to_f.round(8)]
        end

        def rounded_vector(vector)
          return nil unless vector.is_a?(Geom::Vector3d)

          [vector.x.to_f.round(8), vector.y.to_f.round(8), vector.z.to_f.round(8)]
        end

        def valid_feature?(feature)
          feature && (!feature.respond_to?(:valid?) || feature.valid?)
        rescue StandardError
          false
        end

        def overlay_registered?
          !dual_overlay.nil?
        end

        def overlay_enabled?
          overlay = dual_overlay
          return false unless overlay
          return overlay.enabled? if overlay.respond_to?(:enabled?)
          return overlay.enabled if overlay.respond_to?(:enabled)

          false
        rescue StandardError
          false
        end

        def dual_overlay
          model = Sketchup.active_model
          return nil unless model&.respond_to?(:overlays)

          model.overlays.each do |overlay|
            return overlay if overlay.respond_to?(:overlay_id) && overlay.overlay_id == OVERLAY_ID
          end
          nil
        rescue StandardError
          nil
        end

        def active_path_kind(indoor_model)
          path = Sketchup.active_model.active_path
          return 'root' if path.nil? || path.empty?

          primal = indoor_model.primal_group
          return 'primal' if primal&.valid? && path == [primal]
          return 'cell_space' if primal&.valid? && path.first == primal && path.length > 1

          'other'
        rescue StandardError
          'unknown'
        end

        def read_baseline
          return nil unless File.file?(BASELINE_PATH)

          JSON.parse(File.read(BASELINE_PATH), symbolize_names: true)
        end

        def append_report(stage, snapshot, verdict:, differences: [])
          lines = []
          lines << ('=' * 100)
          lines << "CellSpace Lifecycle Regression — #{stage}"
          lines << ('=' * 100)
          lines << format('CellSpaces               : %d', snapshot[:cell_spaces])
          lines << format('States                   : %d', snapshot[:states])
          lines << format('Transitions              : %d', snapshot[:transitions])
          lines << "Transition geometry SHA  : #{snapshot[:transition_geometry_sha256]}"
          lines << "Overlay visible setting  : #{snapshot[:overlay_visible]}"
          lines << "Overlay registered       : #{snapshot[:overlay_registered]}"
          lines << "Overlay enabled          : #{snapshot[:overlay_enabled]}"
          lines << "Active path              : #{snapshot[:active_path]}"
          lines << "Model path               : #{snapshot[:model_path]}"
          Array(differences).each { |difference| lines << "DIFF                     : #{difference}" }
          lines << "VERDICT                  : #{verdict}"
          lines << ('=' * 100)
          text = lines.join("\n") + "\n"
          File.open(LOG_PATH, 'a') { |file| file.write(text) }
          puts text
          puts "Log: #{LOG_PATH}"
          verdict
        end

        def report_error(stage, error)
          text = "[LIFECYCLE REGRESSION] #{stage} failed: #{error.class}: #{error.message}"
          File.open(LOG_PATH, 'a') { |file| file.puts(text) }
          warn text
        rescue StandardError
          nil
        end
      end
    end
  end
end

puts '[CELLSPACE LIFECYCLE REGRESSION PROBE] installed'
puts '1. ...::CellSpaceLifecycleRegressionProbe.baseline!'
puts '2. Undo, then ...::CellSpaceLifecycleRegressionProbe.check!(:undo)'
puts '3. Redo, then ...::CellSpaceLifecycleRegressionProbe.check!(:redo)'
puts '4. Save/reopen, reload this file, then ...::CellSpaceLifecycleRegressionProbe.check!(:reopen)'
puts "Log: #{ULOL::Indoor3DGmlModeler::IndoorCore::CellSpaceLifecycleRegressionProbe::LOG_PATH}"
