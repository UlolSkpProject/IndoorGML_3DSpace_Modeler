# frozen_string_literal: true

require 'json'
require_relative 'val3dity_simple_solid_microbenchmark'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        # Dev-only coarse crossover search for simple convex CellSpaces.
        #
        # Positive-overlap cases are intentionally excluded: the canonical path
        # must perform Full-Solid confirmation after a positive proxy result, so
        # they do not have a meaningful "canonical becomes cheaper" crossover.
        module Val3ditySimpleSolidThresholdBenchmark
          BASE = Val3ditySimpleSolidMicrobenchmark
          TEST_SIDE_COUNTS = [
            4, 8, 12, 20, 28, 40, 56, 80, 112, 160, 224, 320
          ].freeze
          TEST_RELATIONS = {
            'gap_1mm' => [:gap, 1.0],
            'face_touching' => [:gap, 0.0]
          }.freeze
          FASTER_RATIO = 1.05

          class << self
            attr_reader :last_result, :last_result_path

            def run!(iterations: 7, warmup: 2, keep_geometry: false)
              original_side_counts = BASE.const_get(:SIDE_COUNTS)
              original_relations = BASE.const_get(:RELATIONS)
              replace_constant(BASE, :SIDE_COUNTS, TEST_SIDE_COUNTS)
              replace_constant(BASE, :RELATIONS, TEST_RELATIONS)

              result = BASE.run!(
                iterations: iterations,
                warmup: warmup,
                keep_geometry: keep_geometry
              )
              result['mode'] =
                'synthetic_simple_cellspace_full_vs_canonical_threshold_search'
              result['threshold_search'] = threshold_summary(result)
              result['tested_face_counts'] = TEST_SIDE_COUNTS.map { |sides| sides + 2 }
              result['threshold_faster_ratio'] = FASTER_RATIO

              @last_result = result
              @last_result_path = BASE.last_result_path
              File.write(
                @last_result_path,
                JSON.pretty_generate(result),
                encoding: 'UTF-8'
              )
              print_report(result)
              result
            ensure
              replace_constant(BASE, :SIDE_COUNTS, original_side_counts) if
                defined?(original_side_counts) && original_side_counts
              replace_constant(BASE, :RELATIONS, original_relations) if
                defined?(original_relations) && original_relations
            end

            def print_report(result = @last_result)
              raise 'No threshold benchmark result is available.' unless result

              puts
              puts('=' * 116)
              puts('SIMPLE CELLSPACE RECHECK — COARSE CROSSOVER SEARCH')
              puts('=' * 116)
              puts "tested_face_counts : #{result['tested_face_counts'].inspect}"
              puts "iterations         : #{result['iterations']}"
              puts "warmup              : #{result['warmup']}"
              puts "equivalent          : #{result['result_equivalence']}"
              puts "result_path         : #{@last_result_path}"
              puts('-' * 116)
              puts format(
                '%-15s %6s %12s %12s %10s %10s',
                'relation', 'faces', 'full warm', 'canon warm', 'speedup', 'verdict'
              )
              TEST_RELATIONS.each_key do |relation|
                result.fetch('cases')
                      .select { |row| row['relation'] == relation }
                      .sort_by { |row| row['face_count'].to_i }
                      .each do |row|
                  warm = row.fetch('warm')
                  puts format(
                    '%-15s %6d %11.3fms %11.3fms %9.3fx %10s',
                    relation,
                    row['face_count'],
                    warm['full_median_ms'],
                    warm['canonical_median_ms'],
                    warm['speedup_vs_full'],
                    warm['verdict']
                  )
                end
                summary = result.dig('threshold_search', relation, 'warm')
                puts "  warm crossover: #{summary.inspect}"
                puts
              end
              puts "PASS               : #{result['pass']}"
              puts('=' * 116)
              result
            end

            private

            def replace_constant(owner, name, value)
              owner.send(:remove_const, name) if owner.const_defined?(name, false)
              owner.const_set(name, value)
            end

            def threshold_summary(result)
              TEST_RELATIONS.keys.to_h do |relation|
                rows = result.fetch('cases')
                             .select { |row| row['relation'] == relation }
                             .sort_by { |row| row['face_count'].to_i }
                [
                  relation,
                  {
                    'cold' => phase_threshold(rows, 'cold'),
                    'warm' => phase_threshold(rows, 'warm')
                  }
                ]
              end
            end

            def phase_threshold(rows, phase)
              ratios = rows.map do |row|
                [row['face_count'].to_i, row.dig(phase, 'speedup_vs_full').to_f]
              end
              first_single = ratios.find { |_faces, ratio| ratio >= FASTER_RATIO }
              stable_index = ratios.each_index.find do |index|
                next false if index + 1 >= ratios.length

                ratios[index][1] >= FASTER_RATIO &&
                  ratios[index + 1][1] >= FASTER_RATIO
              end
              first_stable = stable_index && ratios[stable_index]
              selected = first_stable || first_single

              unless selected
                return {
                  'status' => 'not_reached',
                  'tested_max_face_count' => ratios.last&.first,
                  'tested_max_speedup' => ratios.last&.last&.round(4)
                }
              end

              selected_index = ratios.index(selected)
              previous = selected_index&.positive? ? ratios[selected_index - 1] : nil
              {
                'status' => first_stable ? 'stable_crossover_observed' : 'single_crossover_observed',
                'previous_tested_face_count' => previous&.first,
                'previous_speedup' => previous&.last&.round(4),
                'first_faster_face_count' => selected.first,
                'first_faster_speedup' => selected.last.round(4),
                'coarse_boundary' => previous ?
                  "#{previous.first + 1}..#{selected.first} faces" :
                  "<= #{selected.first} faces"
              }
            end
          end
        end
      end
    end
  end
end
