# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore

      class EditorSession
        PAGE_NAME = 'IndoorGML Editing'

        def initialize(indoor_model)
          @indoor_model = indoor_model
          @editing = false
          @editable_entity_ids = {}
          @previous_page = nil
          @edit_page = nil
        end

        def editing?
          @editing
        end

        def begin_editing
          return false if @editing

          @indoor_model.refresh_runtime_data()
          model = Sketchup.active_model()
          pages = model.pages()
          @previous_page = pages.selected_page()
          remove_existing_edit_page(pages)
          @editing = true
          mark_editable_primal_entities()
          apply_lock_policy()
          focus_primal_group(model)
          @edit_page = pages.add(PAGE_NAME)
          pages.selected_page = @edit_page
          true
        end

        def finish
          return false unless @editing

          model = Sketchup.active_model()
          pages = model.pages()
          @editing = false
          @editable_entity_ids = {}
          apply_lock_policy()
          restore_previous_page(pages)
          pages.erase(@edit_page) if @edit_page&.valid?()
          @edit_page = nil
          @previous_page = nil
          true
        end

        def editable_entity?(entity)
          begin
            return false unless @editing
            return false unless entity&.valid?()

            @editable_entity_ids[entity.entityID] == true
          rescue StandardError
            false
          end
        end

        def lock_entity(entity)
          begin
            return true unless lockable?(entity)
            return true if editable_entity?(entity)

            entity.locked = true
            true
          rescue StandardError
            true
          end
        end

        def unlock_entity(entity)
          begin
            return true unless lockable?(entity)

            entity.locked = false
            true
          rescue StandardError
            true
          end
        end

        def with_unlocked(entity)
          begin
            entities = temporary_unlock_entities(entity)
            entities.each { |target| unlock_entity(target) }
            yield
          ensure
            entities&.reverse_each { |target| lock_entity(target) }
          end
        end

        def apply_lock_policy
          if @editing
            mark_editable_primal_entities()
          else
            @editable_entity_ids = {}
            clear_feature_editable_flags()
          end

          indoor_entities.each do |entity|
            if editable_entity?(entity)
              unlock_entity(entity)
            else
              lock_entity(entity)
            end
          end
        end

        private

        def remove_existing_edit_page(pages)
          existing_page = pages[PAGE_NAME]
          pages.erase(existing_page) if existing_page&.valid?()
        end

        def restore_previous_page(pages)
          if @previous_page&.valid?()
            pages.selected_page = @previous_page
          elsif pages.length.positive?
            pages.selected_page = pages[0]
          end
        end

        def focus_primal_group(model)
          begin
            primal_group = @indoor_model.primal_group
            return unless primal_group&.valid?()

            model.selection().clear()
            model.selection().add(primal_group)
            model.active_view().zoom(primal_group)
          rescue StandardError => e
            puts "[IndoorGML] Edit focus failed: #{e.class}: #{e.message}"
          end
        end

        def mark_editable_primal_entities
          @editable_entity_ids = {}
          mark_editable(@indoor_model.primal_group)
          @indoor_model.cell_spaces.each do |cell_space|
            cell_space.editable = true if cell_space.respond_to?(:editable=)
            mark_editable(cell_space.sketchup_group)
          end
          @indoor_model.states.each { |state| state.editable = false if state.respond_to?(:editable=) }
          @indoor_model.transitions.each { |transition| transition.editable = false if transition.respond_to?(:editable=) }
        end

        def clear_feature_editable_flags
          @indoor_model.cell_spaces.each { |cell_space| cell_space.editable = false if cell_space.respond_to?(:editable=) }
          @indoor_model.states.each { |state| state.editable = false if state.respond_to?(:editable=) }
          @indoor_model.transitions.each { |transition| transition.editable = false if transition.respond_to?(:editable=) }
        end

        def mark_editable(entity)
          begin
            return unless entity&.valid?()

            @editable_entity_ids[entity.entityID] = true
          rescue StandardError
            true
          end
        end

        def indoor_entities
          entities = []
          entities << @indoor_model.primal_group
          entities << @indoor_model.dual_group
          @indoor_model.cell_spaces.each { |cell_space| entities << cell_space.sketchup_group }
          @indoor_model.states.each { |state| entities << state.sketchup_component_instance }
          @indoor_model.transitions.each { |transition| entities << transition.edge }
          entities.compact.select { |entity| entity&.valid?() }
        end

        def temporary_unlock_entities(entity)
          entities = []
          entities << @indoor_model.dual_group if dual_feature_entity?(entity)
          entities << entity
          entities.compact.select { |target| target&.valid?() }
        end

        def dual_feature_entity?(entity)
          begin
            feature = entity.get_attribute(IndoorModel::ATTRIBUTE_DICTIONARY_NAME, 'feature')
            feature == 'State' || feature == 'Transition'
          rescue StandardError
            false
          end
        end

        def lockable?(entity)
          begin
            entity&.valid?() && entity.respond_to?(:locked=)
          rescue StandardError
            false
          end
        end
      end

    end
  end
end
