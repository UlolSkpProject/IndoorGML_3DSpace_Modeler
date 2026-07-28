# frozen_string_literal: true

# Materializes two persistent diagnostic copies for each currently failing LVN target:
#   1) GRID_NORMALIZED  - after independent grid snap + collapsed/duplicate cleanup,
#                         immediately before grid conforming.
#   2) GRID_CONFORMING  - after grid conforming + cleanup, immediately before the
#                         short-edge sliver stage / hard gate.
#
# IMPORTANT:
# The stage mesh can contain exact-invalid overlapping triangles. SketchUp merges
# points inside one Entities drawing context, so fill_from_mesh/add_face on one
# shared context can omit or rewrite such triangles. For faithful inspection,
# every triangle is therefore materialized in its own child group (triangle soup).
# The parent stage group is committed and remains in the model.
#
# SketchUp Ruby Console:
# load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_failed_targets_stage_copies.rb'
# LvnFailedTargetsStageCopies.run
#
# Remove only copies created by this script:
# LvnFailedTargetsStageCopies.cleanup

require 'time'

root = File.expand_path('..', __dir__)
require File.join(root, 'indoor3d', 'application', 'local_vertex_normalizer') unless
  defined?(ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer)

module LvnFailedTargetsStageCopies
  LVN = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer

  TARGETS = [
    {
      pid: 1_189_788,
      label: 'ijn58ryq',
      expected_name: '[TransitionSpace:Stair]-ijn58ryq'
    },
    {
      pid: 1_106_041,
      label: 's8vadud8',
      expected_name: '[GeneralSpace:Room]-s8vadud8'
    },
    {
      pid: 1_107_846,
      label: 'o6rz6ds0',
      expected_name: '[GeneralSpace:Room]-o6rz6ds0'
    }
  ].freeze

  DIAGNOSTIC_DICTIONARY = 'ULOL_LVN_STAGE_COPY'
  TRIANGLE_DICTIONARY = 'ULOL_LVN_STAGE_TRIANGLE'
  TAG_GRID_NORMALIZED = 'LVN_VIS_GRID_NORMALIZED'
  TAG_GRID_CONFORMING = 'LVN_VIS_GRID_CONFORMING'
  CLEARANCE_MM = 2_000.0

  class StageCaptureNormalizer < LVN
    def capture(entity)
      validate_entity!(entity)
      entities = entity.definition.entities

      source_conforming_duplicates = {}
      source_records = triangle_snapshot(entities)
      source_records = conforming_triangle_snapshot(
        source_records,
        coordinate_space: :source,
        duplicate_diagnostics: source_conforming_duplicates
      )
      source_records, = collapse_source_altitude_sliver_triangles(source_records)
      source_records = conforming_triangle_snapshot(
        source_records,
        coordinate_space: :source,
        duplicate_diagnostics: source_conforming_duplicates
      )
      source_records, = discard_collapsed_triangle_records(
        source_records,
        coordinate_space: :source
      )

      grid_duplicates = {}
      grid_records, = normalize_triangle_records_allowing_collisions(
        source_records,
        nil,
        duplicate_diagnostics: grid_duplicates
      )
      grid_records, grid_cleanup = discard_collapsed_triangle_records(grid_records)
      validate_normalized_triangle_shapes!(grid_records)

      conforming_duplicates = {}
      conforming_records = conforming_triangle_snapshot(
        grid_records,
        duplicate_diagnostics: conforming_duplicates
      )
      conforming_records, conforming_cleanup =
        discard_collapsed_triangle_records(conforming_records)
      validate_normalized_triangle_shapes!(conforming_records)

      {
        grid_normalized: clone_records(grid_records),
        grid_conforming: clone_records(conforming_records),
        diagnostics: {
          grid_cleanup: grid_cleanup,
          conforming_cleanup: conforming_cleanup,
          source_conforming_duplicates: source_conforming_duplicates,
          grid_duplicates: grid_duplicates,
          conforming_duplicates: conforming_duplicates
        }
      }
    end

    # Materialize each triangle in its own SketchUp drawing context. This is
    # intentionally NOT production rebuild logic. It is a diagnostic visualization
    # that must preserve overlapping triangles instead of letting SketchUp merge them.
    def materialize_triangle_soup(parent_group, records)
      added_faces = 0
      outline_only = 0
      failures = []

      records.each_with_index do |record, triangle_index|
        triangle_group = nil
        points = nil

        begin
          triangle_group = parent_group.entities.add_group
          triangle_group.name = triangle_name(record, triangle_index)
          triangle_group.set_attribute(TRIANGLE_DICTIONARY, 'triangle_index', triangle_index)
          triangle_group.set_attribute(
            TRIANGLE_DICTIONARY,
            'source_face_key',
            record[:source_face_key]
          )
          triangle_group.set_attribute(
            TRIANGLE_DICTIONARY,
            'source_polygon_index',
            record[:source_polygon_index]
          )

          points = record[:points].map do |point|
            @point_factory.call(point.x, point.y, point.z)
          end

          face = triangle_group.entities.add_face(points)
          if face&.valid?
            apply_visual_metadata(face, record)
            added_faces += 1
          else
            add_triangle_outline(triangle_group.entities, points)
            outline_only += 1
            failures << {
              triangle_index: triangle_index,
              reason: 'add_face returned nil/invalid',
              points: points.map { |point| grid_indices(point) }
            }
          end
        rescue StandardError => error
          # Keep the child group non-empty even when SketchUp refuses the Face.
          # Otherwise SketchUp may remove the empty group at operation commit,
          # which makes the exact failing triangle impossible to inspect later.
          begin
            add_triangle_outline(triangle_group.entities, points) if
              triangle_group&.valid? && points&.length == 3 &&
              triangle_group.entities.grep(Sketchup::Edge).empty?
          rescue StandardError
            nil
          end

          outline_only += 1
          failures << {
            triangle_index: triangle_index,
            reason: "#{error.class}: #{error.message}",
            points: Array(record[:points]).map { |point| grid_indices(point) rescue nil }
          }
        ensure
          next unless triangle_group&.valid?

          triangle_group.entities.grep(Sketchup::Edge).each do |edge|
            edge.hidden = false if edge.respond_to?(:hidden=)
            edge.soft = false if edge.respond_to?(:soft=)
            edge.smooth = false if edge.respond_to?(:smooth=)
          end
        end
      end

      {
        triangle_group_count: parent_group.entities.grep(Sketchup::Group).length,
        added_faces: added_faces,
        outline_only: outline_only,
        failures: failures
      }
    end

    # Analyze the exact in-memory triangle complex, not the nested visualization.
    def analyze_records(records)
      triangles = records.map do |record|
        record[:points].map { |point| grid_indices(point) }
      end

      edge_incidence = Hash.new { |hash, key| hash[key] = [] }
      vertices = {}
      triangles.each_with_index do |triangle, triangle_index|
        triangle.each { |point| vertices[point] = true }
        3.times do |edge_index|
          edge = canonical_edge_key(
            triangle[edge_index],
            triangle[(edge_index + 1) % 3]
          )
          edge_incidence[edge] << triangle_index
        end
      end

      bad_edges = edge_incidence.select { |_edge, owners| owners.length != 2 }
      intersections = collect_triangle_intersection_failures(triangles)

      {
        triangle_count: triangles.length,
        vertex_count: vertices.length,
        edge_count: edge_incidence.length,
        bad_edge_count: bad_edges.length,
        boundary_edge_count: bad_edges.count { |_edge, owners| owners.length == 1 },
        overused_edge_count: bad_edges.count { |_edge, owners| owners.length > 2 },
        bad_edge_samples: bad_edges.first(10).map do |edge, owners|
          { edge: edge, incidence: owners.length, triangles: owners }
        end,
        invalid_pair_count: intersections[:pairs].length,
        invalid_pairs: intersections[:pairs],
        tested_pairs: intersections[:tested_pairs]
      }
    end

    private

    def clone_records(records)
      records.map do |record|
        cloned = record.dup
        cloned[:points] = record[:points].map do |point|
          @point_factory.call(point.x, point.y, point.z)
        end
        cloned
      end
    end

    def triangle_name(record, triangle_index)
      "T#{triangle_index} sf=#{record[:source_face_key]} p=#{record[:source_polygon_index]}"
    end

    def apply_visual_metadata(face, record)
      face.material = record[:material] if valid_metadata_entity?(record[:material])
      if face.respond_to?(:back_material=) && valid_metadata_entity?(record[:back_material])
        face.back_material = record[:back_material]
      end
    rescue StandardError
      # Visualization must survive stale/non-paintable metadata.
      nil
    end

    def valid_metadata_entity?(value)
      return false if value.nil?
      return value.valid? if value.respond_to?(:valid?)

      true
    rescue StandardError
      false
    end

    def add_triangle_outline(entities, points)
      entities.add_line(points[0], points[1])
      entities.add_line(points[1], points[2])
      entities.add_line(points[2], points[0])
    end
  end

  module_function

  def run(replace_existing: true, clearance_mm: CLEARANCE_MM)
    model = Sketchup.active_model
    normalizer = StageCaptureNormalizer.new(LVN::DEFAULT_TOLERANCE_MM, model: model)

    resolved = TARGETS.map do |target|
      entity, world_transform = find_entity_and_transform(model, target[:pid])
      unless entity&.respond_to?(:valid?) && entity.valid?
        raise "Target not found: #{target[:label]} PID=#{target[:pid]}"
      end
      [target, entity, world_transform]
    end

    captures = resolved.map do |target, entity, world_transform|
      [target, entity, world_transform, normalizer.capture(entity)]
    end

    started = model.start_operation('Create LVN stage copies', true)
    raise 'SketchUp refused to start stage-copy operation' unless started

    begin
      erase_generated_copies(model) if replace_existing

      grid_tag = model.layers.add(TAG_GRID_NORMALIZED)
      conforming_tag = model.layers.add(TAG_GRID_CONFORMING)
      created = []

      captures.each do |target, entity, world_transform, capture|
        spacing = copy_spacing_inches(entity, clearance_mm)

        grid_copy = create_stage_copy(
          model,
          normalizer,
          entity,
          world_transform,
          target,
          :grid_normalized,
          capture[:grid_normalized],
          grid_tag,
          spacing
        )
        conforming_copy = create_stage_copy(
          model,
          normalizer,
          entity,
          world_transform,
          target,
          :grid_conforming,
          capture[:grid_conforming],
          conforming_tag,
          spacing * 2.0
        )

        created << grid_copy << conforming_copy
      end

      model.commit_operation
      started = false

      model.selection.clear
      created.each { |entry| model.selection.add(entry[:group]) if entry[:group]&.valid? }
      model.active_view.invalidate

      $lvn_failed_targets_stage_copies = {
        generated_at: Time.now.iso8601(3),
        representation: 'one child group per triangle; preserves overlapping triangle soup',
        copies: created.map { |entry| entry.reject { |key, _value| key == :group } }
      }
      nil
    rescue StandardError
      model.abort_operation if started
      raise
    end
  end

  def cleanup
    model = Sketchup.active_model
    started = model.start_operation('Remove LVN stage copies', true)
    raise 'SketchUp refused to start cleanup operation' unless started

    begin
      erase_generated_copies(model)
      model.commit_operation
      started = false
      model.active_view.invalidate
      nil
    rescue StandardError
      model.abort_operation if started
      raise
    end
  end

  def create_stage_copy(
    model,
    normalizer,
    source_entity,
    world_transform,
    target,
    stage,
    records,
    tag,
    offset_x_inches
  )
    group = model.entities.add_group
    group.name = "#{target[:expected_name]} [LVN #{stage.to_s.upcase}]"
    group.layer = tag

    exact = normalizer.analyze_records(records)
    build = normalizer.materialize_triangle_soup(group, records)

    placement = Geom::Transformation.translation([offset_x_inches, 0, 0]) * world_transform
    group.transformation = placement

    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'generated', true)
    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'source_pid', target[:pid])
    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'source_name', source_entity.name.to_s)
    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'stage', stage.to_s)
    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'expected_triangle_count', records.length)
    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'triangle_group_count', build[:triangle_group_count])
    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'invalid_pair_count', exact[:invalid_pair_count])
    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'overused_edge_count', exact[:overused_edge_count])

    unless build[:failures].empty?
      warn "[LVN STAGE COPIES] WARNING #{target[:label]} #{stage}: " \
           "triangle materialization failures=#{build[:failures].length} " \
           "samples=#{build[:failures].first(3).inspect}"
    end

    {
      group: group,
      pid: group.persistent_id,
      source_pid: target[:pid],
      label: target[:label],
      stage: stage,
      name: group.name,
      expected_triangle_count: records.length,
      triangle_group_count: build[:triangle_group_count],
      added_face_count: build[:added_faces],
      outline_only_count: build[:outline_only],
      materialization_failure_count: build[:failures].length,
      exact_mesh: exact,
      offset_x_mm: offset_x_inches * LVN::MM_PER_INCH,
      tag: tag.name
    }
  end

  def copy_spacing_inches(entity, clearance_mm)
    bounds = entity.bounds
    span_inches = [bounds.width, bounds.height, bounds.depth].map(&:to_f).max
    clearance_inches = Float(clearance_mm) / LVN::MM_PER_INCH
    [span_inches, 1.0].max + clearance_inches
  end

  def erase_generated_copies(model)
    copies = model.entities.grep(Sketchup::Group).select do |group|
      group.get_attribute(DIAGNOSTIC_DICTIONARY, 'generated', false) == true
    end
    model.entities.erase_entities(copies) unless copies.empty?
    copies.length
  end

  def find_entity_and_transform(model, pid)
    if model.respond_to?(:find_entity_by_persistent_id)
      found = model.find_entity_by_persistent_id(pid)
      if found.respond_to?(:leaf)
        entity = found.leaf
        transform = found.respond_to?(:transformation) ? found.transformation : entity.transformation
        return [entity, transform] if entity&.respond_to?(:valid?) && entity.valid?
      elsif found.respond_to?(:valid?) && found.valid?
        transform = found.respond_to?(:transformation) ? found.transformation : Geom::Transformation.new
        return [found, transform]
      end
    end

    recursive_find(model.entities, pid, Geom::Transformation.new, {})
  rescue StandardError
    recursive_find(model.entities, pid, Geom::Transformation.new, {})
  end

  def recursive_find(entities, pid, accumulated, visited)
    entities.each do |entity|
      entity_transform = entity.respond_to?(:transformation) ? entity.transformation : Geom::Transformation.new
      world_transform = accumulated * entity_transform
      return [entity, world_transform] if (entity.persistent_id rescue nil) == pid

      next unless entity.respond_to?(:definition)

      definition = entity.definition
      visit_key = [definition.object_id, world_transform.to_a]
      next if visited[visit_key]

      visited[visit_key] = true
      found = recursive_find(definition.entities, pid, world_transform, visited)
      return found if found
    end
    [nil, nil]
  end
end

nil
