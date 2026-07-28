# frozen_string_literal: true

# Exports one selected SketchUp solid into an indexed JSON description that is
# compact enough to share for LVN performance/debugging while preserving the
# actual Face-loop topology.
#
# The script is read-only: it never starts an operation or mutates geometry.
# Coordinates are definition-local millimetres, matching the geometry LVN sees.
#
# SketchUp Ruby Console:
#   load 'C:/ProgramData/SketchUp/SketchUp 2026/SketchUp/Devs/IndoorGML_3DSpace_Modeler/dev/lvn_selected_solid_geometry_probe.rb'
#   LvnSelectedSolidGeometryProbe.run

require 'json'
require 'tmpdir'
require 'time'

Object.send(:remove_const, :LvnSelectedSolidGeometryProbe) if
  defined?(LvnSelectedSolidGeometryProbe)

module LvnSelectedSolidGeometryProbe
  MM_PER_INCH = 25.4
  AREA_MM2_PER_INCH2 = MM_PER_INCH * MM_PER_INCH
  DEFAULT_DECIMALS = 6

  module_function

  def run(decimals: DEFAULT_DECIMALS)
    model = Sketchup.active_model
    solid = selected_solid(model)
    unless solid
      puts '[LVN SOLID PROBE] Select exactly one manifold Group/ComponentInstance.'
      return nil
    end

    decimals = Integer(decimals)
    raise ArgumentError, 'decimals must be between 0 and 9' unless decimals.between?(0, 9)

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    entities = solid.definition.entities
    faces = entities.grep(Sketchup::Face).select(&:valid?)
    edges = entities.grep(Sketchup::Edge).select(&:valid?)
    vertices = edges.flat_map { |edge| [edge.start, edge.end] }.uniq.select(&:valid?)

    vertex_index = {}
    vertices.each_with_index { |vertex, index| vertex_index[vertex.object_id] = index }
    face_index = {}
    faces.each_with_index { |face, index| face_index[face.object_id] = index }

    vertex_records = vertices.map.with_index do |vertex, index|
      {
        i: index,
        pid: safe_pid(vertex),
        p_mm: point_mm(vertex.position, decimals),
        edge_degree: safe_count { vertex.edges },
        face_degree: safe_count { vertex.faces }
      }
    end

    face_records = faces.map.with_index do |face, index|
      build_face_record(face, index, vertex_index, decimals)
    end

    edge_records = edges.map.with_index do |edge, index|
      build_edge_record(edge, index, vertex_index, face_index, decimals)
    end

    summary = build_summary(
      solid,
      vertices,
      faces,
      edges,
      vertex_records,
      face_records,
      edge_records,
      decimals
    )

    result = {
      schema: 'ulol.lvn_selected_solid_geometry_probe.v1',
      generated_at: Time.now.iso8601(3),
      coordinate_space: 'definition_local',
      length_unit: 'mm',
      area_unit: 'mm2',
      coordinate_decimals: decimals,
      entity: {
        pid: safe_pid(solid),
        name: entity_name(solid),
        entity_class: solid.class.to_s,
        definition_name: safe_definition_name(solid),
        manifold: safe_manifold(solid),
        tag: safe_tag_name(solid),
        transformation_to_parent: transformation_array(solid)
      },
      summary: summary,
      geometry: {
        vertices: vertex_records,
        edges: edge_records,
        faces: face_records
      }
    }

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    result[:summary][:probe_elapsed_sec] = elapsed

    path = File.join(
      Dir.tmpdir,
      "lvn_selected_solid_geometry_probe_#{safe_pid(solid) || 'no_pid'}_#{Time.now.strftime('%Y%m%d_%H%M%S')}.json"
    )
    File.open(path, 'w:UTF-8') { |file| file.write(JSON.pretty_generate(result)) }

    result[:json_path] = path
    $lvn_selected_solid_geometry_probe = result

    print_summary(result, path)
    nil
  rescue StandardError => error
    warn '[LVN SOLID PROBE] FAILED'
    warn "#{error.class}: #{error.message}"
    warn Array(error.backtrace).first(20).join("\n")
    nil
  end

  def build_face_record(face, index, vertex_index, decimals)
    loops = face.loops.map do |loop|
      {
        outer: loop == face.outer_loop,
        vertices: loop.vertices.map { |vertex| vertex_index.fetch(vertex.object_id) }
      }
    end

    mesh_triangle_count = safe_mesh_triangle_count(face)
    vertices = face.vertices.select(&:valid?)

    {
      i: index,
      pid: safe_pid(face),
      outer_vertex_count: face.outer_loop.vertices.length,
      total_vertex_count: vertices.length,
      loop_count: loops.length,
      hole_count: [loops.length - 1, 0].max,
      mesh_triangle_count: mesh_triangle_count,
      area_mm2: round_number(face.area.to_f * AREA_MM2_PER_INCH2, decimals),
      normal: vector_array(face.normal, 9),
      bbox_mm: points_bbox_mm(vertices.map(&:position), decimals),
      loops: loops
    }
  end

  def build_edge_record(edge, index, vertex_index, face_index, decimals)
    owning_faces = edge.faces.select(&:valid?)
    {
      i: index,
      pid: safe_pid(edge),
      vertices: [
        vertex_index.fetch(edge.start.object_id),
        vertex_index.fetch(edge.end.object_id)
      ],
      faces: owning_faces.filter_map { |face| face_index[face.object_id] }.sort,
      face_count: owning_faces.length,
      length_mm: round_number(edge.length.to_f * MM_PER_INCH, decimals),
      soft: safe_boolean { edge.soft? },
      smooth: safe_boolean { edge.smooth? },
      hidden: safe_boolean { edge.hidden? },
      curve: safe_curve_class(edge)
    }
  end

  def build_summary(solid, vertices, faces, edges, vertex_records, face_records, edge_records, decimals)
    face_vertex_counts = face_records.map { |record| record[:outer_vertex_count] }
    face_loop_counts = face_records.map { |record| record[:loop_count] }
    triangle_counts = face_records.map { |record| record[:mesh_triangle_count] }.compact
    face_areas = face_records.map { |record| record[:area_mm2].to_f }
    edge_lengths = edge_records.map { |record| record[:length_mm].to_f }
    edge_face_counts = edge_records.map { |record| record[:face_count] }
    vertex_edge_degrees = vertex_records.map { |record| record[:edge_degree].to_i }
    vertex_face_degrees = vertex_records.map { |record| record[:face_degree].to_i }

    boundary_edges = edge_records.count { |record| record[:face_count] == 1 }
    overused_edges = edge_records.count { |record| record[:face_count] > 2 }
    stray_edges = edge_records.count { |record| record[:face_count].zero? }
    face_component_sizes = face_connected_component_sizes(faces.length, edge_records)
    chi = vertices.length - edges.length + faces.length

    adjacent_angles = adjacent_face_angles_deg(faces, edge_records)

    {
      counts: {
        vertices: vertices.length,
        edges: edges.length,
        faces: faces.length,
        boundary_edges: boundary_edges,
        overused_edges: overused_edges,
        stray_edges: stray_edges,
        face_connected_components: face_component_sizes.length,
        mesh_triangles: triangle_counts.sum,
        faces_with_holes: face_records.count { |record| record[:hole_count].positive? },
        total_holes: face_records.sum { |record| record[:hole_count] }
      },
      topology: {
        manifold: safe_manifold(solid),
        closed_by_edge_incidence: faces.any? && boundary_edges.zero? && overused_edges.zero?,
        euler_characteristic: chi,
        face_component_sizes: face_component_sizes.sort.reverse
      },
      bbox_mm: points_bbox_mm(vertices.map(&:position), decimals),
      face_outer_vertex_count: numeric_stats(face_vertex_counts),
      face_loop_count: numeric_stats(face_loop_counts),
      face_mesh_triangle_count: numeric_stats(triangle_counts),
      face_area_mm2: numeric_stats(face_areas),
      edge_length_mm: numeric_stats(edge_lengths),
      adjacent_face_angle_deg: numeric_stats(adjacent_angles),
      histograms: {
        face_outer_vertex_count: histogram(face_vertex_counts),
        face_loop_count: histogram(face_loop_counts),
        edge_face_count: histogram(edge_face_counts),
        vertex_edge_degree: histogram(vertex_edge_degrees),
        vertex_face_degree: histogram(vertex_face_degrees)
      },
      small_geometry: {
        edge_length_lt_mm: threshold_counts(edge_lengths, [0.001, 0.01, 0.1, 1.0, 10.0]),
        face_area_lt_mm2: threshold_counts(face_areas, [0.000001, 0.001, 1.0, 100.0]),
        adjacent_face_angle_le_deg: threshold_counts(adjacent_angles, [0.001, 0.01, 0.1, 1.0])
      },
      largest_faces_by_vertices: face_records
        .sort_by { |record| [-record[:outer_vertex_count], -record[:mesh_triangle_count].to_i, record[:i]] }
        .first(20)
        .map do |record|
          {
            i: record[:i],
            pid: record[:pid],
            outer_vertex_count: record[:outer_vertex_count],
            loop_count: record[:loop_count],
            hole_count: record[:hole_count],
            mesh_triangle_count: record[:mesh_triangle_count],
            area_mm2: record[:area_mm2]
          }
        end
    }
  end

  def adjacent_face_angles_deg(faces, edge_records)
    edge_records.filter_map do |edge_record|
      indices = edge_record[:faces]
      next unless indices.length == 2

      first = faces[indices[0]]
      second = faces[indices[1]]
      next unless first&.valid? && second&.valid?

      normal_angle_deg(first.normal, second.normal)
    end
  end

  def normal_angle_deg(first, second)
    a = [first.x.to_f, first.y.to_f, first.z.to_f]
    b = [second.x.to_f, second.y.to_f, second.z.to_f]
    al = Math.sqrt(a.sum { |value| value * value })
    bl = Math.sqrt(b.sum { |value| value * value })
    return nil unless al.positive? && bl.positive?

    cosine = ((a[0] * b[0]) + (a[1] * b[1]) + (a[2] * b[2])) / (al * bl)
    cosine = [[cosine, -1.0].max, 1.0].min
    Math.acos(cosine) * 180.0 / Math::PI
  rescue StandardError
    nil
  end

  def face_connected_component_sizes(face_count, edge_records)
    adjacency = Array.new(face_count) { [] }
    edge_records.each do |record|
      owners = record[:faces]
      next unless owners.length == 2

      a, b = owners
      adjacency[a] << b
      adjacency[b] << a
    end

    visited = Array.new(face_count, false)
    sizes = []
    face_count.times do |seed|
      next if visited[seed]

      visited[seed] = true
      queue = [seed]
      cursor = 0
      size = 0
      while cursor < queue.length
        current = queue[cursor]
        cursor += 1
        size += 1
        adjacency[current].each do |neighbor|
          next if visited[neighbor]

          visited[neighbor] = true
          queue << neighbor
        end
      end
      sizes << size
    end
    sizes
  end

  def safe_mesh_triangle_count(face)
    mesh = face.mesh(0)
    if mesh.respond_to?(:count_polygons)
      mesh.count_polygons
    else
      mesh.polygons.length
    end
  rescue StandardError
    nil
  end

  def numeric_stats(values)
    values = values.compact.map(&:to_f).select(&:finite?).sort
    return { count: 0 } if values.empty?

    {
      count: values.length,
      min: values.first,
      p50: percentile(values, 0.50),
      p90: percentile(values, 0.90),
      p99: percentile(values, 0.99),
      max: values.last,
      mean: values.sum / values.length
    }
  end

  def percentile(sorted, ratio)
    return sorted.first if sorted.length == 1

    position = ratio * (sorted.length - 1)
    lower = position.floor
    upper = position.ceil
    return sorted[lower] if lower == upper

    fraction = position - lower
    sorted[lower] + ((sorted[upper] - sorted[lower]) * fraction)
  end

  def histogram(values)
    values.each_with_object(Hash.new(0)) { |value, hash| hash[value.to_s] += 1 }
          .sort_by { |key, _value| numeric_sort_key(key) }
          .to_h
  end

  def numeric_sort_key(value)
    Float(value)
  rescue StandardError
    value.to_s
  end

  def threshold_counts(values, thresholds)
    thresholds.each_with_object({}) do |threshold, hash|
      hash[threshold.to_s] = values.count { |value| value.to_f <= threshold }
    end
  end

  def points_bbox_mm(points, decimals)
    return nil if points.empty?

    xs = points.map { |point| point.x.to_f * MM_PER_INCH }
    ys = points.map { |point| point.y.to_f * MM_PER_INCH }
    zs = points.map { |point| point.z.to_f * MM_PER_INCH }
    min = [xs.min, ys.min, zs.min]
    max = [xs.max, ys.max, zs.max]
    size = 3.times.map { |index| max[index] - min[index] }

    {
      min: min.map { |value| round_number(value, decimals) },
      max: max.map { |value| round_number(value, decimals) },
      size: size.map { |value| round_number(value, decimals) },
      diagonal: round_number(Math.sqrt(size.sum { |value| value * value }), decimals)
    }
  end

  def point_mm(point, decimals)
    [point.x, point.y, point.z].map do |value|
      round_number(value.to_f * MM_PER_INCH, decimals)
    end
  end

  def vector_array(vector, decimals)
    [vector.x, vector.y, vector.z].map { |value| round_number(value.to_f, decimals) }
  end

  def round_number(value, decimals)
    value.to_f.round(decimals)
  end

  def selected_solid(model)
    candidates = model.selection.to_a.select do |entity|
      entity&.valid? && entity.respond_to?(:definition) && entity.respond_to?(:manifold?)
    end
    return nil unless candidates.length == 1

    solid = candidates.first
    solid.manifold? == true ? solid : nil
  rescue StandardError
    nil
  end

  def safe_pid(entity)
    entity.persistent_id
  rescue StandardError
    nil
  end

  def safe_manifold(entity)
    entity.respond_to?(:manifold?) ? entity.manifold? == true : nil
  rescue StandardError
    nil
  end

  def safe_definition_name(entity)
    entity.definition.name.to_s
  rescue StandardError
    nil
  end

  def safe_tag_name(entity)
    entity.layer.name.to_s
  rescue StandardError
    nil
  end

  def transformation_array(entity)
    return nil unless entity.respond_to?(:transformation)

    entity.transformation.to_a.map(&:to_f)
  rescue StandardError
    nil
  end

  def safe_curve_class(edge)
    curve = edge.curve
    curve ? curve.class.to_s : nil
  rescue StandardError
    nil
  end

  def safe_boolean
    !!yield
  rescue StandardError
    nil
  end

  def safe_count
    Array(yield).length
  rescue StandardError
    nil
  end

  def entity_name(entity)
    name = entity.respond_to?(:name) ? entity.name.to_s : ''
    return name unless name.empty?

    definition_name = safe_definition_name(entity).to_s
    return definition_name unless definition_name.empty?

    entity.class.to_s
  rescue StandardError
    entity.class.to_s
  end

  def print_summary(result, path)
    summary = result[:summary]
    counts = summary[:counts]
    bbox = summary[:bbox_mm]
    puts '=' * 100
    puts '[LVN SOLID PROBE] COMPLETE'
    puts "solid=#{result.dig(:entity, :name)} PID=#{result.dig(:entity, :pid)}"
    puts "V/E/F=#{counts[:vertices]}/#{counts[:edges]}/#{counts[:faces]} mesh_triangles=#{counts[:mesh_triangles]}"
    puts "boundary=#{counts[:boundary_edges]} overused=#{counts[:overused_edges]} stray=#{counts[:stray_edges]} components=#{counts[:face_connected_components]}"
    puts "bbox_size_mm=#{bbox && bbox[:size].inspect} diagonal_mm=#{bbox && bbox[:diagonal]}"
    puts "face_vertices max=#{summary.dig(:face_outer_vertex_count, :max)} p90=#{summary.dig(:face_outer_vertex_count, :p90)}"
    puts "edge_length_mm min=#{summary.dig(:edge_length_mm, :min)} p50=#{summary.dig(:edge_length_mm, :p50)}"
    puts format('elapsed=%.3f s', summary[:probe_elapsed_sec].to_f)
    puts "JSON: #{path}"
    puts '=' * 100
  end
end

nil
