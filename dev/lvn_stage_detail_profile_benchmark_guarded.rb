# frozen_string_literal: true

require_relative 'lvn_runtime_preflight'
require_relative 'lvn_stage_detail_profile_benchmark'

# Guarded entrypoint for the stage-detail benchmark. Runtime verification runs
# before the benchmark installs profiler extensions, validates model targets, or
# starts a SketchUp operation.
module LvnStageDetailProfileBenchmarkRuntimeGuard
  def run(...)
    core = ULOL::Indoor3DGmlModeler::IndoorCore
    report = LvnRuntimePreflight.verify!(
      target_class: core::LocalVertexNormalizer,
      constant_root: core
    )
    LvnRuntimePreflight.print_report(report)
    super
  end
end

benchmark_singleton = LvnStageDetailProfileBenchmark.singleton_class
unless benchmark_singleton.ancestors.include?(
  LvnStageDetailProfileBenchmarkRuntimeGuard
)
  benchmark_singleton.prepend(LvnStageDetailProfileBenchmarkRuntimeGuard)
end

nil
