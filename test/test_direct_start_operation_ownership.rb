# frozen_string_literal: true

require 'minitest/autorun'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      class DirectStartOperationOwnershipTest < Minitest::Test
        ALLOWED_DIRECT_OWNERS = %w[
          indoor3d/application/indoor_model/runtime_support.rb
          indoor3d/application/local_vertex_normalizer/legacy_kernel.rb
        ].freeze

        def test_only_declared_operation_owners_call_start_operation_directly
          root = File.expand_path('..', __dir__)
          direct_call_files = Dir.glob(File.join(root, 'indoor3d/**/*.rb')).filter_map do |path|
            source = File.read(path)
            next unless source.match?(/\bstart_operation\s*\(/)

            path.delete_prefix("#{root}/").tr('\\', '/')
          end

          assert_equal ALLOWED_DIRECT_OWNERS.sort, direct_call_files.sort
        end

        def test_indoor_model_integration_does_not_delegate_operation_ownership_to_lvn
          root = File.expand_path('..', __dir__)
          integration_files = %w[
            indoor3d/application/indoor_model/local_vertex_normalization.rb
            indoor3d/application/indoor_model/local_grid_coordinate_v2.rb
          ]

          integration_files.each do |relative_path|
            source = File.read(File.join(root, relative_path))
            refute_match(/LocalVertexNormalizer\.normalize\(.*manage_operation:\s*true/m, source)
          end

          integration = File.read(
            File.join(
              root,
              'indoor3d/application/indoor_model/local_vertex_normalization.rb'
            )
          )
          assert_includes integration, "with_indoor_model_operation('Normalize IndoorGML local vertices')"
          assert_includes integration, 'manage_operation: false'
        end
      end
    end
  end
end
