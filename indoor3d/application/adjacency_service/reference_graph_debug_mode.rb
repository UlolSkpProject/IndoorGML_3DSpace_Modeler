# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # SketchUp Ruby Console:
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.before!
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.collapsed!
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.optimized!
      # RG.los_graph!         # Full line-of-sight graph of OPTIMIZED reference nodes.
      # RG.connectivity_repair! # Full LOS with verified connecting paths and restored nodes.
      # RG.short_path_graph!  # State-rooted Dijkstra tree from repaired graph.
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.clear!
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.mode
      # RG.highlight_on! / RG.highlight_off! / RG.highlight?
      # RG.toggle_highlight!
      #
      # Each stage command asks Native for one radius-free display snapshot.
      # It changes no State, Transition, geometry or undoable model data.
      module ReferenceGraphDebugMode
        module_function

        def mode
          @mode || :off
        end

        def off?
          mode == :off
        end

        def collapsed?
          mode == :collapsed
        end

        def optimized?
          mode == :optimized
        end

        def los_graph?
          mode == :los_graph
        end

        def connectivity_repair?
          mode == :connectivity_repair
        end

        def short_path_graph?
          mode == :short_path_graph
        end

        # Runtime-only selection highlight setting. Independent of RG.mode
        # and ON by default; changing it never touches Native or model data.
        def highlight?
          @selection_highlight_enabled != false
        end

        def highlight_on!
          set_selection_highlight(true)
        end

        def highlight_off!
          set_selection_highlight(false)
        end

        def toggle_highlight!
          set_selection_highlight(!highlight?)
        end

        def set_selection_highlight(enabled)
          @selection_highlight_enabled = (enabled == true)
          if defined?(Sketchup) && Sketchup.respond_to?(:active_model)
            Sketchup.active_model&.active_view&.invalidate
          end
          # puts "[IndoorGML] Selected CellSpace Highlight: #{highlight? ? 'ON' : 'OFF'}"
          highlight?
        end

        def before!
          set_mode(:before)
        end

        def collapsed!
          set_mode(:collapsed)
        end

        def optimized!
          set_mode(:optimized)
        end

        def los_graph!
          set_mode(:los_graph)
        end

        def connectivity_repair!
          set_mode(:connectivity_repair)
        end

        def short_path_graph!
          set_mode(:short_path_graph)
        end

        def clear!
          @mode = :off
          active_indoor_model&.clear_reference_graph_debug
          # puts '[IndoorGML] Reference Graph Overlay: OFF'
          :off
        end

        def off!
          clear!
        end

        def set_mode(value)
          return clear! if value.to_sym == :off
          value = value.to_sym
          unless %i[before collapsed optimized los_graph connectivity_repair short_path_graph].include?(value)
            raise ArgumentError, 'expected :off, :before, :collapsed, :optimized, :los_graph, :connectivity_repair or :short_path_graph'
          end

          active_indoor_model&.request_reference_graph_debug(value)
          @mode = value
          if defined?(Sketchup) && Sketchup.respond_to?(:active_model)
            Sketchup.active_model&.active_view&.invalidate
          end
          # puts "[IndoorGML] Reference Graph Overlay: #{value.upcase}"
          value
        end

        def active_indoor_model
          return nil unless defined?(IndoorModel)

          IndoorModel.current
        rescue StandardError
          nil
        end
        private_class_method :active_indoor_model
      end
    end
  end
end

# Short alias for the SketchUp Ruby Console. Never overwrite another extension's RG.
unless Object.const_defined?(:RG, false)
  Object.const_set(:RG, ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode)
end
