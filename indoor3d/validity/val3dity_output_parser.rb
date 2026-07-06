# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter

        class Val3dityOutputParser
          PHASE_WEIGHTS = {
            xsd:          [0.00, 0.02],
            primitive:    [0.02, 0.07],
            xlinks:       [0.07, 0.10],
            overlap:      [0.10, 0.44],
            dual_vertex:  [0.44, 0.49],
            primal_dual:  [0.49, 1.00]
          }.freeze

          def initialize(queue, total_states:, total_transitions:)
            @queue = queue
            @total_states = total_states
            @total_transitions = total_transitions
            @buffer = +''
            @phase = :xsd
            @primitive_done = 0
            @dual_done = 0
            @link_done = 0
            @xlinks_emitted = false
            @last_ratio = 0.0
            @last_emit_at = Time.at(0)
          end

          def feed(chunk)
            text = decode_chunk(chunk)
            @buffer << text

            while (index = @buffer.index("\n"))
              line = @buffer.slice!(0..index).strip
              parse_line(line) unless line.empty?
            end
          end

          def finish
            parse_line(@buffer.strip) unless @buffer.strip.empty?
            @phase = :finished
            emit(force: true, ratio_override: 1.0, message: 'val3dity finished')
          end

          private

          def parse_line(line)
            case line
            when /XSD|schema/i
              @phase = :xsd
              emit(force: true, message: 'Validating IndoorGML schema')
            when /======== Validating Primitive ========/
              @phase = :primitive
              emit(force: true, message: 'Validating CellSpace solids')
            when /^id:\s+solid_(cell_[^\s]+)/
              emit(current: Regexp.last_match(1), message: "Geometry #{Regexp.last_match(1)}")
            when /^========= VALID =========/
              if @phase == :primitive
                @primitive_done += 1
                emit(message: "Geometry validated #{@primitive_done}")
              end
            when /XLink/i
              @phase = :xlinks
              @xlinks_emitted = true
              emit(force: true, message: 'Checking XLink references')
            when /^--- Overlapping tests between Cells ---/
              emit_xlinks_checkpoint
              @phase = :overlap
              emit(force: true, ratio_override: phase_start(:overlap), message: 'Checking CellSpace overlaps')
            when /^--- Constructing Nef Polyhedra ---/
              emit(force: true, ratio_override: phase_ratio(:overlap, 0.30), message: 'Constructing Nef polyhedra')
            when /^--- Constructing AABB tree ---/
              emit(force: true, ratio_override: phase_ratio(:overlap, 0.60), message: 'Constructing AABB tree')
            when /^--- Testing intersections between Nefs ---/
              emit(force: true, ratio_override: phase_ratio(:overlap, 0.90), message: 'Testing cell intersections')
            when /^======== Validating Dual Vertex/
              @phase = :dual_vertex
              emit(force: true, ratio_override: phase_start(:dual_vertex), message: 'Checking State points inside CellSpaces')
            when /^Cell \(.*\) id=(cell_[^\s]+)\s+--> ok/
              @dual_done += 1
              emit(current: Regexp.last_match(1), message: "Dual vertex #{@dual_done}")
            when /^======== Validating Primal-Dual links/
              @phase = :primal_dual
              emit(force: true, ratio_override: phase_start(:primal_dual), message: 'Checking primal/dual adjacencies')
            when /^Cells id=(cell_[^\s]+) id=(cell_[^\s]+)/
              @link_done += 1
              emit(
                current: "#{Regexp.last_match(1)} -> #{Regexp.last_match(2)}",
                message: "Primal-dual link #{@link_done}"
              )
            when /ERROR\s+(\d+):\s+([A-Z0-9_]+)/
              emit(
                force: true,
                message: "ERROR #{Regexp.last_match(1)}: #{Regexp.last_match(2)}"
              )
            end
          end

          def emit(force: false, ratio_override: nil, current: nil, message: nil)
            return unless force || Time.now - @last_emit_at >= 0.10

            ratio = ratio_override || current_ratio
            ratio = bounded_ratio(ratio, @last_ratio, 1.0)
            @last_ratio = ratio
            @last_emit_at = Time.now

            @queue << {
              percent: (ratio * 100.0).round,
              phase: phase_label,
              message: message,
              current: current
            }
          end

          def current_ratio
            case @phase
            when :xsd
              phase_ratio(:xsd, 0.50)
            when :primitive
              start, finish = PHASE_WEIGHTS[:primitive]
              bounded_ratio(start + @primitive_done * 0.01, start, finish)
            when :xlinks
              phase_ratio(:xlinks, 0.50)
            when :overlap
              phase_ratio(:overlap, 0.50)
            when :dual_vertex
              start, finish = PHASE_WEIGHTS[:dual_vertex]
              if @total_states > 0
                bounded_ratio(start + (@dual_done.to_f / @total_states) * (finish - start), start, finish)
              else
                bounded_ratio(start + @dual_done * 0.001, start, finish)
              end
            when :primal_dual
              start, finish = PHASE_WEIGHTS[:primal_dual]
              if @total_transitions > 0
                bounded_ratio(start + (@link_done.to_f / @total_transitions) * (finish - start), start, finish)
              else
                bounded_ratio(start + @link_done * 0.002, start, finish)
              end
            else
              0.0
            end
          end

          def bounded_ratio(value, min, max)
            [[value, min].max, max].min
          end

          def phase_start(phase)
            PHASE_WEIGHTS.fetch(phase).first
          end

          def phase_ratio(phase, local_ratio)
            start, finish = PHASE_WEIGHTS.fetch(phase)
            bounded_ratio(start + (finish - start) * local_ratio, start, finish)
          end

          def phase_label
            case @phase
            when :xsd then '1. XSD Validation'
            when :primitive then '2. Geometry Primal Cells'
            when :xlinks then '3. XLinks Errors'
            when :overlap then '4. Overlap Primal Cells'
            when :dual_vertex then '5. Dual Vertex Inside Cells'
            when :primal_dual then "6. Adjacency in Primal / Dual (#{@link_done} / #{@total_transitions})"
            when :finished then 'Finished'
            else 'Starting val3dity'
            end
          end

          def emit_xlinks_checkpoint
            return if @xlinks_emitted

            @phase = :xlinks
            @xlinks_emitted = true
            emit(force: true, ratio_override: phase_ratio(:xlinks, 0.95), message: 'Checking XLink references')
          end

          def decode_chunk(chunk)
            text = chunk.dup.force_encoding('UTF-8')
            return text if text.valid_encoding?

            chunk.force_encoding('CP949').encode('UTF-8', invalid: :replace, undef: :replace)
          rescue EncodingError
            chunk.force_encoding('UTF-8').encode('UTF-8', invalid: :replace, undef: :replace)
          end
        end

      end
    end
  end
end
