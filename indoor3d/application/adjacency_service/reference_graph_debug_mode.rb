# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # SketchUp Ruby Console:
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.before!
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.collapsed!
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.optimized!
      # RG.los_graph!         # All 3D LOS edges among OPTIMIZED nodes.
      # RG.connectivity_repair! # Full LOS plus restored intermediate nodes.
      # RG.short_path_graph!  # State-rooted Dijkstra tree from repaired graph.
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.clear!
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.mode
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
          puts '[IndoorGML] Reference Graph Overlay: OFF'
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

          count = active_indoor_model&.request_reference_graph_debug(value).to_i
          @mode = value
          if defined?(Sketchup) && Sketchup.respond_to?(:active_model)
            Sketchup.active_model&.active_view&.invalidate
          end
          puts "[IndoorGML] Reference Graph Overlay: #{value.upcase} (#{count} CellSpace)"
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
