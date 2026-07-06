# frozen_string_literal: true

require 'minitest/autorun'
require 'thread'

require_relative '../indoor3d/validity/val3dity_output_parser'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityOutputParserTest < Minitest::Test
          FIXTURE_ROOT = File.expand_path('fixtures/val3dity', __dir__)

          def test_fixture_logs_finish_with_stable_payload_shape
            %w[success.log overlap.log failure.log current_model.log].each do |filename|
              events = parse_fixture(filename)

              assert_operator events.length, :>, 0, filename
              assert_equal 100, events.last[:percent], filename
              assert_equal 'Finished', events.last[:phase], filename
              assert_equal 'val3dity finished', events.last[:message], filename
              events.each { |event| assert_equal %i[current message percent phase], event.keys.sort, filename }
            end
          end

          def test_current_model_fixture_keeps_major_phase_events
            events = parse_fixture('current_model.log', total_states: 220, total_transitions: 227)
            phases = events.map { |event| event[:phase] }

            assert_includes phases, '2. Geometry Primal Cells'
            assert_includes phases, '3. XLinks Errors'
            assert_includes phases, '4. Overlap Primal Cells'
            assert_includes phases, '5. Dual Vertex Inside Cells'
            assert phases.any? { |phase| phase.start_with?('6. Adjacency in Primal / Dual') }
          end

          def test_split_chunks_are_buffered_before_parsing
            events = parse_chunks(['X', 'SD validation', "\nERROR 701: OVERLAP\n"])

            assert_equal 'Validating IndoorGML schema', events[0][:message]
            assert_equal 'ERROR 701: OVERLAP', events[1][:message]
            assert_equal 'Finished', events.last[:phase]
          end

          private

          def parse_fixture(filename, total_states: 0, total_transitions: 0)
            parse_chunks(
              [File.binread(File.join(FIXTURE_ROOT, filename))],
              total_states: total_states,
              total_transitions: total_transitions
            )
          end

          def parse_chunks(chunks, total_states: 0, total_transitions: 0)
            queue = Queue.new
            parser = Val3dityOutputParser.new(
              queue,
              total_states: total_states,
              total_transitions: total_transitions
            )
            chunks.each { |chunk| parser.feed(chunk) }
            parser.finish
            drain(queue)
          end

          def drain(queue)
            events = []
            loop { events << queue.pop(true) }
          rescue ThreadError
            events
          end
        end
      end
    end
  end
end
