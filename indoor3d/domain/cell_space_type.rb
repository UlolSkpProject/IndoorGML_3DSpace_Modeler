# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      module CellSpaceType
        GENERAL    = 0 unless const_defined?(:GENERAL, false)
        TRANSITION = 1 unless const_defined?(:TRANSITION, false)
        CONNECTION = 2 unless const_defined?(:CONNECTION, false)
        ANCHOR     = 3 unless const_defined?(:ANCHOR, false)
        GEOMETRY_ONLY = 4 unless const_defined?(:GEOMETRY_ONLY, false)

        LABELS = {
          GENERAL => 'GeneralSpace',
          TRANSITION => 'TransitionSpace',
          CONNECTION => 'ConnectionSpace',
          ANCHOR => 'AnchorSpace',
          GEOMETRY_ONLY => 'CellSpace'
        }.freeze unless const_defined?(:LABELS, false)

        remove_const(:SELECTABLE_TYPES) if const_defined?(:SELECTABLE_TYPES, false)
        SELECTABLE_TYPES = [
          GENERAL,
          TRANSITION,
          CONNECTION,
          ANCHOR,
          GEOMETRY_ONLY
        ].freeze

        remove_const(:NAVIGABLE_TYPES) if const_defined?(:NAVIGABLE_TYPES, false)
        NAVIGABLE_TYPES = [
          GENERAL,
          TRANSITION,
          CONNECTION,
          ANCHOR
        ].freeze

        def self.label(value)
          LABELS[value] || LABELS[GENERAL]
        end

        def self.from_label(label)
          LABELS.key(label) || GENERAL
        end

        def self.navigable?(value)
          NAVIGABLE_TYPES.include?(value)
        end

        def self.geometry_only?(value)
          value == GEOMETRY_ONLY
        end

      end

    end
  end
end
