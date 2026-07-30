# frozen_string_literal: true

Object.send(:remove_const, :IndoorGMLCellSpaceBatchStressProbe) \
  if Object.const_defined?(:IndoorGMLCellSpaceBatchStressProbe, false)

module IndoorGMLCellSpaceBatchStressProbe
  COUNT = 3000
  SEED = 20260730
  GRID_PITCH_MM = 20_000.0

  LOG_PATH = File.join(
    ENV['TEMP'] || ENV['TMP'] || '.',
    'IndoorGML_cellspace_batch_stress.log'
  )

  @material_ensure_keys_original = nil

  module_function

  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def log(message)
    line = "[#{Time.now.strftime('%Y-%m-%d %H:%M:%S.%L')}] #{message}"
    puts line
    File.open(LOG_PATH, 'a') do |file|
      file.puts(line)
      file.flush
    end
    line
  rescue StandardError => e
    puts "[BATCH STRESS LOG ERROR] #{e.class}: #{e.message}"
    nil
  end

  def random_range(rng, min_value, max_value)
    min_value + rng.rand * (max_value - min_value)
  end

  def create_box(group, rng)
    width = random_range(rng, 2500.0, 8000.0)
    depth = random_range(rng, 2500.0, 8000.0)
    height = random_range(rng, 2400.0, 5500.0)
    face = group.entities.add_face([
      Geom::Point3d.new(0.mm, 0.mm, 0.mm),
      Geom::Point3d.new(width.mm, 0.mm, 0.mm),
      Geom::Point3d.new(width.mm, depth.mm, 0.mm),
      Geom::Point3d.new(0.mm, depth.mm, 0.mm)
    ])
    raise 'Box face creation failed' unless face&.valid?

    face.reverse! if face.normal.z < 0.0
    face.pushpull(height.mm)
  end

  def create_l_prism(group, rng)
    width = random_range(rng, 4000.0, 8000.0)
    depth = random_range(rng, 4000.0, 8000.0)
    height = random_range(rng, 2400.0, 5500.0)
    cut_x = random_range(rng, width * 0.35, width * 0.70)
    cut_y = random_range(rng, depth * 0.35, depth * 0.70)
    face = group.entities.add_face([
      Geom::Point3d.new(0.mm, 0.mm, 0.mm),
      Geom::Point3d.new(width.mm, 0.mm, 0.mm),
      Geom::Point3d.new(width.mm, cut_y.mm, 0.mm),
      Geom::Point3d.new(cut_x.mm, cut_y.mm, 0.mm),
      Geom::Point3d.new(cut_x.mm, depth.mm, 0.mm),
      Geom::Point3d.new(0.mm, depth.mm, 0.mm)
    ])
    raise 'L-prism face creation failed' unless face&.valid?

    face.reverse! if face.normal.z < 0.0
    face.pushpull(height.mm)
  end

  def generate_sources(model)
    raise "Probe requires an empty model: root_entities=#{model.entities.length}" unless model.entities.length.zero?

    rng = Random.new(SEED)
    columns = Math.sqrt(COUNT).ceil
    groups = []
    started = clock
    operation_started = model.start_operation("Generate #{COUNT} Batch Stress Solids", true)
    raise 'Failed to start source generation operation' unless operation_started

    begin
      COUNT.times do |index|
        group = model.entities.add_group
        group.name = format('BatchStress_%04d', index + 1)
        rng.rand < 0.70 ? create_box(group, rng) : create_l_prism(group, rng)
        raise "Generated source is not manifold: #{group.name}" unless group.manifold?

        column = index % columns
        row = index / columns
        translation = Geom::Transformation.translation(
          Geom::Vector3d.new(
            (column * GRID_PITCH_MM).mm,
            (row * GRID_PITCH_MM).mm,
            0.mm
          )
        )
        rotation = Geom::Transformation.rotation(
          ORIGIN,
          Z_AXIS,
          random_range(rng, -35.0, 35.0).degrees
        )
        group.transformation = translation * rotation
        groups << group
        log("SOURCE #{index + 1}/#{COUNT}") if ((index + 1) % 500).zero?
      end

      committed = model.commit_operation
      raise 'Source generation commit failed' if committed == false
      operation_started = false
    rescue StandardError
      model.abort_operation if operation_started
      raise
    end

    log(format('SOURCE GENERATION COMPLETE count=%d elapsed=%.3fs', groups.length, clock - started))
    groups
  end

  def build_jobs(groups)
    core = ULOL::Indoor3DGmlModeler::IndoorCore
    jobs = core::CellSpaceConversionJobBuilder.new(entities: groups).build
    core::CellSpaceConversionJobBuilder.apply_fallback_storey(
      jobs,
      core::CellSpace::DEFAULT_STOREY
    )
  end

  def install_instance_probe(object, method_name, counters, times)
    singleton = object.singleton_class
    original = object.method(method_name)
    singleton.send(:define_method, method_name) do |*args, **kwargs, &block|
      counters[method_name] += 1
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        if kwargs.empty?
          original.call(*args, &block)
        else
          original.call(*args, **kwargs, &block)
        end
      ensure
        times[method_name] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end
    end
    method_name
  end

  def install_material_probe(counters, times)
    materials = ULOL::Indoor3DGmlModeler::Utils::Materials
    singleton = materials.singleton_class
    @material_ensure_keys_original = singleton.instance_method(:ensure_keys)
    original = materials.method(:ensure_keys)
    singleton.send(:define_method, :ensure_keys) do |keys|
      counters[:ensure_keys] += 1
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        original.call(keys)
      ensure
        times[:ensure_keys] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end
    end
    true
  end

  def restore_probe(object, method_names)
    singleton = object.singleton_class
    Array(method_names).each do |method_name|
      singleton.send(:remove_method, method_name) if singleton.instance_methods(false).include?(method_name)
    end
  rescue StandardError => e
    log("PROBE RESTORE ERROR #{e.class}: #{e.message}")
  end

  def restore_material_probe
    original = @material_ensure_keys_original
    return unless original

    singleton = ULOL::Indoor3DGmlModeler::Utils::Materials.singleton_class
    singleton.send(:define_method, :ensure_keys, original)
    @material_ensure_keys_original = nil
  rescue StandardError => e
    log("MATERIAL PROBE RESTORE ERROR #{e.class}: #{e.message}")
  end

  def verify_runtime(indoor_model, result, counters)
    core = ULOL::Indoor3DGmlModeler::IndoorCore
    cells = Array(indoor_model.cell_spaces)
    states = Array(indoor_model.states)
    transitions = Array(indoor_model.transitions)

    material_violations = 0
    face_material_violations = 0
    invalid_cells = 0

    cells.each do |cell_space|
      unless cell_space&.valid?
        invalid_cells += 1
        next
      end

      label = core::CellSpaceType.label(cell_space.cell_type)
      definition = ULOL::Indoor3DGmlModeler::Utils::Materials::MATERIAL_DEFINITIONS[label]
      expected_name = definition && definition[0]
      actual_name = cell_space.sketchup_group.material&.name.to_s
      material_violations += 1 if expected_name && actual_name != expected_name

      cell_space.sketchup_group.definition.entities.grep(Sketchup::Face).each do |face|
        face_material_violations += 1 unless face.material.nil? && face.back_material.nil?
      end
    end

    features = cells + states + transitions
    ids = features.map { |feature| feature.id.to_s }
    duplicate_ids = ids.length - ids.uniq.length
    registry = indoor_model.instance_variable_get(:@feature_registry)
    registry_index_misses = features.count do |feature|
      !registry.respond_to?(:feature_by_id) || !registry.feature_by_id(feature.id).equal?(feature)
    end

    checks = {
      converted: result.converted_count == COUNT,
      errors: result.errors.empty?,
      cells: cells.length == COUNT,
      states: states.length == COUNT,
      valid_cells: invalid_cells.zero?,
      materials: material_violations.zero?,
      face_materials: face_material_violations.zero?,
      unique_ids: duplicate_ids.zero?,
      registry_index: registry_index_misses.zero?,
      prepare_once: counters[:prepare_cell_space_batch_environment] == 1,
      material_batch_once: counters[:apply_cell_space_materials_batch] == 1,
      material_resolve_once: counters[:ensure_keys] == 1,
      topology_once: counters[:synchronize_topology_after_bulk_conversion] == 1,
      lock_once: counters[:apply_indoor_lock_policy] == 1
    }

    log(
      "VERIFY cells=#{cells.length} states=#{states.length} transitions=#{transitions.length} " \
      "invalid_cells=#{invalid_cells} material_violations=#{material_violations} " \
      "face_material_violations=#{face_material_violations} duplicate_ids=#{duplicate_ids} " \
      "registry_index_misses=#{registry_index_misses}"
    )
    checks.each { |key, passed| log("CHECK #{key}=#{passed ? 'PASS' : 'FAIL'}") }
    checks.values.all?
  end

  def run
    File.write(LOG_PATH, "")
    model = Sketchup.active_model
    core = ULOL::Indoor3DGmlModeler::IndoorCore
    indoor_model = core::IndoorModel.current
    raise 'IndoorModel.current unavailable' unless indoor_model

    log("BATCH STRESS START count=#{COUNT} seed=#{SEED}")
    log("LOG PATH: #{LOG_PATH}")

    groups = generate_sources(model)
    jobs = build_jobs(groups)
    log("JOBS BUILT count=#{jobs.length}")

    counters = Hash.new(0)
    times = Hash.new(0.0)
    probed_methods = [
      :prepare_cell_space_batch_environment,
      :apply_cell_space_materials_batch,
      :synchronize_topology_after_bulk_conversion,
      :apply_indoor_lock_policy
    ]
    probed_methods.each do |method_name|
      install_instance_probe(indoor_model, method_name, counters, times)
    end
    install_material_probe(counters, times)

    original_active_path = model.active_path ? model.active_path.dup : nil
    started = clock
    result = nil
    begin
      result = indoor_model.convert_cell_space_jobs_bulk(
        jobs,
        fallback_target: [core::CellSpaceType::GENERAL, nil],
        original_active_path: original_active_path,
        operation_name: "Batch Stress #{COUNT} CellSpaces",
        activate_root_context: true
      )
    ensure
      restore_probe(indoor_model, probed_methods)
      restore_material_probe
    end
    elapsed = clock - started

    log(
      format(
        'BULK RETURNED converted=%d errors=%d elapsed=%.3fs',
        result.converted_count,
        result.errors.length,
        elapsed
      )
    )
    log("METRICS #{result.metrics.inspect}")
    counters.each do |key, count|
      log(format('CALL %-45s count=%d time=%.3fs', key, count, times[key]))
    end

    passed = verify_runtime(indoor_model, result, counters)
    log("BATCH STRESS #{passed ? 'PASS' : 'FAIL'}")
    passed
  rescue StandardError => e
    restore_material_probe
    log("BATCH STRESS ERROR #{e.class}: #{e.message}")
    Array(e.backtrace).each { |line| log("BACKTRACE #{line}") }
    false
  end
end

IndoorGMLCellSpaceBatchStressProbe.run

nil
