# frozen_string_literal: true

require 'minitest/autorun'
require 'tmpdir'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module CellSpaceType
        GENERAL = 0 unless const_defined?(:GENERAL, false)
        TRANSITION = 1 unless const_defined?(:TRANSITION, false)
        CONNECTION = 2 unless const_defined?(:CONNECTION, false)
        ANCHOR = 3 unless const_defined?(:ANCHOR, false)
        GEOMETRY_ONLY = 4 unless const_defined?(:GEOMETRY_ONLY, false)
      end
    end
  end
end

require_relative '../indoor3d/application/precision_validation/crash_isolation'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module PrecisionValidation
        class PrecisionValidationCrashIsolationTest < Minitest::Test
          Cell = Struct.new(:id, :cell_type, :category_code)

          class FakeTimerApi
            attr_reader :callback

            def start_timer(_interval, _repeat, &block)
              @callback = block
              1
            end

            def stop_timer(_timer_id)
              true
            end

            def pulse(limit: 100)
              limit.times do
                break unless @callback
                break if @callback.call == false
              end
            end
          end

          class FakeProcess
            attr_accessor :finished
            attr_reader :exit_code, :terminated_waits

            def initialize(exit_code, finished: true, terminate_result: true, progress: [])
              @exit_code = exit_code
              @finished = finished
              @terminate_result = terminate_result
              @terminated_waits = []
              @progress = Array(progress).dup
            end

            def start(total_states:, total_transitions:)
              raise unless total_states == 0 && total_transitions == 0
              self
            end

            def finished?
              @finished == true
            end

            def join_reader
              true
            end

            def pop_progress
              @progress.shift
            end

            def close
              true
            end

            def terminate(wait_ms:)
              @terminated_waits << wait_ms
              @finished = true if @terminate_result
              @terminate_result
            end
          end

          def setup
            @plan = CrashIsolationPlan.new
          end

          def test_groups_supported_categories_in_stable_order
            cells = [
              Cell.new('room', CellSpaceType::GENERAL, 'Room'),
              Cell.new('stair-1', CellSpaceType::TRANSITION, 'Stair'),
              Cell.new('stair-2', CellSpaceType::TRANSITION, 'Stair'),
              Cell.new('stair-3', CellSpaceType::TRANSITION, 'Stair'),
              Cell.new('door', CellSpaceType::CONNECTION, 'Door'),
              Cell.new('elevator', CellSpaceType::TRANSITION, 'Elevator'),
              Cell.new('window', CellSpaceType::GEOMETRY_ONLY, 'Window'),
              Cell.new('anchor', CellSpaceType::ANCHOR, 'ExteriorDoor')
            ]

            jobs = @plan.initial_jobs(cells)

            assert_equal CrashIsolationPlan::CATEGORY_ORDER, jobs.map { |job| job[:category] }
            assert_equal ['room'], jobs[0][:cell_spaces].map(&:id)
            assert_equal %w[stair-1 stair-2], jobs[1][:cell_spaces].map(&:id)
            assert_equal ['stair-3'], jobs[2][:cell_spaces].map(&:id)
            assert_equal %w[door elevator window anchor], jobs[3][:cell_spaces].map(&:id)
          end

          def test_even_stairs_are_split_equally_between_initial_jobs
            stairs = 40.times.map do |index|
              Cell.new("stair-#{index}", CellSpaceType::TRANSITION, 'Stair')
            end

            jobs = @plan.initial_jobs(stairs)

            assert_equal [
              CrashIsolationPlan::STAIR_FIRST_CATEGORY,
              CrashIsolationPlan::STAIR_SECOND_CATEGORY
            ], jobs.map { |job| job[:category] }
            assert_equal [20, 20], jobs.map { |job| job[:cell_spaces].length }
            assert_equal stairs, jobs.flat_map { |job| job[:cell_spaces] }
          end

          def test_falls_back_to_cell_type_for_known_semantics
            cells = [
              Cell.new('door', CellSpaceType::CONNECTION, nil),
              Cell.new('gate', CellSpaceType::ANCHOR, nil),
              Cell.new('window', CellSpaceType::GEOMETRY_ONLY, nil),
              Cell.new('room', CellSpaceType::GENERAL, nil)
            ]

            assert_equal [
              CrashIsolationPlan::COMBINED_CATEGORY,
              CrashIsolationPlan::COMBINED_CATEGORY,
              CrashIsolationPlan::COMBINED_CATEGORY,
              'Room'
            ], cells.map { |cell| @plan.category_for(cell) }
          end

          def test_crashing_job_is_split_into_at_most_four_balanced_quarters
            cells = 10.times.map { |index| Cell.new("cell-#{index}", CellSpaceType::GENERAL, 'Room') }

            children = @plan.split(category: 'Room', cell_spaces: cells, depth: 2)

            assert_equal 4, children.length
            assert_equal [3, 3, 3, 1], children.map { |job| job[:cell_spaces].length }
            assert children.all? { |job| job[:depth] == 3 }
            assert_equal cells, children.flat_map { |job| job[:cell_spaces] }
          end

          def test_single_cell_job_cannot_be_split_further
            cell = Cell.new('only', CellSpaceType::GENERAL, 'Room')

            assert_empty @plan.split(category: 'Room', cell_spaces: [cell], depth: 0)
          end

          def test_coordinator_quarter_isolates_only_the_crashing_cell
            cells = 9.times.map { |index| Cell.new("cell-#{index}", CellSpaceType::GENERAL, 'Room') }
            path_cells = {}
            timer = FakeTimerApi.new
            result = nil
            snapshots = []
            coordinator = CrashIsolationCoordinator.new(
              indoor_model: Struct.new(:cell_spaces, :model).new(cells, nil),
              work_dir: Dir.tmpdir,
              overlap_tol_mm: 0.01,
              timer_api: timer,
              exporter: proc { |subset, path| path_cells[path] = subset },
              process_factory: proc do |gml_path, _report_path|
                crashes = path_cells.fetch(gml_path).any? { |cell| cell.id == 'cell-7' }
                FakeProcess.new(crashes ? 1 : 0)
              end
            )

            coordinator.start(on_progress: proc { |snapshot| snapshots << snapshot }) do |value|
              result = value
            end
            timer.pulse

            assert coordinator.finished?
            refute_nil result
            refute result.error?
            assert_equal ['cell-7'], result.crash_cell_spaces.map(&:id)
            assert_operator result.records.length, :>, 1
            assert result.records.any? { |row| row[:depth] >= 2 }
            room_rows = snapshots.flat_map { |snapshot| snapshot[:categories] }
                                 .select { |row| row[:category] == 'Room' }
            assert room_rows.any? { |row| row[:status] == :splitting }
            assert room_rows.any? { |row| row[:split_count] >= 2 }
            assert_equal :crashed, result.progress[:categories].first[:status]
            assert_equal 1, result.progress[:categories].first[:crash_cell_count]
          end

          def test_coordinator_marks_parent_cells_when_only_combination_crashes
            cells = 4.times.map { |index| Cell.new("pair-#{index}", CellSpaceType::GENERAL, 'Room') }
            path_cells = {}
            timer = FakeTimerApi.new
            result = nil
            coordinator = CrashIsolationCoordinator.new(
              indoor_model: Struct.new(:cell_spaces, :model).new(cells, nil),
              work_dir: Dir.tmpdir,
              overlap_tol_mm: 0.01,
              timer_api: timer,
              exporter: proc { |subset, path| path_cells[path] = subset },
              process_factory: proc do |gml_path, _report_path|
                FakeProcess.new(path_cells.fetch(gml_path).length > 1 ? 1 : 0)
              end
            )

            coordinator.start { |value| result = value }
            timer.pulse

            assert_equal cells.map(&:id), result.crash_cell_spaces.map(&:id)
          end

          def test_aabb_progress_marks_probe_passed_and_stops_process_early
            cells = 4.times.map { |index| Cell.new("room-#{index}", CellSpaceType::GENERAL, 'Room') }
            timer = FakeTimerApi.new
            process = FakeProcess.new(
              99,
              finished: false,
              progress: [{ phase: '4. Overlap Primal Cells', message: 'Constructing AABB tree' }]
            )
            result = nil
            coordinator = CrashIsolationCoordinator.new(
              indoor_model: Struct.new(:cell_spaces, :model).new(cells, nil),
              work_dir: Dir.tmpdir,
              overlap_tol_mm: 0.01,
              timer_api: timer,
              exporter: proc { |_subset, _path| true },
              process_factory: proc { |_gml_path, _report_path| process }
            )

            coordinator.start { |value| result = value }
            timer.pulse

            assert_equal [200], process.terminated_waits
            assert_empty result.crash_cell_spaces
            assert_equal 1, result.records.length
            assert_equal :aabb_reached, result.records.first[:outcome]
            assert result.records.first[:aabb_reached]
            assert result.records.first[:early_stopped]
            assert_equal 4, result.progress[:categories].first[:aabb_passed_cell_space_count]
          end

          def test_nef_progress_alone_does_not_mark_probe_passed
            cell = Cell.new('room-crash', CellSpaceType::GENERAL, 'Room')
            timer = FakeTimerApi.new
            process = FakeProcess.new(
              1,
              progress: [{ phase: '4. Overlap Primal Cells', message: 'Constructing Nef polyhedra' }]
            )
            result = nil
            coordinator = CrashIsolationCoordinator.new(
              indoor_model: Struct.new(:cell_spaces, :model).new([cell], nil),
              work_dir: Dir.tmpdir,
              overlap_tol_mm: 0.01,
              timer_api: timer,
              exporter: proc { |_subset, _path| true },
              process_factory: proc { |_gml_path, _report_path| process }
            )

            coordinator.start { |value| result = value }
            timer.pulse

            assert_empty process.terminated_waits
            assert_equal ['room-crash'], result.crash_cell_spaces.map(&:id)
            assert_equal :crashed, result.records.first[:outcome]
            refute result.records.first[:aabb_reached]
          end

          def test_coordinator_launches_four_initial_type_bucket_processes_concurrently
            cells = [
              Cell.new('room', CellSpaceType::GENERAL, 'Room'),
              Cell.new('stair-1', CellSpaceType::TRANSITION, 'Stair'),
              Cell.new('stair-2', CellSpaceType::TRANSITION, 'Stair'),
              Cell.new('door', CellSpaceType::CONNECTION, 'Door'),
              Cell.new('elevator', CellSpaceType::TRANSITION, 'Elevator'),
              Cell.new('window', CellSpaceType::GEOMETRY_ONLY, 'Window'),
              Cell.new('anchor', CellSpaceType::ANCHOR, 'ExteriorDoor')
            ]
            timer = FakeTimerApi.new
            process_count = 0
            exported_subsets = []
            coordinator = CrashIsolationCoordinator.new(
              indoor_model: Struct.new(:cell_spaces, :model).new(cells, nil),
              work_dir: Dir.tmpdir,
              overlap_tol_mm: 0.01,
              timer_api: timer,
              exporter: proc do |subset, _path|
                exported_subsets << subset.map(&:id)
              end,
              process_factory: proc do |_gml_path, _report_path|
                process_count += 1
                FakeProcess.new(0)
              end
            )

            coordinator.start { |_value| nil }

            assert_equal 4, process_count
            assert_equal 4, coordinator.instance_variable_get(:@active_processes).length
            assert_empty coordinator.instance_variable_get(:@pending)
            assert_equal [
              ['room'],
              ['stair-1'],
              ['stair-2'],
              %w[door elevator window anchor]
            ], exported_subsets
          ensure
            coordinator&.terminate(wait_ms: 0)
          end

          def test_cancel_terminates_every_running_probe_process
            cells = [
              Cell.new('room', CellSpaceType::GENERAL, 'Room'),
              Cell.new('stair-1', CellSpaceType::TRANSITION, 'Stair'),
              Cell.new('stair-2', CellSpaceType::TRANSITION, 'Stair'),
              Cell.new('door', CellSpaceType::CONNECTION, 'Door')
            ]
            timer = FakeTimerApi.new
            processes = []
            coordinator = CrashIsolationCoordinator.new(
              indoor_model: Struct.new(:cell_spaces, :model).new(cells, nil),
              work_dir: Dir.tmpdir,
              overlap_tol_mm: 0.01,
              timer_api: timer,
              exporter: proc { |_subset, _path| true },
              process_factory: proc do |_gml_path, _report_path|
                process = FakeProcess.new(0, finished: false)
                processes << process
                process
              end
            )

            coordinator.start { |_value| nil }
            assert_equal 4, processes.length

            assert coordinator.terminate(wait_ms: 200)

            assert coordinator.terminated?
            assert coordinator.finished?
            assert processes.all? { |process| process.terminated_waits == [200] }
            assert_empty coordinator.instance_variable_get(:@active_processes)
          end

          def test_cancel_defers_completion_until_a_probe_that_failed_to_terminate_exits
            cell = Cell.new('room', CellSpaceType::GENERAL, 'Room')
            timer = FakeTimerApi.new
            process = FakeProcess.new(0, finished: false, terminate_result: false)
            coordinator = CrashIsolationCoordinator.new(
              indoor_model: Struct.new(:cell_spaces, :model).new([cell], nil),
              work_dir: Dir.tmpdir,
              overlap_tol_mm: 0.01,
              timer_api: timer,
              exporter: proc { |_subset, _path| true },
              process_factory: proc { |_gml_path, _report_path| process }
            )

            coordinator.start { |_value| nil }

            refute coordinator.terminate(wait_ms: 200)
            refute coordinator.finished?

            process.finished = true

            assert coordinator.finished?
            assert_empty coordinator.instance_variable_get(:@active_processes)
          end

          def test_cached_results_skip_probes_and_cached_crashes_remain_lvn_targets
            cached_pass = Cell.new('room-cache', CellSpaceType::GENERAL, 'Room')
            cached_crash = Cell.new('door-cache', CellSpaceType::CONNECTION, 'Door')
            probe = Cell.new('stair-probe', CellSpaceType::TRANSITION, 'Stair')
            timer = FakeTimerApi.new
            launched_subsets = []
            result = nil
            coordinator = CrashIsolationCoordinator.new(
              indoor_model: Struct.new(:cell_spaces, :model).new([], nil),
              cell_spaces: [probe],
              cached_checked_cell_spaces: [cached_pass, cached_crash],
              cached_crash_cell_spaces: [cached_crash],
              work_dir: Dir.tmpdir,
              overlap_tol_mm: 0.01,
              timer_api: timer,
              exporter: proc { |subset, _path| launched_subsets << subset.map(&:id) },
              process_factory: proc { |_gml_path, _report_path| FakeProcess.new(0) }
            )

            coordinator.start { |value| result = value }
            timer.pulse

            assert_equal [['stair-probe']], launched_subsets
            assert_equal ['door-cache'], result.crash_cell_spaces.map(&:id)
            rows = result.progress[:categories]
            assert_equal :cached_passed, rows[0][:status]
            assert_equal :passed, rows[1][:status]
            assert_equal :cached_crashed, rows[3][:status]
            assert_equal 2, rows.sum { |row| row[:cached_checked_count] }
          end
        end
      end
    end
  end
end
