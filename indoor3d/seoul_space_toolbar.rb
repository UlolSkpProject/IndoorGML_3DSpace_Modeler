# frozen_string_literal: true
# encoding: UTF-8

require 'sketchup.rb'

module SeoulSpaceToolbar
  desired_name = '서울시 공간정보구축 Tools'.freeze
  if const_defined?(:TOOLBAR_NAME, false) && const_get(:TOOLBAR_NAME) != desired_name
    remove_const(:TOOLBAR_NAME)
  end
  const_set(:TOOLBAR_NAME, desired_name) unless const_defined?(:TOOLBAR_NAME, false)

  desired_groups = %i[tag rm verify indoorgml obj manager].freeze
  if const_defined?(:EXPECTED_GROUPS, false) && const_get(:EXPECTED_GROUPS) != desired_groups
    remove_const(:EXPECTED_GROUPS)
  end
  const_set(:EXPECTED_GROUPS, desired_groups) unless const_defined?(:EXPECTED_GROUPS, false)

  const_set(:FALLBACK_DELAY, 0.25) unless const_defined?(:FALLBACK_DELAY, false)

  @groups ||= {}
  @timer_id = nil unless instance_variable_defined?(:@timer_id)
  @built = false unless instance_variable_defined?(:@built)
  @built_groups ||= if @built
                      @groups.keys.each_with_object({}) { |key, memo| memo[key] = true }
                    else
                      {}
                    end

  class << self
    def register(group, order:, items:)
      key = group.to_sym
      @groups[key] = {
        order: Integer(order),
        items: Array(items).dup
      }

      if @built
        append_group(key)
      elsif ready?
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
      @built_groups = {}

      @groups.sort_by { |_key, group| group[:order] }.each_with_index do |(key, group), index|
        append_group_items(group, separator: index.positive?)
        @built_groups[key] = true
      end

      last_state = @toolbar.get_last_state
      @toolbar.restore
      @toolbar.show if defined?(::TB_NEVER_SHOWN) && last_state == ::TB_NEVER_SHOWN

      @built = true
    rescue StandardError => e
      puts "[SeoulSpaceToolbar] Build failed: #{e.class}: #{e.message}"
    end

    def append_group(key)
      return if @built_groups[key]

      group = @groups[key]
      return unless group

      unless @toolbar
        @built = false
        build
        return
      end

      was_visible = @toolbar.visible?
      append_group_items(group, separator: @toolbar.length.positive?)
      @built_groups[key] = true
      @toolbar.show if was_visible
    rescue StandardError => e
      puts "[SeoulSpaceToolbar] Late group append failed (#{key}): #{e.class}: #{e.message}"
    end

    def append_group_items(group, separator:)
      @toolbar.add_separator if separator

      group[:items].each do |item|
        item == :separator ? @toolbar.add_separator : @toolbar.add_item(item)
      end
    end
  end
end
