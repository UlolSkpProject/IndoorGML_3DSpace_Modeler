# frozen_string_literal: true

require_relative 'lvn_stage_detail_profile_benchmark'

# Adds pair-result-cache counters to the ordinary stage-detail benchmark without
# enabling the expensive deep-reuse fingerprint/allocation probe.
module LvnPairResultCacheBenchmark
  module PairResultCacheStatsExtension
    private

    def normalize_entity(entity)
      super
    ensure
      profile = @local_vertex_normalizer_debug_profile
      stats = profile&.dig(
        :performance_counters,
        :triangle_intersection_pair_result_cache
      )
      if profile && stats
        hotspot = profile[:hotspot_detail] ||= {}
        intersection = hotspot[:intersection] ||= {}
        Hash(stats).each do |key, value|
          next unless value.is_a?(Numeric)

          intersection["pair_result_cache_#{key}".to_sym] = value
        end
      end
    end
  end

  module_function

  def run(**options)
    LvnStageDetailProfileBenchmark.send(:install_stage_extensions!)
    klass = ULOL::Indoor3DGmlModeler::IndoorCore::LocalVertexNormalizer
    unless klass.ancestors.include?(PairResultCacheStatsExtension)
      klass.prepend(PairResultCacheStatsExtension)
    end
    LvnStageDetailProfileBenchmark.run(**options)
  end
end
