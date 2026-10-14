# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      # SketchUp Ruby Console:
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.before!
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.after!
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.collapsed!
      # ULOL::Indoor3DGmlModeler::IndoorCore::ReferenceGraphDebugMode.mode
      #
      # Controls only the runtime debug overlay. Both graph snapshots remain
      # intact; no State, Transition, Geometry or undoable model data changes.
      module ReferenceGraphDebugMode
        module_function

        def mode
          @mode || :before
        end

        def after?
          mode == :after
        end

        def collapsed?
          mode == :collapsed
        end

        def before!
          set_mode(:before)
        end

        def after!
          set_mode(:after)
        end

        def collapsed!
          set_mode(:collapsed)
        end

        def set_mode(value)
          raise ArgumentError, 'expected :before, :after or :collapsed' unless %i[before after collapsed].include?(value)

          @mode = value
          if defined?(Sketchup) && Sketchup.respond_to?(:active_model)
            Sketchup.active_model&.active_view&.invalidate
          end
          puts "[IndoorGML] Reference Graph Overlay: #{value.upcase}"
          value
        end
      end
    end
  end
end
