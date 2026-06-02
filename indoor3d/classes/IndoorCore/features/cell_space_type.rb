# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      module CellSpaceType
        GENERAL    = 0 unless const_defined?(:GENERAL, false)
        TRANSFER   = 1 unless const_defined?(:TRANSFER, false)
        TRANSITION = 2 unless const_defined?(:TRANSITION, false)
        CONNECTION = 3 unless const_defined?(:CONNECTION, false)
        ANCHOR     = 4 unless const_defined?(:ANCHOR, false)

        LABELS = {
          GENERAL => 'GeneralSpace',
          TRANSFER => 'TransferSpace',
          TRANSITION => 'TransitionSpace',
          CONNECTION => 'ConnectionSpace',
          ANCHOR => 'AnchorSpace'
        }.freeze unless const_defined?(:LABELS, false)

        SELECTABLE_TYPES = [
          GENERAL,
          TRANSITION,
          CONNECTION,
          ANCHOR
        ].freeze unless const_defined?(:SELECTABLE_TYPES, false)

        def self.label(value)
          LABELS[value] || LABELS[GENERAL]
        end

        def self.from_label(label)
          LABELS.key(label) || GENERAL
        end

        def self.selectable_labels
          SELECTABLE_TYPES.map { |type| label(type) }
        end
      end

    end
  end
end
