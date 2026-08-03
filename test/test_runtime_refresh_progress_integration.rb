# frozen_string_literal: true

require 'minitest/autorun'

module Sketchup
  class << self
    attr_accessor :runtime_progress_active_model
  end

  def self.active_model
    runtime_progress_active_model
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end unless const_defined?(:Logger)

      module ProductionProgress
        class ProductionProgressSession
          class << self
            attr_accessor :instances
          end
          self.instances = []

          attr_reader :events, :metadata, :title, :total

          def initialize(title:, total:, renderer:, cancellable:, metadata:)
            @title = title
            @total = total
            @renderer = renderer
            @cancellable = cancellable
            @metadata = metadata
            @events = []
            @active = false
            self.class.instances << self
          end

          def start(message: nil)
            @active = true
            @events << [:start, message]
          end

          def active?
            @active
          end

          def start_stage(name, total:, message:, cancellable:, metadata:)
            @events << [:stage_start, name, total, message, cancellable, metadata]
          end

          def update_stage(completed:, message: nil, telemetry: nil)
            @events << [:stage_update, completed, message, telemetry]
          end

          def finish_stage(message: nil, telemetry: nil)
            @events << [:stage_finish, message, telemetry]
          end

          def complete(message: nil, telemetry: nil)
            @events << [:complete, message, telemetry]
            @active = false
          end

          def fail(error, message: nil, telemetry: nil)
            @events << [:fail, error.class.name, message, telemetry]
            @active = false
          end

          def close
            @events << [:close]
            true
          end
        end

        class SketchupOverlayProgressRenderer
          def initialize(model:)
            @model = model
          end
        end

        module AdjacencyProgressContext
          THREAD_KEY = :test_runtime_refresh_adjacency_progress

          module_function

          def current
            Thread.current[THREAD_KEY]
          end

          def with(value)
            previous = current
            Thread.current[THREAD_KEY] = value
            yield
          ensure
            Thread.current[THREAD_KEY] = previous
          end
        end

        class AdjacencyProgressSink
          def initialize(progress, logger:)
            @progress = progress
            @open = false
          end

          def call(payload)
            case payload[:event]
            when :stage_start
              @progress.start_stage(
                payload[:name],
                total: payload[:total],
                message: payload[:message],
                cancellable: false,
                metadata: {}
              )
              @open = true
            when :stage_progress
              @progress.update_stage(
                completed: payload[:completed],
                message: payload[:message],
                telemetry: payload[:telemetry]
              )
            when :stage_finish
              @progress.finish_stage(
                message: payload[:message],
                telemetry: payload[:telemetry]
              )
              @open = false
            end
          end

          def finish_open_stage(message: nil, telemetry: nil)
            return false unless @open

            @progress.finish_stage(message: message, telemetry: telemetry)
            @open = false
            true
          end
        end
      end

      class RuntimeProgressFakeEntity
        attr_reader :entities
        attr_accessor :name

        def initialize(name: '', feature: nil, children: [])
          @name = name
          @feature = feature
          @entities = children
        end

        def valid?
          true
        end

        def get_attribute(_dictionary, key)
          key == 'feature' ? @feature : nil
        end
      end

      class RuntimeProgressFakeCellSpace
        attr_reader :id

        def initialize(id)
          @id = id
        end

        def valid?
          true
        end
      end

      class RuntimeProgressFakeModel
        attr_reader :entities

        def initialize(entities)
          @entities = entities
        end
      end

      class RuntimeRestorer
        def initialize(registry)
          @registry = registry
        end

        def restore(primal_group:, persist_repaired_ids: false)
          return true unless primal_group&.valid?

          restored = indoor_children(primal_group.entities, 'CellSpace').filter_map do |entity|
            restore_cell_space(entity)
          end
          restored.each { |cell_space| restore_state(cell_space) }
          true
        end

        private

        def restore_cell_space(entity)
          cell_space = RuntimeProgressFakeCellSpace.new(entity.name)
          @registry << cell_space
          cell_space
        end

        def restore_state(cell_space)
          cell_space
        end

        def indoor_children(entities, feature)
          entities.select do |entity|
            entity.get_attribute('IndoorGml', 'feature') == feature
          end
        end
      end

      class IndoorModel
        PRIMAL_GROUP_NAME = 'IndoorGML_PrimalSpaceFeatures'
        PRIMAL_GROUP_FEATURE = 'primalspace'
        ATTRIBUTE_DICTIONARY_NAME = 'IndoorGml'

        attr_reader :cell_spaces, :states, :transitions

        def initialize(model, fail_refresh: false)
          @model = model
          @cell_spaces = []
          @states = []
          @transitions = []
          @runtime_restorer = RuntimeRestorer.new(@cell_spaces)
          @fail_refresh = fail_refresh
        end

        def refresh_runtime_data(initial_model_load: false)
          raise 'refresh failed' if @fail_refresh

          if initial_model_load
            prepare_primal_children_for_initial_load
          else
            @primal_group ||= find_primal_group
          end
          @runtime_restorer.restore(
            primal_group: @primal_group,
            persist_repaired_ids: true
          )
          @states.concat(@cell_spaces)
          recenter_runtime_cell_spaces
          apply_initial_cell_space_materials if initial_model_load
          rebuild_runtime_transitions_from_cell_adjacency
          true
        end

        private

        def prepare_primal_children_for_initial_load
          @primal_group = find_primal_group
          true
        end

        def find_primal_group
          @model.entities.find do |entity|
            entity.name == PRIMAL_GROUP_NAME ||
              entity.get_attribute(
                ATTRIBUTE_DICTIONARY_NAME,
                'feature'
              ) == PRIMAL_GROUP_FEATURE
          end
        end

        def recenter_runtime_cell_spaces
          @cell_spaces.each do |cell_space|
            recenter_cell_space_origin(cell_space)
            write_cell_space_attributes(cell_space)
          end
        end

        def recenter_cell_space_origin(cell_space)
          cell_space
        end

        def write_cell_space_attributes(cell_space)
          cell_space
        end

        def apply_initial_cell_space_materials
          @cell_spaces.each { |cell_space| apply_cell_space_material(cell_space) }
        end

        def apply_cell_space_material(cell_space)
          cell_space
        end

        def rebuild_runtime_transitions_from_cell_adjacency
          sink = ProductionProgress::AdjacencyProgressContext.current
          if sink
            sink.call(
              event: :stage_start,
              name: 'Adjacency 상세 판정',
              total: 2,
              message: '판정 시작'
            )
            sink.call(
              event: :stage_progress,
              completed: 1,
              message: '판정 중',
              telemetry: nil
            )
            sink.call(
              event: :stage_finish,
              message: '판정 완료',
              telemetry: {}
            )
            sink.call(
              event: :stage_start,
              name: 'Transition 반영',
              total: 1,
              message: '반영 시작'
            )
            sink.call(
              event: :stage_finish,
              message: '반영 완료',
              telemetry: {}
            )
          end
          @transitions << :transition unless @cell_spaces.empty?
          { pair_comparison_count: 1 }
        end
      end
    end
  end
