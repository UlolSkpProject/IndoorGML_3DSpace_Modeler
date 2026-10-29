# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class EditorSession
        # Owns only the val3dity error overlay. DualGraph and EditMode overlays
        # remain under OverlayController. Resolver output is already WORLD-space;
        # the service never applies edit_transform or Component transforms.
        class ValidationOverlayService
          OVERLAY_ID = 'ulol.indoor3dgml_modeler.validation_error_geometry_overlay'.freeze
          GEOMETRY_KEYS = %i[face_triangles face_edges overlap_triangles overlap_edges].freeze

          attr_reader :model, :overlay, :last_error

          def initialize(indoor_model:, overlay_factory:, resolver_factory:, invalidate_view: nil)
            @indoor_model = indoor_model
            @overlay_factory = overlay_factory
            @resolver_factory = resolver_factory
            @invalidate_view = invalidate_view || ->(model) { model&.active_view&.invalidate }
            @model = nil
            @overlay = nil
            @resolver = nil
            @scene_enabled = false
            @has_geometry = false
            @row_key = nil
            @last_geometry = nil
            @last_error = nil
          end

          def ensure_registered(model)
            # A Model switch always releases the old Validation overlay, even
            # when the new Model is invalid or lacks the Overlay API.
            return false unless switch_model(model)
            return fail_with('Overlay Model is invalid') unless valid_model?(model)
            return fail_with('SketchUp Overlay API is unavailable') unless manager_for(model)

            manager = manager_for(model)
            matches = []
            manager.each do |item|
              matches << item if item.respond_to?(:overlay_id) && item.overlay_id == OVERLAY_ID
            end

            reusable = matches.find { |item| compatible?(item) }
            # Discard only duplicate/invalid Validation overlays; never touch
            # DualGraph or Screen overlays (even on reused models).
            matches.each do |item|
              next if item.equal?(reusable)

              manager.remove(item)
            end
            still_duplicate = false
            manager.each do |item|
              if item.respond_to?(:overlay_id) && item.overlay_id == OVERLAY_ID &&
                 !item.equal?(reusable)
                still_duplicate = true
                break
              end
            end
            return fail_with('Duplicate Validation overlay could not be removed') if still_duplicate

            if reusable
              if !@overlay.equal?(reusable)
                @overlay = reusable
                @has_geometry = false
                @row_key = nil
                @last_geometry = nil
                # Registered instances from a previous Extension reload may
                # still hold old Row geometry; clear before adopting them.
                raise 'Registered Validation overlay could not be cleared' if @overlay.clear == false
                set_overlay_enabled(false, force: true)
                invalidate_view(model)
              end
              return true
            end

            candidate = @overlay_factory.call
            return fail_with('Validation overlay factory returned an incompatible Overlay') unless compatible?(candidate, require_valid: false)
            added = manager.add(candidate)
            return fail_with('Validation overlay registration was rejected') unless added

            @overlay = candidate
            @has_geometry = false
            @row_key = nil
            @last_geometry = nil
            set_overlay_enabled(false, force: true)
            invalidate_view(model)
            true
          rescue StandardError => e
            fail_with("Validation overlay registration failed: #{e.class}: #{e.message}")
          end

          # Resolution happens outside Overlay#draw. The existing Resolver owns
          # face lookup, 701/704 overlap evidence and rollback-only Boolean work.
          # Returns draw geometry on success, nil on unavailable/empty geometry.
          def show(model, row)
            unless row.is_a?(Hash)
              clear
              return nil
            end
            unless ensure_registered(model)
              registration_error = @last_error
              clear(force: true)
              fail_with(registration_error) if registration_error
              return nil
            end

            resolver = (@resolver ||= @resolver_factory.call)
            unless resolver
              clear(force: true)
              fail_with('Validation geometry resolver is unavailable')
              return nil
            end

            key = row_key(row)
            geometry = if @row_key == key && @last_geometry
                         @last_geometry
                       else
                         resolver.resolve(row)
                       end

            if !geometry.is_a?(Hash) || geometry[:status] == :failed || !geometry_present?(geometry)
              clear
              fail_with(geometry.is_a?(Hash) && geometry[:reason] ? geometry[:reason] : 'Validation geometry is empty')
              return nil
            end

            changed = @last_geometry != geometry || !@has_geometry
            if changed
              raise 'Validation Overlay rejected geometry' if @overlay.set_geometry(geometry) == false
              @last_geometry = geometry
              @has_geometry = true
              invalidate_view(model)
            end
            @row_key = key
            unless update_enabled
              enable_error = @last_error
              clear(force: true)
              fail_with(enable_error || 'Validation overlay could not be enabled')
              return nil
            end
            @last_error = nil
            geometry
          rescue StandardError => e
            clear(force: true)
            fail_with("Validation geometry show failed: #{e.class}: #{e.message}")
            nil
          end

          alias update show

          def clear(force: false)
            @row_key = nil
            @last_geometry = nil
            changed = false
            if valid_overlay?(@overlay)
              if @has_geometry || force
                raise 'Validation overlay refused Clear' if @overlay.clear == false
                @has_geometry = false
                changed = true
              end
              changed = set_overlay_enabled(false) || changed
            else
              @has_geometry = false
            end
            invalidate_view(@model) if changed
            @last_error = nil
            true
          rescue StandardError => e
            fail_with("Validation overlay clear failed: #{e.class}: #{e.message}")
          end

          # Disable without destroying Row geometry (e.g. toggling Edit Mode).
          def disable
            @scene_enabled = false
            update_enabled
          end

          def set_enabled(enabled)
            @scene_enabled = enabled == true
            update_enabled
          end

          def invalidate
            return false unless valid_model?(@model)

            @row_key = nil
            @last_geometry = nil
            true
          end

          # For actual CellSpace mutation/runtime refresh only. This existing
          # Resolver API also invalidates model-specific overlap evidence. Row
          # deselection and session end MUST NOT call it.
          def invalidate_geometry_cache
            @row_key = nil
            @last_geometry = nil
            if @resolver&.respond_to?(:clear_cache)
              @resolver.clear_cache
            elsif defined?(IndoorGmlConverter::ValidationErrorGeometryResolver)
              current = @model || @indoor_model.model
              IndoorGmlConverter::ValidationErrorGeometryResolver.clear_overlap_geometry(model: current) if current
            end
            true
          rescue StandardError => e
            fail_with("Validation geometry cache invalidation failed: #{e.class}: #{e.message}")
          end

          def clear_cache
            # Session-local memoization is dropped, but shared overlap evidence
            # survives so another inspection Row can reuse verified geometry.
            @resolver = nil
            @row_key = nil
            @last_geometry = nil
            true
          end

          def end_session
            cleared = clear
            disabled = disable
            cache_cleared = clear_cache
            cleared && disabled && cache_cleared
          end

          private

          def switch_model(next_model)
            return true if @model.equal?(next_model)

            if @model
              return false unless end_session
              @overlay = nil
            end
            first_model = @model.nil?
            @model = next_model
            @resolver = nil
            @scene_enabled = false unless first_model
            @has_geometry = false
            true
          end

          def update_enabled
            return true unless valid_overlay?(@overlay)

            desired = @scene_enabled && @has_geometry
            changed = set_overlay_enabled(desired)
            invalidate_view(@model) if changed
            true
          rescue StandardError => e
            fail_with("Validation overlay enabled update failed: #{e.class}: #{e.message}")
          end

          def set_overlay_enabled(value, force: false)
            return false unless valid_overlay?(@overlay)

            current = if @overlay.respond_to?(:enabled?)
                        @overlay.enabled?
                      elsif @overlay.respond_to?(:enabled)
                        @overlay.enabled
                      end
            return false if !force && current == value

            @overlay.enabled = value
            if @overlay.respond_to?(:enabled?) && @overlay.enabled? != value
              raise 'Validation overlay enabled state was not updated'
            end
            true
          end

          def geometry_present?(geometry)
            GEOMETRY_KEYS.any? { |key| !Array(geometry[key]).empty? }
          end

          def row_key(row)
            [row[:id] || row['id'], row.hash]
          end

          def manager_for(model)
            model.overlays if model&.respond_to?(:overlays)
          end

          def compatible?(item, require_valid: true)
            item && (!require_valid || valid_overlay?(item)) &&
              item.respond_to?(:overlay_id) && item.overlay_id == OVERLAY_ID &&
              item.respond_to?(:set_geometry) && item.respond_to?(:clear) &&
              item.respond_to?(:enabled=)
          end

          def valid_overlay?(item)
            item && (!item.respond_to?(:valid?) || item.valid?)
          rescue StandardError
            false
          end

          def valid_model?(model)
            model && (!model.respond_to?(:valid?) || model.valid?)
          rescue StandardError
            false
          end

          def invalidate_view(model)
            @invalidate_view.call(model) if valid_model?(model)
          end

          def fail_with(message)
            @last_error = message
            IndoorCore::Logger.puts("[IndoorGML] #{message}") if defined?(IndoorCore::Logger)
            false
          rescue StandardError
            false
          end
        end
      end
    end
  end
end
