# frozen_string_literal: true

# Compatibility loader for the renamed n-gon capable experiment.
# The implementation now treats every SketchUp Face as a candidate, not only
# triangles. Keep this file so older console commands continue to work.

load File.join(__dir__, 'lvn_coplanar_face_merge_experiment.rb')

Object.send(:remove_const, :LvnCoplanarTriangleMergeExperiment) if
  defined?(LvnCoplanarTriangleMergeExperiment)

LvnCoplanarTriangleMergeExperiment = LvnCoplanarFaceMergeExperiment

nil
