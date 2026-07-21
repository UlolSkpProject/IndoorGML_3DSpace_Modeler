# frozen_string_literal: true

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class LocalVertexNormalizer
        private

        def augment_v2_normalization_report!(
          report,
          axis_plane_plan:,
          vertex_metrics:,
          target_collision_cleanup:,
          post_retriangulation_cleanup:,
          rebuilt_pre_repair_validation:,
          forced_retriangulation:,
          final_surface_equivalence:,
          final_repair:
        )
          report[:normalization_strategy] = :validated_triangle_rebuild_v2
          report[:axis_constraint_priority] = axis_plane_plan[:axis_priority]
          report[:constrained_coordinate_count] =
            axis_plane_plan[:constrained_coordinate_count]
          report[:multi_axis_constrained_vertex_count] =
            axis_plane_plan[:multi_axis_constrained_vertex_count]
          report[:resolved_axis_constraint_conflict_count] =
            axis_plane_plan[:resolved_constraint_conflict_count]
          report[:discarded_axis_constraint_count] =
            axis_plane_plan[:discarded_constraint_count]
          report[:target_collision_count] = vertex_metrics[:target_collision_count]
          report[:merged_target_vertex_count] = vertex_metrics[:merged_target_vertex_count]
          report[:target_collision_samples] = vertex_metrics[:target_collisions]
          report[:target_collision_cleanup] = target_collision_cleanup
          report[:forced_retriangulation] = forced_retriangulation
          report[:forced_retriangulation_source_face_count] =
            forced_retriangulation[:source_face_keys].length
          report[:post_retriangulation_cleanup] = post_retriangulation_cleanup
          report[:rebuilt_pre_repair_validation] = rebuilt_pre_repair_validation
          report[:final_surface_equivalence] = final_surface_equivalence
          report[:final_entity_repair] = final_repair
          report[:surface_border_repair_count] =
            final_repair.dig(:surface_border, :repairs).to_i
          report[:external_face_removal_count] =
            final_repair.dig(:external_faces, :removed_faces).to_i
          report[:stray_edge_removal_count] =
            final_repair.dig(:stray_edges, :removed_edges).to_i
          report[:reverse_face_repair_count] =
            final_repair.dig(:reverse_faces, :reversed_faces).to_i
          report[:manifold] = final_repair[:manifold] &&
            final_surface_equivalence[:equivalent]
          report
        end
      end
    end
  end
end