end

require_relative '../indoor3d/application/progress/runtime_refresh_progress_integration'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class RuntimeRefreshProgressIntegrationTest < Minitest::Test
        Session = ProductionProgress::ProductionProgressSession

        def setup
          Session.instances.clear
        end

        def teardown
          Sketchup.runtime_progress_active_model = nil
        end

        def test_empty_model_refreshes_without_progress_overlay
          model = RuntimeProgressFakeModel.new([])
          Sketchup.runtime_progress_active_model = model
          indoor_model = IndoorModel.new(model)

          assert indoor_model.refresh_runtime_data(initial_model_load: true)
          assert_empty Session.instances
        end

        def test_active_refresh_guard_does_not_start_nested_progress
          primal = build_primal(2)
          model = RuntimeProgressFakeModel.new([primal])
          Sketchup.runtime_progress_active_model = model
          indoor_model = IndoorModel.new(model)
          indoor_model.instance_variable_set(:@refreshing_runtime, true)

          assert indoor_model.refresh_runtime_data(initial_model_load: true)
          assert_empty Session.instances
        end

        def test_non_initial_full_refresh_uses_the_same_progress_pipeline
          primal = build_primal(2)
          model = RuntimeProgressFakeModel.new([primal])
          Sketchup.runtime_progress_active_model = model
          indoor_model = IndoorModel.new(model)

          assert indoor_model.refresh_runtime_data(initial_model_load: false)

          session = Session.instances.fetch(0)
          stage_names = session.events.filter_map do |event|
            event[1] if event[0] == :stage_start
          end
          assert_equal 'IndoorGML Runtime Refresh', session.title
          assert_equal 4, session.total
          assert_equal [
            'Runtime 데이터 복원',
            'CellSpace 위치 정리',
            'Adjacency 상세 판정',
            'Transition 반영'
          ], stage_names
        end

        def test_initial_load_reports_runtime_cell_and_topology_stages
          primal = build_primal(3)
          model = RuntimeProgressFakeModel.new([primal])
          Sketchup.runtime_progress_active_model = model
          indoor_model = IndoorModel.new(model)

          assert indoor_model.refresh_runtime_data(initial_model_load: true)

          session = Session.instances.fetch(0)
          stage_names = session.events.filter_map do |event|
            event[1] if event[0] == :stage_start
          end
          assert_equal 'IndoorGML 모델 열기', session.title
          assert_equal 6, session.total
          assert_equal [
            'IndoorGML 모델 구조 확인',
            'Runtime 데이터 복원',
            'CellSpace 위치 정리',
            'CellSpace 재질 적용',
            'Adjacency 상세 판정',
            'Transition 반영'
          ], stage_names
          assert_equal :complete, session.events[-2][0]
          assert_equal :close, session.events[-1][0]
          assert_equal 3, indoor_model.cell_spaces.length
          assert_equal 1, indoor_model.transitions.length
        end

        def test_cell_stages_use_adaptive_updates
          primal = build_primal(420)
          model = RuntimeProgressFakeModel.new([primal])
          Sketchup.runtime_progress_active_model = model
          indoor_model = IndoorModel.new(model)

          assert indoor_model.refresh_runtime_data(initial_model_load: true)

          session = Session.instances.fetch(0)
          update_events = session.events.select { |event| event[0] == :stage_update }
          assert_operator update_events.length, :<, 350
          assert update_events.any? { |event| event[1] == 1 }
          assert update_events.any? { |event| event[1] == 420 }
        end

        def test_failure_is_reported_and_session_is_closed
          primal = build_primal(1)
          model = RuntimeProgressFakeModel.new([primal])
          Sketchup.runtime_progress_active_model = model
          indoor_model = IndoorModel.new(model, fail_refresh: true)

          assert_raises(RuntimeError) do
            indoor_model.refresh_runtime_data(initial_model_load: true)
          end

          session = Session.instances.fetch(0)
          assert_equal :fail, session.events[-2][0]
          assert_equal :close, session.events[-1][0]
        end

        private

        def build_primal(count)
          children = count.times.map do |index|
            RuntimeProgressFakeEntity.new(
              name: "cell-#{index}",
              feature: 'CellSpace'
            )
          end
          RuntimeProgressFakeEntity.new(
            name: IndoorModel::PRIMAL_GROUP_NAME,
            feature: IndoorModel::PRIMAL_GROUP_FEATURE,
            children: children
          )
        end
      end
    end
  end
end
