# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class CellSpace < AbstractFeature
        attr_reader :sketchup_group
        attr_reader :sketchup_group_id
        attr_accessor :cell_type
        attr_accessor :category_code
        attr_accessor :category_label
        attr_accessor :category_code_space
        attr_accessor :category_standard
        attr_accessor :editable
        attr_reader :duality_state

        def initialize(sketchup_group, cell_type = CellSpaceType::GENERAL, category_code = nil)
          self.class.validate_sketchup_group!(sketchup_group)

          super()

          @sketchup_group = sketchup_group
          @sketchup_group_id = sketchup_group.persistent_id
          @cell_type = cell_type
          set_category(category_code)
          @editable = false
          @duality_state = nil
        end

        def set_category(category_code = nil, category_label = nil, category_code_space = nil, category_standard = nil)
          category = CellSpaceCategory.normalize(
            @cell_type,
            category_code,
            category_label,
            category_code_space,
            category_standard
          )
          @category_code = category[:code]
          @category_label = category[:label]
          @category_code_space = category[:code_space]
          @category_standard = category[:standard]
        end

        def create_duality_state(parent_entities, local_position = nil)
          @duality_state ||= State.new(self, parent_entities, local_position)
        end

        def restore_duality_state(state)
          @duality_state = state
        end

        def valid?
          @sketchup_group&.valid? == true
        end

        def valid_sketchup_group
          return nil unless @sketchup_group&.valid?

          @sketchup_group
        rescue StandardError
          nil
        end

        def erase!
          @sketchup_group.erase! if valid?
        end

        def self.restore(sketchup_group, cell_type, id: nil, name: nil, category_code: nil, category_label: nil, category_code_space: nil, category_standard: nil)
          validate_sketchup_group!(sketchup_group)

          cell_space = allocate
          cell_space.send(:initialize_restored, sketchup_group, cell_type, id, name, category_code, category_label, category_code_space, category_standard)
          cell_space
        end

        def self.validate_sketchup_group!(sketchup_group)
          unless sketchup_group.is_a?(Sketchup::Group) || sketchup_group.is_a?(Sketchup::ComponentInstance)
            raise ArgumentError, 'Sketchup::Group or Sketchup::ComponentInstance expected'
          end

          unless sketchup_group.valid?
            raise ArgumentError, 'Valid Sketchup::Group or Sketchup::ComponentInstance expected'
          end

          unless sketchup_group.respond_to?(:manifold?) && sketchup_group.manifold?
            raise ArgumentError, 'Solid Group expected'
          end
        end

        private

        def initialize_restored(sketchup_group, cell_type, id, name, category_code, category_label, category_code_space, category_standard)
          @sketchup_group = sketchup_group
          @sketchup_group_id = sketchup_group.persistent_id
          @cell_type = cell_type
          set_category(category_code, category_label, category_code_space, category_standard)
          @editable = false
          @duality_state = nil
          @id = id unless id.to_s.empty?
          @name = name.to_s
        end

      end

    end
  end
end
