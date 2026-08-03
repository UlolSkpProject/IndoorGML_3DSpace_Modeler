# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

module UI
  class << self
    attr_accessor :undo_trace_timers
  end

  def self.start_timer(_delay, _repeat, &block)
    self.undo_trace_timers ||= []
    undo_trace_timers << block
    undo_trace_timers.length
  end
end

module Sketchup
  class FakeEntity
    attr_reader :attributes, :write_count

    def initialize
      @attributes = {}
      @locked = true
      @write_count = 0
    end

    def valid?
      true
    end

    def entityID
      101
    end

    def persistent_id
      1001
    end

    def name
      'fake'
    end

    def set_attribute(dictionary, key, value)
      @attributes[[dictionary, key]] = value
    end

    def locked=(value)
      @write_count += 1
      @locked = value
    end
  end

  class FakeModel < FakeEntity
    attr_reader :operation_open

    def start_operation(_name, *_arguments)
      @operation_open = true
      true
    end

    def commit_operation
      @operation_open = false
      true
    end

    def abort_operation
      @operation_open = false
      true
    end
  end
end

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module Logger
        def self.puts(_message); end
      end

      class IndoorModel
        def initialize(model)
          @model = model
        end

        def with_indoor_model_operation(name, **_options)
          @model.start_operation(name, true, false, false)
          result = yield
          @model.commit_operation
          result
        end
      end

      class CommandDispatcher
        attr_reader :model

        def initialize
          @model = Sketchup::FakeModel.new
          @indoor_model = IndoorModel.new(@model)
        end

        def convert_selected_solid_groups_to_cell_spaces
          @indoor_model.with_indoor_model_operation('Convert Groups to CellSpace') do
            @model.set_attribute('IndoorGML', 'feature', 'CellSpace')
          end
          @model.locked = false
          :ok
        end
      end
    end
  end
end

require_relative '../indoor3d/application/diagnostics/create_cell_space_undo_trace'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class CreateCellSpaceUndoTraceTest < Minitest::Test
        Trace = Diagnostics::CreateCellSpaceUndoTrace

        def setup
          UI.undo_trace_timers = []
          @path = File.join(Dir.tmpdir, "undo_trace_test_#{Process.pid}.log")
          File.delete(@path) if File.exist?(@path)
          Trace.output_path = @path
        end

        def teardown
          Trace.finish(reason: :test_teardown) if Trace.active?
          File.delete(@path) if File.exist?(@path)
        end

        def test_records_property_write_after_commit_as_outside_operation
          dispatcher = CommandDispatcher.new

          assert_equal :ok, dispatcher.convert_selected_solid_groups_to_cell_spaces
          assert Trace.active?
          assert_equal 1, UI.undo_trace_timers.length

          UI.undo_trace_timers.shift.call

          refute Trace.active?
          log = File.read(@path, encoding: 'UTF-8')
          assert_match(/PROPERTY_WRITE IN_OPERATION .*method=set_attribute/, log)
          assert_match(/PROPERTY_WRITE OUTSIDE_OPERATION .*method=locked=/, log)
          assert_match(/outside_property_writes=1/, log)
          assert_match(/WRAPPER_ENTER name="Convert Groups to CellSpace"/, log)
        end
      end
    end
  end
end
