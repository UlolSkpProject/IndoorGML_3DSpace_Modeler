# frozen_string_literal: true

# Deep runtime profiler for CellSpace batch creation.
#
# This file changes no production behavior. It temporarily wraps the existing
# conversion methods, runs the normal batch stress probe with a reduced sample,
# prints per-stage totals and bucket growth, then restores every wrapper.

Object.send(:remove_const, :IndoorGMLCellSpaceBatchDeepProfile) \
  if Object.const_defined?(:IndoorGMLCellSpaceBatchDeepProfile, false)

module IndoorGMLCellSpaceBatchDeepProfile
  DEFAULT_COUNT = 1000
  BUCKET_SIZE = 250
  LOG_PATH = File.join(
    ENV['TEMP'] || ENV['TMP'] || '.',
    'IndoorGML_cellspace_batch_deep_profile.log'
  )

  @stats = {}
  @patches = []
  @current_index = 0
  @execute_count = 0

  module_function

  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def allocated_objects
    GC.stat[:total_allocated_objects].to_i
  rescue StandardError
    0
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
    puts "[DEEP PROFILE LOG ERROR] #{e.class}: #{e.message}"
    nil
  end

  def begin_execute
    @execute_count = @execute_count.to_i + 1
    @current_index = @execute_count
  end

  def finish_execute
    @current_index = 0
  end

  def bucket_for_current_item
    index = @current_index.to_i
    return nil if index <= 0

    (index - 1) / BUCKET_SIZE
  end

  def record(label, elapsed, allocated)
    stat = (@stats[label] ||= {
      count: 0,
      total: 0.0,
      max: 0.0,
      allocated: 0,
      buckets: {}
    })
    stat[:count] += 1
    stat[:total] += elapsed
    stat[:max] = elapsed if elapsed > stat[:max]
    stat[:allocated] += allocated

    bucket = bucket_for_current_item
    return unless bucket

    bucket_stat = (stat[:buckets][bucket] ||= {
      count: 0,
      total: 0.0,
      allocated: 0
    })
    bucket_stat[:count] += 1
    bucket_stat[:total] += elapsed
    bucket_stat[:allocated] += allocated
  end

  def measure(label)
    started = clock
    allocated_before = allocated_objects
    yield
  ensure
    elapsed = clock - started
    allocated = allocated_objects - allocated_before
    record(label, elapsed, allocated)
  end

  def method_visibility(klass, method_name)
    return :private if klass.private_method_defined?(method_name)
    return :protected if klass.protected_method_defined?(method_name)

    :public
  end

  def direct_method_defined?(klass, method_name)
    klass.instance_methods(false).include?(method_name) ||
      klass.private_instance_methods(false).include?(method_name) ||
      klass.protected_instance_methods(false).include?(method_name)
  end

  def patch_instance_method(klass, method_name, label)
    return false unless klass.method_defined?(method_name) ||
                        klass.private_method_defined?(method_name) ||
                        klass.protected_method_defined?(method_name)

    original = klass.instance_method(method_name)
    visibility = method_visibility(klass, method_name)
    direct = direct_method_defined?(klass, method_name)

    klass.send(:define_method, method_name) do |*args, **kwargs, &block|
      IndoorGMLCellSpaceBatchDeepProfile.measure(label) do
        bound = original.bind(self)
        if kwargs.empty?
          bound.call(*args, &block)
        else
          bound.call(*args, **kwargs, &block)
        end
      end
    end
    klass.send(visibility, method_name)
    @patches << [:instance, klass, method_name, original, visibility, direct]
    true
  end

  def patch_executor_execute(core)
    klass = core::CellSpaceConversionExecutor
    method_name = :execute
    original = klass.instance_method(method_name)
    visibility = method_visibility(klass, method_name)
    direct = direct_method_defined?(klass, method_name)

    klass.send(:define_method, method_name) do |*args, **kwargs, &block|
      IndoorGMLCellSpaceBatchDeepProfile.begin_execute
      IndoorGMLCellSpaceBatchDeepProfile.measure('executor.execute') do
        bound = original.bind(self)
        if kwargs.empty?
          bound.call(*args, &block)
        else
          bound.call(*args, **kwargs, &block)
        end
      end
    ensure
      IndoorGMLCellSpaceBatchDeepProfile.finish_execute
    end
    klass.send(visibility, method_name)
    @patches << [:instance, klass, method_name, original, visibility, direct]
  end

  def patch_singleton_method(object, method_name, label)
    return false unless object.respond_to?(method_name, true)

    singleton = object.singleton_class
    direct = singleton.instance_methods(false).include?(method_name) ||
             singleton.private_instance_methods(false).include?(method_name) ||
             singleton.protected_instance_methods(false).include?(method_name)
    original = object.method(method_name)
    visibility = if singleton.private_method_defined?(method_name)
                   :private
                 elsif singleton.protected_method_defined?(method_name)
                   :protected
                 else
                   :public
                 end

    singleton.send(:define_method, method_name) do |*args, **kwargs, &block|
      IndoorGMLCellSpaceBatchDeepProfile.measure(label) do
        if kwargs.empty?
          original.call(*args, &block)
        else
          original.call(*args, **kwargs, &block)
        end
      end
    end
    singleton.send(visibility, method_name)
    @patches << [:singleton, singleton, method_name, original, visibility, direct]
    true
  end

  def restore_patches
    @patches.reverse_each do |kind, owner, method_name, original, visibility, direct|
      if kind == :instance
        if direct
          owner.send(:define_method, method_name, original)
          owner.send(visibility, method_name)
        elsif direct_method_defined?(owner, method_name)
          owner.send(:remove_method, method_name)
        end
      elsif direct
        owner.send(:define_method, method_name, original)
        owner.send(visibility, method_name)
      elsif owner.instance_methods(false).include?(method_name) ||
            owner.private_instance_methods(false).include?(method_name) ||
            owner.protected_instance_methods(false).include?(method_name)
        owner.send(:remove_method, method_name)
      end
    rescue StandardError => e
      log("RESTORE ERROR #{owner}##{method_name} #{e.class}: #{e.message}")
    end
    @patches = []
  end

  def install_probes(indoor_model)
    core = ULOL::Indoor3DGmlModeler::IndoorCore

    patch_executor_execute(core)
    {
      isolate_instance_source: 'executor.isolate_instance_source',
      prepare_source: 'executor.prepare_source',
      call_converter: 'executor.call_converter',
      cleanup_empty_ancestors: 'executor.cleanup_empty_ancestors'
    }.each do |method_name, label|
      patch_instance_method(core::CellSpaceConversionExecutor, method_name, label)
    end

    patch_instance_method(
      core::CellSpaceLifecycleService,
      :create_from_group_deferred,
      'lifecycle.create_from_group_deferred'
    )

    {
      converted?: 'source_preparer.converted?',
      resolve_type_and_category: 'source_preparer.resolve_type_and_category',
      prepare!: 'source_preparer.prepare!',
      resolve_storey: 'source_preparer.resolve_storey'
    }.each do |method_name, label|
      patch_instance_method(core::CellSpaceLifecycleSourcePreparer, method_name, label)
    end

    {
      prepare_cell_group: 'context.prepare_cell_group',
      initialize_scene: 'context.initialize_scene',
      register_created: 'context.register_created'
    }.each do |method_name, label|
      patch_instance_method(core::CellSpaceBatchLifecycleContext, method_name, label)
    end

    patch_instance_method(core::CellSpace, :create_duality_state, 'cell_space.create_duality_state')

    {
      place_cell_group: 'model.place_cell_group',
      fixed_state_height_offset: 'model.fixed_state_height_offset',
      recenter_cell_space_geometry: 'model.recenter_cell_space_geometry',
      name_cell_space_entity: 'model.name_cell_space_entity',
      register_cell_space: 'model.register_cell_space',
      register_state: 'model.register_state',
      write_attributes: 'model.write_attributes',
      track_cell_space_entity: 'model.track_cell_space_entity'
    }.each do |method_name, label|
      patch_singleton_method(indoor_model, method_name, label)
    end

    if defined?(ULOL::Indoor3DGmlModeler::IndoorCore::EntityCopyHelper)
      patch_singleton_method(
        ULOL::Indoor3DGmlModeler::IndoorCore::EntityCopyHelper,
        :copy_instance,
        'entity_copy.copy_instance'
      )
    end

    if defined?(ULOL::Indoor3DGmlModeler::Utils::Geometry)
      patch_singleton_method(
        ULOL::Indoor3DGmlModeler::Utils::Geometry,
        :prepare_cell_space_source_group!,
        'geometry.prepare_cell_space_source_group!'
      )
    end

    if defined?(ULOL::Indoor3DGmlModeler::IndoorCore::AttributeSerializer)
      patch_instance_method(
        ULOL::Indoor3DGmlModeler::IndoorCore::AttributeSerializer,
        :write_cell_space_and_state,
        'attributes.write_cell_space_and_state'
      )
    end
  end

  def print_stats(count)
    log("DEEP PROFILE SUMMARY count=#{count} bucket_size=#{BUCKET_SIZE}")
    @stats.sort_by { |_label, stat| -stat[:total] }.each do |label, stat|
      average_ms = stat[:count].positive? ? (stat[:total] * 1000.0 / stat[:count]) : 0.0
      log(
        format(
          'PROFILE %-42s count=%5d total=%9.3fs avg=%8.3fms max=%8.3fms alloc=%d',
          label,
          stat[:count],
          stat[:total],
          average_ms,
          stat[:max] * 1000.0,
          stat[:allocated]
        )
      )
      stat[:buckets].sort.each do |bucket, bucket_stat|
        first = (bucket * BUCKET_SIZE) + 1
        last = [first + BUCKET_SIZE - 1, count].min
        bucket_avg_ms = bucket_stat[:count].positive? ?
          (bucket_stat[:total] * 1000.0 / bucket_stat[:count]) : 0.0
        log(
          format(
            '  BUCKET %4d-%4d count=%5d total=%8.3fs avg=%8.3fms alloc=%d',
            first,
            last,
            bucket_stat[:count],
            bucket_stat[:total],
            bucket_avg_ms,
            bucket_stat[:allocated]
          )
        )
      end
    end
  end

  def run(count = DEFAULT_COUNT)
    File.write(LOG_PATH, '')
    model = Sketchup.active_model
    raise "Deep profile requires an empty model: root_entities=#{model.entities.length}" unless model.entities.length.zero?

    core = ULOL::Indoor3DGmlModeler::IndoorCore
    indoor_model = core::IndoorModel.current
    raise 'IndoorModel.current unavailable' unless indoor_model

    @stats = {}
    @execute_count = 0
    @current_index = 0

    log("DEEP PROFILE START count=#{count}")
    install_probes(indoor_model)

    stress_path = File.join(__dir__, 'cell_space_batch_stress_probe.rb')
    source = File.read(stress_path)
    source = source.sub(/COUNT = 3000\b/, "COUNT = #{Integer(count)}")
    raise 'Stress probe COUNT override failed' unless source.include?("COUNT = #{Integer(count)}")

    eval(source, TOPLEVEL_BINDING, stress_path)
    print_stats(Integer(count))
    true
  rescue StandardError => e
    log("DEEP PROFILE ERROR #{e.class}: #{e.message}")
    Array(e.backtrace).each { |line| log("BACKTRACE #{line}") }
    false
  ensure
    restore_patches
  end
end

IndoorGMLCellSpaceBatchDeepProfile.run

nil
