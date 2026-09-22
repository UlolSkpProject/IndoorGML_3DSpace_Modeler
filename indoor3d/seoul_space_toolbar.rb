# frozen_string_literal: true
# encoding: UTF-8

require 'sketchup.rb'

unless defined?(SeoulSpaceToolbar)
  module SeoulSpaceToolbar
    TOOLBAR_NAME = 'SeoulSpace'.freeze
    EXPECTED_GROUPS = %i[tag rm verify indoorgml obj].freeze
    FALLBACK_DELAY = 0.25

    @groups = {}
    @timer_id = nil
    @built = false

    class << self
      def register(group, order:, items:)
        key = group.to_sym
        @groups[key] = {
          order: Integer(order),
          items: Array(items).dup
        }

        if ready?
          cancel_timer
          build
        else
          schedule_build
        end
      end

      def toolbar
        @toolbar
      end

      private

      def ready?
        (EXPECTED_GROUPS - @groups.keys).empty?
      end

      def schedule_build
        return if @built
        return unless ::UI.respond_to?(:start_timer)

        cancel_timer
        @timer_id = ::UI.start_timer(FALLBACK_DELAY, false) do
          @timer_id = nil
          build
        end
      end

      def cancel_timer
        return unless @timer_id

        ::UI.stop_timer(@timer_id)
        @timer_id = nil
      rescue StandardError
        @timer_id = nil
      end

      def build
        return if @built || @groups.empty?

        @toolbar = ::UI::Toolbar.new(TOOLBAR_NAME)

        @groups.values.sort_by { |group| group[:order] }.each_with_index do |group, index|
          @toolbar.add_separator if index.positive?
          group[:items].each do |item|
            item == :separator ? @toolbar.add_separator : @toolbar.add_item(item)
          end
        end

        last_state = @toolbar.get_last_state
        @toolbar.restore
        @toolbar.show if defined?(::TB_NEVER_SHOWN) && last_state == ::TB_NEVER_SHOWN

        @built = true
      rescue StandardError => e
        puts "[SeoulSpaceToolbar] Build failed: #{e.class}: #{e.message}"
      end
    end
  end
end
