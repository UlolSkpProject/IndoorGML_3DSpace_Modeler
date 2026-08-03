# frozen_string_literal: true

require_relative 'screen_overlay'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module ProductionProgress
        class ProductionProgressOverlay < ScreenOverlay
          OVERLAY_ID = 'ulol.indoor3dgml_modeler.production_progress'
          OVERLAY_NAME = 'IndoorGML Production Progress'

          PANEL_WIDTH = 560
          PANEL_HEIGHT = 86
          PANEL_MARGIN = 20
          PANEL_COLOR = Sketchup::Color.new(28, 32, 38, 230)
          TRACK_COLOR = Sketchup::Color.new(78, 84, 94, 255)
          FILL_COLOR = Sketchup::Color.new(44, 150, 108, 255)
          TERMINAL_COLOR = Sketchup::Color.new(45, 115, 190, 255)
          FAILED_COLOR = Sketchup::Color.new(190, 55, 55, 255)
          PRIMARY_TEXT_COLOR = Sketchup::Color.new(255, 255, 255, 255)
          SECONDARY_TEXT_COLOR = Sketchup::Color.new(214, 220, 228, 255)

          attr_reader :snapshot

          def initialize
            @snapshot = nil
            @visible = false
            super(
              OVERLAY_ID,
              OVERLAY_NAME,
              description: 'Shows progress for IndoorGML production operations.'
            )
          end

          def update_snapshot(snapshot)
            @snapshot = snapshot
            @visible = true
            self.enabled = true if respond_to?(:enabled=)
            true
          end

          def hide
            @visible = false
            true
          end

          def visible?
            @visible == true
          end

          def draw(view)
            snapshot = @snapshot
            return unless @visible && snapshot

            width = [PANEL_WIDTH, viewport_width(view) - (PANEL_MARGIN * 2)].min
            return if width <= 120

            x = (viewport_width(view) - width) / 2.0
            y = [viewport_height(view) - PANEL_HEIGHT - PANEL_MARGIN, PANEL_MARGIN].max
            draw_panel(view, x, y, width, snapshot)
          rescue StandardError => e
            IndoorCore::Logger.puts "[IndoorGML] Production progress draw failed: #{e.class}: #{e.message}"
          end

          private

          def draw_panel(view, x, y, width, snapshot)
            draw_2d_quad(view, quad(x, y, width, PANEL_HEIGHT), PANEL_COLOR)

            view.draw_text(
              Geom::Point3d.new(x + 14, y + 10, 0),
              title_text(snapshot),
              text_options(size: 13, bold: true, color: PRIMARY_TEXT_COLOR)
            )
            view.draw_text(
              Geom::Point3d.new(x + 14, y + 34, 0),
              detail_text(snapshot),
              text_options(size: 10, bold: false, color: SECONDARY_TEXT_COLOR)
            )

            track_x = x + 14
            track_y = y + 65
            track_width = width - 28
            track_height = 8
            draw_2d_quad(view, quad(track_x, track_y, track_width, track_height), TRACK_COLOR)

            percent = displayed_percent(snapshot)
            fill_width = track_width * percent.fdiv(100.0)
            return unless fill_width.positive?

            draw_2d_quad(
              view,
              quad(track_x, track_y, fill_width, track_height),
              fill_color(snapshot)
            )
          end

          def title_text(snapshot)
            message = snapshot[:message].to_s.strip
            return message unless message.empty?

            snapshot[:title].to_s
          end

          def detail_text(snapshot)
            stage = snapshot[:stage]
            elapsed = format('%.1f초', snapshot[:elapsed].to_f)
            return format('%5.1f%% · %s', displayed_percent(snapshot), elapsed) unless stage

            parts = []
            position = stage_position_text(snapshot, stage)
            parts << position unless position.nil?
            parts << stage[:name].to_s

            completed = stage[:completed].to_i
            total = stage[:total].to_i
            parts << "#{completed} / #{total}" if total.positive?
            parts << format('%5.1f%%', displayed_percent(snapshot))
            parts << elapsed
            parts.join(' · ')
          end

          def stage_position_text(snapshot, stage)
            stage_metadata = metadata_hash(stage[:metadata])
            session_metadata = metadata_hash(snapshot[:metadata])
            stage_count = metadata_value(stage_metadata, :stage_count)
            stage_count = metadata_value(session_metadata, :stage_count) if stage_count.nil?
            stage_count = default_stage_count(session_metadata) if stage_count.nil?
            stage_count = stage_count.to_i
            return nil unless stage_count.positive?

            explicit_index = metadata_value(stage_metadata, :stage_index)
            stage_number = if explicit_index.nil?
                             Array(snapshot[:stages]).length + 1
                           else
                             explicit_index.to_i + 1
                           end
            stage_number = [[stage_number, 1].max, stage_count].min
            "#{stage_number} / #{stage_count}단계"
          rescue StandardError
            nil
          end

          def default_stage_count(session_metadata)
            operation = metadata_value(session_metadata, :operation).to_s
            case operation
            when 'cell_space_create'
              7
            when 'gml_export'
              5
            when 'runtime_refresh'
              metadata_value(session_metadata, :initial_model_load) == true ? 6 : 4
            end
          rescue StandardError
            nil
          end

          def metadata_hash(value)
            value.respond_to?(:[]) ? value : {}
          end

          def metadata_value(metadata, key)
            value = metadata[key]
            return value unless value.nil?

            metadata[key.to_s]
          rescue StandardError
            nil
          end

          def displayed_percent(snapshot)
            stage = snapshot[:stage]
            percent = stage ? stage[:percent] : snapshot[:percent]
            [[percent.to_f, 0.0].max, 100.0].min
          end

          def fill_color(snapshot)
            status = snapshot[:status].to_sym
            return FAILED_COLOR if status == :failed
            return TERMINAL_COLOR if snapshot[:terminal]

            FILL_COLOR
          end

          def quad(x, y, width, height)
            [
              [x, y, 0],
              [x + width, y, 0],
              [x + width, y + height, 0],
              [x, y + height, 0]
            ]
          end
        end

        class SketchupOverlayProgressRenderer
          DEFAULT_REFRESH_INTERVAL = 0.5

          attr_reader :overlay

          def initialize(model: Sketchup.active_model, refresh_interval: DEFAULT_REFRESH_INTERVAL, clock: nil)
            @model = model
            @refresh_interval = [refresh_interval.to_f, 0.0].max
            @clock = clock || proc { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
            @overlay = nil
            @registered = false
            @closed = false
            @last_refresh_at = nil
            @last_stage_signature = nil
          end

          def show(snapshot)
            return false if @closed
            return false unless ensure_registered

            @overlay.update_snapshot(snapshot)
            @last_stage_signature = stage_signature(snapshot)
            refresh_view(force: true)
            true
          end

          def update(snapshot)
            return false if @closed
            return false unless ensure_registered

            signature = stage_signature(snapshot)
            force = snapshot[:terminal] == true || signature != @last_stage_signature
            @overlay.update_snapshot(snapshot)
            @last_stage_signature = signature
            refresh_view(force: force)
            true
          end

          def hide(_snapshot = nil)
            return false unless @overlay

            @overlay.hide
            refresh_view(force: true)
            true
          rescue StandardError => e
            log_error('hide', e)
            false
          end

          def close
            return false if @closed

            @closed = true
            @overlay&.hide
            remove_overlay
            refresh_view(force: true)
            true
          rescue StandardError => e
            log_error('close', e)
            false
          end

          private

          def ensure_registered
            return true if @registered && @overlay&.valid?
            return false unless @model&.respond_to?(:overlays)

            remove_stale_overlays
            @overlay = ProductionProgressOverlay.new
            @model.overlays.add(@overlay)
            @overlay.enabled = true if @overlay.respond_to?(:enabled=)
            @registered = true
            true
          rescue StandardError => e
            log_error('registration', e)
            false
          end

          def remove_stale_overlays
            stale = []
            @model.overlays.each do |candidate|
              next unless candidate.respond_to?(:overlay_id)
              next unless candidate.overlay_id == ProductionProgressOverlay::OVERLAY_ID
              next if candidate.equal?(@overlay)

              stale << candidate
            end
            stale.each { |candidate| @model.overlays.remove(candidate) }
          end

          def remove_overlay
            overlay = @overlay
            @overlay = nil
            @registered = false
            return true unless overlay
            return true unless @model&.respond_to?(:overlays)
            return true if overlay.respond_to?(:valid?) && !overlay.valid?

            @model.overlays.remove(overlay)
            true
          end

          def refresh_view(force:)
            view = @model&.active_view
            return false unless view

            now = @clock.call.to_f
            due = @last_refresh_at.nil? || (now - @last_refresh_at) >= @refresh_interval
            return false unless force || due

            if view.respond_to?(:refresh)
              view.refresh
            elsif view.respond_to?(:invalidate)
              view.invalidate
            end
            @last_refresh_at = now
            true
          rescue StandardError => e
            log_error('view refresh', e)
            false
          end

          def stage_signature(snapshot)
            stage = snapshot[:stage]
            [stage&.dig(:name), stage&.dig(:status), snapshot[:status]]
          end

          def log_error(context, error)
            IndoorCore::Logger.puts(
              "[IndoorGML] Production progress #{context} failed: #{error.class}: #{error.message}"
            )
          rescue StandardError
            nil
          end
        end
      end
    end
  end
end
