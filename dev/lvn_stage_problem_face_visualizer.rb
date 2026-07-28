# frozen_string_literal: true

# Highlights one triangle from the persistent LVN stage-copy visualization.
#
# Default target is the current o6rz6ds0 materialization failure T420.
# The stage mesh itself is re-captured from the source entity, so this script can
# restore the exact triangle outline even when SketchUp refused to create its Face
# or removed the empty per-triangle child group at operation commit.
#
# Ruby Console:
# load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_stage_problem_face_visualizer.rb'
# LvnStageProblemFaceVisualizer.run
#
# Custom triangle:
# LvnStageProblemFaceVisualizer.run(source_pid: 1_107_846, triangle_index: 420)
#
# Remove markers/text created by this script:
# LvnStageProblemFaceVisualizer.cleanup

require_relative 'lvn_failed_targets_stage_copies'

module LvnStageProblemFaceVisualizer
  StageCopies = LvnFailedTargetsStageCopies
  LVN = StageCopies::LVN

  DEFAULT_SOURCE_PID = 1_107_846
  DEFAULT_TRIANGLE_INDEX = 420
  DEFAULT_STAGES = %i[grid_normalized grid_conforming].freeze

  VIS_DICTIONARY = 'ULOL_LVN_PROBLEM_VIS'
  MATERIAL_NAME = 'LVN_PROBLEM_TRIANGLE'

  TEXT_HEIGHT_MM = 120.0
  TEXT_OFFSET_MM = 60.0
  MARKER_RADIUS_MM = 140.0
  MARKER_OFFSET_MM = 20.0

  module_function

  def run(
    source_pid: DEFAULT_SOURCE_PID,
    triangle_index: DEFAULT_TRIANGLE_INDEX,
    stages: DEFAULT_STAGES
  )
    model = Sketchup.active_model
    source_entity, = StageCopies.find_entity_and_transform(model, source_pid)
    raise "Source target not found: PID=#{source_pid}" unless source_entity&.valid?

    normalizer = StageCopies::StageCaptureNormalizer.new(
      LVN::DEFAULT_TOLERANCE_MM,
      model: model
    )
    capture = normalizer.capture(source_entity)

    started = model.start_operation('Visualize LVN problem triangle', true)
    raise 'SketchUp refused to start problem-visualization operation' unless started

    begin
      material = problem_material(model)

      Array(stages).each do |stage|
        stage = stage.to_sym
        records = capture.fetch(stage)
        record = records.fetch(Integer(triangle_index))
        stage_group = find_stage_group(model, source_pid, stage)
        raise "Stage copy not found: PID=#{source_pid} stage=#{stage}" unless stage_group

        remove_stage_markers(stage_group, triangle_index)
        triangle_group = find_triangle_group(stage_group, triangle_index)
        triangle_group ||= create_triangle_group(stage_group, record, triangle_index)

        points = record[:points].map { |point| Geom::Point3d.new(point.x, point.y, point.z) }
        ensure_triangle_outline(triangle_group, points)
        apply_problem_material(triangle_group, material)
        create_marker(stage_group, record, triangle_index, stage, points, material)
      end

      model.commit_operation
      started = false
      model.active_view.invalidate
      nil
    rescue StandardError
      model.abort_operation if started
      raise
    end
  end

  def cleanup(source_pid: nil, triangle_index: nil)
    model = Sketchup.active_model
    started = model.start_operation('Remove LVN problem visualization', true)
    raise 'SketchUp refused to start visualization cleanup operation' unless started

    begin
      stage_groups(model).each do |stage_group|
        next if source_pid && stage_group.get_attribute(
          StageCopies::DIAGNOSTIC_DICTIONARY,
          'source_pid'
        ).to_i != source_pid.to_i

        marker_groups = stage_group.entities.grep(Sketchup::Group).select do |group|
          next false unless group.get_attribute(VIS_DICTIONARY, 'generated', false) == true
          next true unless triangle_index

          group.get_attribute(VIS_DICTIONARY, 'triangle_index').to_i == triangle_index.to_i
        end
        stage_group.entities.erase_entities(marker_groups) unless marker_groups.empty?
      end

      model.commit_operation
      started = false
      model.active_view.invalidate
      nil
    rescue StandardError
      model.abort_operation if started
      raise
    end
  end

  def find_stage_group(model, source_pid, stage)
    stage_groups(model).find do |group|
      group.get_attribute(StageCopies::DIAGNOSTIC_DICTIONARY, 'source_pid').to_i == source_pid.to_i &&
        group.get_attribute(StageCopies::DIAGNOSTIC_DICTIONARY, 'stage').to_s == stage.to_s
    end
  end

  def stage_groups(model)
    model.entities.grep(Sketchup::Group).select do |group|
      group.valid? && group.get_attribute(
        StageCopies::DIAGNOSTIC_DICTIONARY,
        'generated',
        false
      ) == true
    end
  end

  def find_triangle_group(stage_group, triangle_index)
    stage_group.entities.grep(Sketchup::Group).find do |group|
      value = group.get_attribute(
        StageCopies::TRIANGLE_DICTIONARY,
        'triangle_index'
      )
      !value.nil? && value.to_i == triangle_index.to_i
    end
  end

  # A failed add_face can leave an empty triangle child group. SketchUp may remove
  # that empty group when the stage-copy operation commits. Recreate it here from
  # the authoritative in-memory stage record instead of depending on visualization
  # leftovers.
  def create_triangle_group(stage_group, record, triangle_index)
    group = stage_group.entities.add_group
    group.name = "T#{triangle_index} sf=#{record[:source_face_key]} p=#{record[:source_polygon_index]} [VIS]"
    group.set_attribute(
      StageCopies::TRIANGLE_DICTIONARY,
      'triangle_index',
      triangle_index
    )
    group.set_attribute(
      StageCopies::TRIANGLE_DICTIONARY,
      'source_face_key',
      record[:source_face_key]
    )
    group.set_attribute(
      StageCopies::TRIANGLE_DICTIONARY,
      'source_polygon_index',
      record[:source_polygon_index]
    )
    group.set_attribute(VIS_DICTIONARY, 'recreated_triangle_group', true)
    group
  end

  def ensure_triangle_outline(triangle_group, points)
    return unless triangle_group.entities.grep(Sketchup::Edge).empty?

    triangle_group.entities.add_line(points[0], points[1])
    triangle_group.entities.add_line(points[1], points[2])
    triangle_group.entities.add_line(points[2], points[0])
  end

  def apply_problem_material(triangle_group, material)
    triangle_group.material = material if triangle_group.respond_to?(:material=)

    triangle_group.entities.grep(Sketchup::Face).each do |face|
      face.material = material
      face.back_material = material if face.respond_to?(:back_material=)
    end

    triangle_group.entities.grep(Sketchup::Edge).each do |edge|
      edge.material = material if edge.respond_to?(:material=)
      edge.hidden = false if edge.respond_to?(:hidden=)
      edge.soft = false if edge.respond_to?(:soft=)
      edge.smooth = false if edge.respond_to?(:smooth=)
    end
  end

  def create_marker(stage_group, record, triangle_index, stage, points, material)
    frame = triangle_frame(points)
    marker = stage_group.entities.add_group
    marker.name = "LVN PROBLEM T#{triangle_index} #{stage}"
    marker.set_attribute(VIS_DICTIONARY, 'generated', true)
    marker.set_attribute(VIS_DICTIONARY, 'triangle_index', triangle_index)
    marker.set_attribute(VIS_DICTIONARY, 'stage', stage.to_s)

    add_marker_disc(marker.entities, material)
    add_marker_text(marker.entities, record, triangle_index, stage, material)
    marker.transformation = frame
  end

  def triangle_frame(points)
    centroid = Geom::Point3d.new(
      points.sum(&:x) / 3.0,
      points.sum(&:y) / 3.0,
      points.sum(&:z) / 3.0
    )

    x_axis = points[0].vector_to(points[1])
    normal = x_axis.cross(points[0].vector_to(points[2]))
    raise 'Problem triangle has zero normal' if normal.length.zero?

    x_axis.normalize!
    normal.normalize!
    y_axis = normal.cross(x_axis)
    y_axis.normalize!

    origin = centroid.offset(normal, MARKER_OFFSET_MM.mm)
    Geom::Transformation.axes(origin, x_axis, y_axis, normal)
  end

  def add_marker_disc(entities, material)
    edges = entities.add_circle(
      Geom::Point3d.new(0, 0, 0),
      Z_AXIS,
      MARKER_RADIUS_MM.mm,
      24
    )
    face = entities.add_face(edges)
    return unless face&.valid?

    face.material = material
    face.back_material = material if face.respond_to?(:back_material=)
  rescue StandardError
    nil
  end

  def add_marker_text(entities, record, triangle_index, stage, material)
    text_group = entities.add_group
    text_group.name = "T#{triangle_index} label"

    source_face_key = record[:source_face_key]
    polygon_index = record[:source_polygon_index]
    label = "T#{triangle_index} #{stage}\nsf=#{source_face_key} p=#{polygon_index}"

    text_group.entities.add_3d_text(
      label,
      TextAlignCenter,
      'Arial',
      true,
      false,
      TEXT_HEIGHT_MM.mm,
      0.0,
      0.0,
      true,
      0.0
    )
    text_group.entities.grep(Sketchup::Face).each do |face|
      face.material = material
      face.back_material = material if face.respond_to?(:back_material=)
    end
    text_group.transformation = Geom::Transformation.translation(
      [0, 0, TEXT_OFFSET_MM.mm]
    )
  rescue StandardError
    text_group.erase! if text_group&.valid?
    nil
  end

  def remove_stage_markers(stage_group, triangle_index)
    markers = stage_group.entities.grep(Sketchup::Group).select do |group|
      group.get_attribute(VIS_DICTIONARY, 'generated', false) == true &&
        group.get_attribute(VIS_DICTIONARY, 'triangle_index').to_i == triangle_index.to_i
    end
    stage_group.entities.erase_entities(markers) unless markers.empty?
  end

  def problem_material(model)
    material = model.materials[MATERIAL_NAME] || model.materials.add(MATERIAL_NAME)
    material.color = Sketchup::Color.new(255, 40, 40)
    material.alpha = 0.55 if material.respond_to?(:alpha=)
    material
  end
end

nil
