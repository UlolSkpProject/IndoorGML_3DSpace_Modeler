# frozen_string_literal: true

# Diagnostic loader for adjacency waypoint snapshot reuse A/B.
# Keeps the original 8-decimal regression gate and adds component-level,
# multi-precision comparisons to identify whether differences are numerical
# or structural.

base_script = File.join(__dir__, 'adjacency_waypoint_snapshot_reuse_ab_v2.rb')
load(base_script) unless defined?(
  ULOL::Indoor3DGmlModeler::IndoorCore::AdjacencyWaypointSnapshotReuseAB
)

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module AdjacencyWaypointSnapshotReuseAB
        DIAGNOSTIC_DIGITS = [8, 7, 6, 5, 4, 3].freeze unless const_defined?(:DIAGNOSTIC_DIGITS, false)

        class << self
          def build_report(service, result, elapsed, error)
            metrics = result.is_a?(Hash) ? result : (service.respond_to?(:last_metrics) ? service.last_metrics : {})
            model = IndoorModel.current
            transitions = Array(model.transitions).select { |transition| transition&.valid? }
            diagnostics = diagnostic_signatures(transitions)

            {
              mode: @active_mode,
              elapsed: elapsed.to_f,
              service_total: metrics[:total_duration].to_f,
              service_detailed: metrics[:adjacency_detailed_computation].to_f,
              pair_count: metrics[:pair_comparison_count].to_i,
              transition_count: transitions.length,
              transition_signatures: diagnostics.fetch(ROUND_DIGITS).fetch(:full),
              diagnostics: diagnostics,
              candidate_counts: transitions.map { |transition| Array(transition.waypoint_candidates).length }.sort,
              live_query_calls: stat_calls('live waypoint query'),
              live_query_total: stat_total('live waypoint query'),
              snapshot_analysis_calls: stat_calls('snapshot pair analysis'),
              snapshot_analysis_total: stat_total('snapshot pair analysis'),
              snapshot_context_hits: stat_calls('snapshot context hit'),
              snapshot_context_fallbacks: stat_calls('snapshot context fallback'),
              error: error && "#{error.class}: #{error.message}"
            }
          end

          def compare!
            baseline = @reports[:baseline]
            optimized = @reports[:optimized]
            same_transitions = baseline[:transition_count] == optimized[:transition_count]
            same_candidate_counts = baseline[:candidate_counts] == optimized[:candidate_counts]
            exact_geometry = diagnostic_equal?(baseline, optimized, ROUND_DIGITS, :full)
            elapsed_delta = optimized[:elapsed] - baseline[:elapsed]
            service_delta = optimized[:service_total] - baseline[:service_total]
            detailed_delta = optimized[:service_detailed] - baseline[:service_detailed]

            lines = []
            lines << '=' * 118
            lines << 'Adjacency Waypoint Snapshot Reuse A/B Diagnostic Comparison'
            lines << '=' * 118
            lines << "Transition count          : #{pf(same_transitions)}  #{baseline[:transition_count]} / #{optimized[:transition_count]}"
            lines << "Candidate count multiset  : #{pf(same_candidate_counts)}"
            lines << "Original 8-digit geometry : #{pf(exact_geometry)}"
            lines << "Baseline errors           : #{baseline[:error] ? 'FAIL' : 'PASS'}"
            lines << "Optimized errors          : #{optimized[:error] ? 'FAIL' : 'PASS'}"
            lines << '-' * 118
            lines << format('%-10s %-12s %-12s %-12s %-12s %-12s', 'Digits', 'Full', 'Endpoints', 'Selected', 'Cand.Points', 'Cand.Normals')
            DIAGNOSTIC_DIGITS.each do |digits|
              lines << format(
                '%-10d %-12s %-12s %-12s %-12s %-12s',
                digits,
                pf(diagnostic_equal?(baseline, optimized, digits, :full)),
                pf(diagnostic_equal?(baseline, optimized, digits, :endpoints)),
                pf(diagnostic_equal?(baseline, optimized, digits, :selected)),
                pf(diagnostic_equal?(baseline, optimized, digits, :candidate_points)),
                pf(diagnostic_equal?(baseline, optimized, digits, :candidate_normals))
              )
            end
            first_equal = DIAGNOSTIC_DIGITS.find do |digits|
              diagnostic_equal?(baseline, optimized, digits, :full)
            end
            lines << "First full-geometry equality: #{first_equal ? "#{first_equal} decimal digits" : 'none through 3 digits'}"
            lines << '-' * 118
            lines << metric_line('synchronize_all elapsed', baseline[:elapsed], optimized[:elapsed], elapsed_delta)
            lines << metric_line('Service reported total', baseline[:service_total], optimized[:service_total], service_delta)
            lines << metric_line('Detailed geometry', baseline[:service_detailed], optimized[:service_detailed], detailed_delta)
            lines << metric_line('Live waypoint query', baseline[:live_query_total], optimized[:live_query_total], optimized[:live_query_total] - baseline[:live_query_total])
            lines << metric_line('Snapshot pair analysis', baseline[:snapshot_analysis_total], optimized[:snapshot_analysis_total], optimized[:snapshot_analysis_total] - baseline[:snapshot_analysis_total])
            lines << '-' * 118
            verdict = if !same_transitions || !same_candidate_counts || !exact_geometry || baseline[:error] || optimized[:error]
                        'REJECT — DIAGNOSE DIFFERENCE'
                      elsif optimized[:elapsed] < baseline[:elapsed]
                        'PASS — OPTIMIZED FASTER'
                      else
                        'PASS FUNCTIONALLY — NO SPEEDUP'
                      end
            lines << "VERDICT                   : #{verdict}"
            lines << '=' * 118
            @comparison_lines = lines
            puts
            lines.each { |line| puts line }
            true
          end

          def diagnostic_signatures(transitions)
            DIAGNOSTIC_DIGITS.each_with_object({}) do |digits, result|
              full = []
              endpoints = []
              selected = []
              candidate_points = []
              candidate_normals = []

              transitions.each do |transition|
                endpoint_signature = [
                  point_signature_at(transition.state1_point, digits),
                  point_signature_at(transition.state2_point, digits)
                ].sort_by(&:inspect)
                candidate_signatures = Array(transition.waypoint_candidates).filter_map do |candidate|
                  next unless candidate.is_a?(Hash)

                  point = point_signature_at(candidate[:point], digits)
                  normal1 = vector_signature_at(candidate[:normal1], digits)
                  normal2 = vector_signature_at(candidate[:normal2], digits)
                  candidate_points << point
                  candidate_normals << [normal1, normal2]
                  [point, normal1, normal2]
                end.sort_by(&:inspect)
                selected_signature = point_signature_at(transition.selected_waypoint, digits)

                endpoints << endpoint_signature
                selected << selected_signature
                full << [endpoint_signature, candidate_signatures, selected_signature]
              end

              result[digits] = {
                full: full.sort_by(&:inspect),
                endpoints: endpoints.sort_by(&:inspect),
                selected: selected.sort_by(&:inspect),
                candidate_points: candidate_points.sort_by(&:inspect),
                candidate_normals: candidate_normals.sort_by(&:inspect)
              }
            end
          end

          def diagnostic_equal?(baseline, optimized, digits, key)
            baseline.dig(:diagnostics, digits, key) == optimized.dig(:diagnostics, digits, key)
          end

          def point_signature_at(point, digits)
            return nil unless point.is_a?(Geom::Point3d)

            [
              point.x.to_f.round(digits),
              point.y.to_f.round(digits),
              point.z.to_f.round(digits)
            ]
          end

          def vector_signature_at(vector, digits)
            return nil unless vector.is_a?(Geom::Vector3d)

            [
              vector.x.to_f.round(digits),
              vector.y.to_f.round(digits),
              vector.z.to_f.round(digits)
            ]
          end

          def pf(value)
            value ? 'PASS' : 'FAIL'
          end
        end
      end
    end
  end
end

ULOL::Indoor3DGmlModeler::IndoorCore::AdjacencyWaypointSnapshotReuseAB.reset!
puts '[ADJACENCY WAYPOINT SNAPSHOT A/B V3] component-level diagnostic comparison enabled'
puts 'A: ...::AdjacencyWaypointSnapshotReuseAB.baseline!'
puts 'B: reopen source SKP, then ...::AdjacencyWaypointSnapshotReuseAB.optimized!'
