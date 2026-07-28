# frozen_string_literal: true

# Materializes two persistent diagnostic copies for each currently failing LVN target:
#   1) GRID_NORMALIZED  - after independent grid snap + collapsed/duplicate cleanup,
#                         immediately before grid conforming.
#   2) GRID_CONFORMING  - after grid conforming + cleanup, immediately before the
#                         short-edge sliver stage / hard gate.
#
# The original entities are never modified. Unlike the normal diagnostic probes,
# the generated stage copies are intentionally COMMITTED and remain in the model.
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

    def materialize(entities, records)
      rebuild_triangles(entities, records)
    end

    def topology(entities)
      geometry_counts(entities)
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
      puts "[LVN STAGE COPIES] capture #{target[:label]} PID=#{target[:pid]}"
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

      result = {
        generated_at: Time.now.iso8601(3),
        copies: created.map { |entry| entry.reject { |key, _value| key == :group } }
      }
      $lvn_failed_targets_stage_copies = result
      print_summary(result)
      result
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
      removed = erase_generated_copies(model)
      model.commit_operation
      started = false
      puts "[LVN STAGE COPIES] removed=#{removed}"
      removed
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

    build = normalizer.materialize(group.entities, records)
    topology = normalizer.topology(group.entities)

    # Keep every generated triangle edge visible for direct triangulation inspection.
    group.entities.grep(Sketchup::Edge).each do |edge|
      edge.hidden = false if edge.respond_to?(:hidden=)
      edge.soft = false if edge.respond_to?(:soft=)
      edge.smooth = false if edge.respond_to?(:smooth=)
    end

    placement = Geom::Transformation.translation([offset_x_inches, 0, 0]) * world_transform
    group.transformation = placement

    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'generated', true)
    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'source_pid', target[:pid])
    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'source_name', source_entity.name.to_s)
    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'stage', stage.to_s)
    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'expected_triangle_count', records.length)
    group.set_attribute(DIAGNOSTIC_DICTIONARY, 'added_face_count', build[:added_faces].to_i)

    exact_rebuild = build[:added_faces].to_i == records.length &&
      build[:skipped_collinear].to_i.zero?

    unless exact_rebuild
      warn "[LVN STAGE COPIES] WARNING #{target[:label]} #{stage}: " \
           "SketchUp rebuild differs from in-memory stage " \
           "expected=#{records.length} added=#{build[:added_faces]} " \
           "skipped_collinear=#{build[:skipped_collinear]}"
    end

    {
      group: group,
      pid: group.persistent_id,
      source_pid: target[:pid],
      label: target[:label],
      stage: stage,
      name: group.name,
      expected_triangle_count: records.length,
      added_face_count: build[:added_faces].to_i,
      skipped_collinear: build[:skipped_collinear].to_i,
      exact_rebuild: exact_rebuild,
      sketchup_topology: topology,
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

  def print_summary(result)
    puts "\n#{'=' * 100}"
    puts '[LVN FAILED TARGET STAGE COPIES]'
    result[:copies].each do |entry|
      topology = entry[:sketchup_topology] || {}
      puts "#{entry[:label]} #{entry[:stage]}: " \
           "pid=#{entry[:pid]} triangles=#{entry[:expected_triangle_count]} " \
           "faces=#{entry[:added_face_count]} exact_rebuild=#{entry[:exact_rebuild]} " \
           "boundary=#{topology[:boundary_edges]} overused=#{topology[:overused_edges]} " \
           "tag=#{entry[:tag]} offset_x_mm=#{entry[:offset_x_mm].round(3)}"
    end
    puts 'Copies are committed and selected. Originals were not modified.'
    puts '=' * 100
  end
end
