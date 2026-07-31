# frozen_string_literal: true

# Lightweight 3000-CellSpace growth profiler.
#
# Runs the existing batch stress probe unchanged while temporarily measuring
# only three hot paths:
# - CellSpaceConversionExecutor#execute
# - IndoorModel#recenter_cell_space_geometry
# - EntityCopyHelper.copy_instance
#
# Every 250 converted sources it logs wall/process CPU time plus GC deltas.
# Production behavior is not changed and every wrapper is restored afterwards.

Object.send(:remove_const, :IndoorGMLCellSpaceBatchGrowthProbe) \
  if Object.const_defined?(:IndoorGMLCellSpaceBatchGrowthProbe, false)

module IndoorGMLCellSpaceBatchGrowthProbe
  COUNT = 3000
  BUCKET_SIZE = 250
  LOG_PATH = File.join(
    ENV['TEMP'] || ENV['TMP'] || '.',
    'IndoorGML_cellspace_batch_growth.log'
  )

  @current_index = 0
  @execute_count = 0
  @bucket_started_wall = nil
  @bucket_started_cpu = nil
  @bucket_started_gc = nil
  @bucket_stats = {}
  @patches = []

  module_function

  def wall_clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def process_cpu_clock
    Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)
  rescue StandardError
    nil
  end

  def gc_snapshot
    stat = GC.stat
    {
      count: stat[:count].to_i,
      major: stat[:major_gc_count].to_i,
      minor: stat[:minor_gc_count].to_i,
      time: stat[:time],
      heap_live_slots: stat[:heap_live_slots].to_i,
      heap_allocated_pages: stat[:heap_allocated_pages].to_i,
      total_allocated_objects: stat[:total_allocated_objects].to_i,
      total_freed_objects: stat[:total_freed_objects].to_i
    }
  rescue StandardError
    {}
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
    puts "[BATCH GROWTH LOG ERROR] #{e.class}: #{e.message}"
    nil
  end

  def bucket_index_for(index)
    (index - 1) / BUCKET_SIZE
  end

  def begin_execute
    @execute_count = @execute_count.to_i + 1
    @current_index = @execute_count
    return unless ((@current_index - 1) % BUCKET_SIZE).zero?

    @bucket_started_wall = wall_clock
    @bucket_started_cpu = process_cpu_clock
    @bucket_started_gc = gc_snapshot
  end

  def finish_execute
    index = @current_index.to_i
    checkpoint(index) if index.positive? && (index % BUCKET_SIZE).zero?
  ensure
    @current_index = 0
  end

  def record(label, elapsed)
    index = @current_index.to_i
    return if index <= 0

    bucket = bucket_index_for(index)
    key = [label, bucket]
    stat = (@bucket_stats[key] ||= { count: 0, total: 0.0, max: 0.0 })
    stat[:count] += 1
    stat[:total] += elapsed
    stat[:max] = elapsed if elapsed > stat[:max]
  end

  def measure(label)
    started = wall_clock
    yield
  ensure
    record(label, wall_clock - started)
  end

  def delta(current, previous, key)
    current.fetch(key, 0).to_i - previous.fetch(key, 0).to_i
  end

  def checkpoint(index)
    bucket = bucket_index_for(index)
    first = (bucket * BUCKET_SIZE) + 1
    current_wall = wall_clock
    current_cpu = process_cpu_clock
    current_gc = gc_snapshot
    started_gc = @bucket_started_gc || {}

    wall_elapsed = @bucket_started_wall ? current_wall - @bucket_started_wall : 0.0
    cpu_elapsed = if current_cpu && @bucket_started_cpu
                    current_cpu - @bucket_started_cpu
                  end
    cpu_ratio = if cpu_elapsed && wall_elapsed.positive?
                  cpu_elapsed / wall_elapsed
                end

    gc_time_delta = if current_gc[:time] && started_gc[:time]
                      current_gc[:time].to_f - started_gc[:time].to_f
                    end

    log(
      format(
        'CHECKPOINT %4d-%4d wall=%8.3fs cpu=%s cpu_wall=%s gc=%d major=%d minor=%d gc_time=%s live=%d pages=%d allocated=%d freed=%d',
        first,
        index,
        wall_elapsed,
        cpu_elapsed ? format('%.3fs', cpu_elapsed) : 'n/a',
        cpu_ratio ? format('%.3f', cpu_ratio) : 'n/a',
        delta(current_gc, started_gc, :count),
        delta(current_gc, started_gc, :major),
        delta(current_gc, started_gc, :minor),
        gc_time_delta ? format('%.3f', gc_time_delta) : 'n/a',
        current_gc[:heap_live_slots].to_i,
        current_gc[:heap_allocated_pages].to_i,
        delta(current_gc, started_gc, :total_allocated_objects),
        delta(current_gc, started_gc, :total_freed_objects)
      )
    )

    %w[executor.execute model.recenter entity_copy.copy_instance].each do |label|
      stat = @bucket_stats[[label, bucket]] || { count: 0, total: 0.0, max: 0.0 }
      average_ms = stat[:count].positive? ? stat[:total] * 1000.0 / stat[:count] : 0.0
      log(
        format(
          '  HOT %-27s count=%4d total=%8.3fs avg=%8.3fms max=%8.3fms',
          label,
          stat[:count],
          stat[:total],
          average_ms,
          stat[:max] * 1000.0
        )
      )
    end
  end

  def method_visibility(owner, method_name)
    return :private if owner.private_method_defined?(method_name)
    return :protected if owner.protected_method_defined?(method_name)

    :public
  end

  def direct_method_defined?(owner, method_name)
    owner.instance_methods(false).include?(method_name) ||
      owner.private_instance_methods(false).include?(method_name) ||
      owner.protected_instance_methods(false).include?(method_name)
  end

  def patch_instance_method(owner, method_name, label, execute_boundary: false)
    original = owner.instance_method(method_name)
    visibility = method_visibility(owner, method_name)
    direct = direct_method_defined?(owner, method_name)

    owner.send(:define_method, method_name) do |*args, **kwargs, &block|
      IndoorGMLCellSpaceBatchGrowthProbe.begin_execute if execute_boundary
      IndoorGMLCellSpaceBatchGrowthProbe.measure(label) do
        bound = original.bind(self)
        if kwargs.empty?
          bound.call(*args, &block)
        else
          bound.call(*args, **kwargs, &block)
        end
      end
    ensure
      IndoorGMLCellSpaceBatchGrowthProbe.finish_execute if execute_boundary
    end
    owner.send(visibility, method_name)
    @patches << [owner, method_name, original, visibility, direct]
  end

  def patch_singleton_method(object, method_name, label)
    owner = object.singleton_class
    original = owner.instance_method(method_name)
    visibility = method_visibility(owner, method_name)
    direct = direct_method_defined?(owner, method_name)

    owner.send(:define_method, method_name) do |*args, **kwargs, &block|
      IndoorGMLCellSpaceBatchGrowthProbe.measure(label) do
        bound = original.bind(self)
        if kwargs.empty?
          bound.call(*args, &block)
        else
          bound.call(*args, **kwargs, &block)
        end
      end
    end
    owner.send(visibility, method_name)
    @patches << [owner, method_name, original, visibility, direct]
  end

  def restore_patches
    @patches.reverse_each do |owner, method_name, original, visibility, direct|
      if direct
        owner.send(:define_method, method_name, original)
        owner.send(visibility, method_name)
      elsif direct_method_defined?(owner, method_name)
        owner.send(:remove_method, method_name)
      end
    rescue StandardError => e
      log("RESTORE ERROR #{owner}##{method_name} #{e.class}: #{e.message}")
    end
    @patches = []
  end

  def install_probes(indoor_model)
    core = ULOL::Indoor3DGmlModeler::IndoorCore
    patch_instance_method(
      core::CellSpaceConversionExecutor,
      :execute,
      'executor.execute',
      execute_boundary: true
    )
    patch_singleton_method(
      indoor_model,
      :recenter_cell_space_geometry,
      'model.recenter'
    )
    patch_singleton_method(
      core::EntityCopyHelper,
      :copy_instance,
      'entity_copy.copy_instance'
    )
  end

  def run
    File.write(LOG_PATH, '')
    model = Sketchup.active_model
    raise "Growth probe requires an empty model: root_entities=#{model.entities.length}" unless model.entities.length.zero?

    core = ULOL::Indoor3DGmlModeler::IndoorCore
    indoor_model = core::IndoorModel.current
    raise 'IndoorModel.current unavailable' unless indoor_model

    @current_index = 0
    @execute_count = 0
    @bucket_stats = {}
    @patches = []

    log("BATCH GROWTH START count=#{COUNT} bucket_size=#{BUCKET_SIZE}")
    install_probes(indoor_model)

    stress_probe = File.join(__dir__, 'cell_space_batch_stress_probe.rb')
    raise "Missing stress probe: #{stress_probe}" unless File.file?(stress_probe)
    load stress_probe

    log("BATCH GROWTH COMPLETE executed=#{@execute_count}")
    @execute_count == COUNT
  rescue StandardError => e
    log("BATCH GROWTH ERROR #{e.class}: #{e.message}")
    Array(e.backtrace).each { |line| log("BACKTRACE #{line}") }
    false
  ensure
    restore_patches
  end
end

IndoorGMLCellSpaceBatchGrowthProbe.run

nil
