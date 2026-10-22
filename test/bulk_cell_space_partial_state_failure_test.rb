# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../indoor3d/application/cell_space_conversion'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module EntityCopyHelper
        class << self
          attr_accessor :copies

          def copy_instance(**_options)
            Array(@copies).shift
          end
        end
      end unless const_defined?(:EntityCopyHelper)
    end
  end
end

class BulkCellSpacePartialStateFailureTest < Minitest::Test
  IndoorCore = ULOL::Indoor3DGmlModeler::IndoorCore

  class FakeEntity
    attr_reader :name

    def initialize(name)
      @name = name
      @valid = true
    end

    def valid?
      @valid
    end

    def erase!
      @valid = false
    end
  end

  FakeCell = Struct.new(:id)

  class FakeLogger
    def self.puts(_message); end
  end

  def test_native_state_failure_keeps_failed_source_and_commits_successful_source
    good_source = FakeEntity.new('good source')
    bad_source = FakeEntity.new('bad source')
    good_copy = FakeEntity.new('good copy')
    bad_copy = FakeEntity.new('bad copy')
    IndoorCore::EntityCopyHelper.copies = [good_copy, bad_copy]
    created = []
    restored = false
    rollback_requested = nil

    service = IndoorCore::BulkCellSpaceConversionService.new(
      model: Object.new,
      jobs: [
        { source: good_source, transformation: nil, ancestors: [] },
        { source: bad_source, transformation: nil, ancestors: [] }
      ],
      fallback_target: [:room, nil],
      target_entities: Object.new,
      converter: proc do |copy, *_target|
        cell = FakeCell.new(copy == good_copy ? 'good-cell' : 'bad-cell')
        created << cell
        cell
      end,
      synchronize_all: proc do
        {
          native_state_failures: [{
            cell_id: 'bad-cell',
            reason: 'Native State unavailable: insufficient_clearance'
          }]
        }
      end,
      apply_lock_policy: proc {},
      runtime_snapshot: proc { :snapshot },
      runtime_restore: proc { |_snapshot| restored = true },
      apply_guards: proc { |&block| block.call },
      operation_runner: proc do |_name, **options, &block|
        value = block.call
        rollback_requested = options.fetch(:rollback_if).call
        value
      end,
      restore_active_path: proc {},
      activate_root_context: proc { true },
      clear_dirty_topology: proc {},
      logger: FakeLogger
    )

    result = service.call

    assert_equal 1, result.converted_count
    assert_equal 1, result.errors.length
    assert_match(/insufficient_clearance/, result.errors.first[:reason])
    refute good_source.valid?, 'successful conversion should remove its original source'
    assert bad_source.valid?, 'failed Native State conversion must retain its original source'
    assert_equal false, rollback_requested
    assert_equal false, restored
    assert_equal %w[good-cell bad-cell], created.map(&:id)
  end

  def test_all_native_state_failures_keep_every_source_and_roll_back_batch
    first_source = FakeEntity.new('first source')
    second_source = FakeEntity.new('second source')
    first_copy = FakeEntity.new('first copy')
    second_copy = FakeEntity.new('second copy')
    IndoorCore::EntityCopyHelper.copies = [first_copy, second_copy]
    restored = false
    rollback_requested = nil

    service = IndoorCore::BulkCellSpaceConversionService.new(
      model: Object.new,
      jobs: [
        { source: first_source, transformation: nil, ancestors: [] },
        { source: second_source, transformation: nil, ancestors: [] }
      ],
      fallback_target: [:room, nil],
      target_entities: Object.new,
      converter: proc do |copy, *_target|
        FakeCell.new(copy == first_copy ? 'first-cell' : 'second-cell')
      end,
      synchronize_all: proc do
        {
          native_state_failures: [
            { cell_id: 'first-cell', reason: 'first State failed' },
            { cell_id: 'second-cell', reason: 'second State failed' }
          ]
        }
      end,
      apply_lock_policy: proc {},
      runtime_snapshot: proc { :snapshot },
      runtime_restore: proc { |_snapshot| restored = true },
      apply_guards: proc { |&block| block.call },
      operation_runner: proc do |_name, **options, &block|
        value = block.call
        rollback_requested = options.fetch(:rollback_if).call
        value
      end,
      restore_active_path: proc {},
      activate_root_context: proc { true },
      clear_dirty_topology: proc {},
      logger: FakeLogger
    )

    result = service.call

    assert_equal 0, result.converted_count
    assert_equal 2, result.errors.length
    assert first_source.valid?, 'a failed conversion must retain its original source'
    assert second_source.valid?, 'a failed conversion must retain its original source'
    assert_equal true, rollback_requested
    assert_equal true, restored
  end
end
