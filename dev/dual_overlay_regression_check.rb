# frozen_string_literal: true

# Run from the SketchUp Ruby Console after the extension is loaded:
#
#   core_file = ULOL::Indoor3DGmlModeler.method(:attach_model_observer).source_location.first
#   root = File.expand_path('..', File.dirname(core_file))
#   load File.join(root, 'dev', 'dual_overlay_regression_check.rb')

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module DualOverlayRegressionCheck
        REPORT_DELAY_SECONDS = 10.0

        module_function

        def run
          indoor_model = IndoorModel.current
          overlay = DualGraphSpaceOverlay.new(indoor_model)
          state_renderer = overlay.instance_variable_get(:@state_renderer)
          transition_builder = overlay.instance_variable_get(:@transition_curve_builder)
          scale = DualOverlayPreferences.state_radius_scale

          checks = []

          state_renderer.clear_cache
          state_renderer.send(:rebuild_state_points)
          state_renderer.overlay_state_extent_points(state_radius_scale: scale)
          transition_builder.clear_cache

          baseline = transition_builder.transition_line_points
          baseline_copy = point_snapshot(baseline)
          warm = transition_builder.transition_line_points

          checks << check('warm cache reuses same render array', baseline.equal?(warm))
          checks << check('GL line point count is even', baseline.length.even?, baseline.length)

          transition_builder.invalidate
          soft = transition_builder.transition_line_points
          checks << check('soft invalidate creates a new render array', !baseline.equal?(soft))
          checks << check('soft invalidate preserves exact GL coordinates', same_points?(baseline_copy, soft))

          transition_builder.clear_cache
          hard = transition_builder.transition_line_points
          checks << check('hard clear creates a new render array', !soft.equal?(hard))
          checks << check('hard clear preserves exact GL coordinates', same_points?(baseline_copy, hard))

          visible_states = visible_state_count(indoor_model)
          visible_transitions = visible_transition_count(indoor_model)
          state_points = Array(state_renderer.instance_variable_get(:@render_state_points))
          extent_points = Array(state_renderer.instance_variable_get(:@render_state_extent_points))
          render_cache = transition_builder.instance_variable_get(:@transition_render_segment_cache) || {}

          checks << check('state render count matches visible State count', state_points.length == visible_states,
                          "render=#{state_points.length}, visible=#{visible_states}")
          checks << check('render cache covers visible Transitions', render_cache.length == visible_transitions,
                          "cache=#{render_cache.length}, visible=#{visible_transitions}")
          checks << check('state extent cache is present when State points exist',
                          state_points.empty? || extent_points.length == 2,
                          "state_points=#{state_points.length}, extent_points=#{extent_points.length}")
          checks << check('legacy curve-cache ivar is absent',
                          !transition_builder.instance_variable_defined?(:@transition_curve_cache))

          passed = checks.all? { |entry| entry[:pass] }
          report = build_report(
            indoor_model,
            baseline.length,
            visible_states,
            visible_transitions,
            render_cache.length,
            checks
          )
          schedule_report(report)
          passed
        rescue StandardError => e
          report = [
            '[regression] Dual Overlay Regression Check failed',
            "#{e.class}: #{e.message}",
            Array(e.backtrace).first(10).join("\n")
          ].join("\n")
          schedule_report(report)
          false
        end

        def visible_state_count(indoor_model)
          states = Array(indoor_model.states)
          return states.length unless indoor_model.respond_to?(:dual_overlay_state_visible?)

          states.count { |state| indoor_model.dual_overlay_state_visible?(state) }
        end

        def visible_transition_count(indoor_model)
          transitions = Array(indoor_model.transitions)
          return transitions.length unless indoor_model.respond_to?(:dual_overlay_transition_visible?)

          transitions.count { |transition| indoor_model.dual_overlay_transition_visible?(transition) }
        end

        def point_snapshot(points)
          Array(points).map { |point| [point.x, point.y, point.z] }
        end

        def same_points?(expected, actual)
          actual_points = Array(actual)
          return false unless expected.length == actual_points.length

          expected.each_with_index.all? do |coords, index|
            point = actual_points[index]
            coords[0] == point.x && coords[1] == point.y && coords[2] == point.z
          end
        end

        def check(label, pass, detail = nil)
          { label: label, pass: !!pass, detail: detail }
        end

        def schedule_report(report)
          UI.start_timer(REPORT_DELAY_SECONDS, false) { puts report }
        rescue StandardError
          puts report
        end

        def build_report(indoor_model, point_count, visible_states, visible_transitions, cache_entries, checks)
          lines = []
          lines << ('=' * 72)
          lines << ' IndoorGML Dual Overlay Regression Check'
          lines << ('=' * 72)
          lines << format('states total        : %d', Array(indoor_model.states).length)
          lines << format('states visible      : %d', visible_states)
          lines << format('transitions total   : %d', Array(indoor_model.transitions).length)
          lines << format('transitions visible : %d', visible_transitions)
          lines << format('GL line points      : %d', point_count)
          lines << format('GL segments         : %d', point_count / 2)
          lines << format('render cache entries: %d', cache_entries)
          lines << '--- checks ------------------------------------------------------------'
          checks.each do |entry|
            suffix = entry[:detail].nil? ? '' : " (#{entry[:detail]})"
            lines << format('%-6s %s%s', entry[:pass] ? 'PASS' : 'FAIL', entry[:label], suffix)
          end
          lines << '------------------------------------------------------------------------'
          lines << (checks.all? { |entry| entry[:pass] } ? 'RESULT: PASS' : 'RESULT: FAIL')
          lines << ('=' * 72)
          lines.join("\n")
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::DualOverlayRegressionCheck.run
