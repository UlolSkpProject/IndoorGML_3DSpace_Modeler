# frozen_string_literal: true

require 'minitest/autorun'
require 'tempfile'

module Geom
  class Point3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def distance(other)
      Math.sqrt((x - other.x)**2 + (y - other.y)**2 + (z - other.z)**2)
    end
  end

  class Vector3d
    attr_reader :x, :y, :z

    def initialize(x, y, z)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def length
      Math.sqrt(x**2 + y**2 + z**2)
    end

    def normalize!
      len = length
      return self if len <= 0.0

      @x /= len
      @y /= len
      @z /= len
      self
    end
  end
end unless defined?(Geom::Point3d)

require_relative '../indoor3d/export/val3dity_exported_solid_snapshot_reader'

module ULOL
  module Indoor3DGmlModeler
    module IndoorCore
      module IndoorGmlConverter
        class Val3dityExportedSolidSnapshotReaderTest < Minitest::Test
          def test_reads_cell_space_solid_faces
            snapshot = read_snapshot(<<~XML)
              <core:IndoorFeatures xmlns:core="urn:test:core" xmlns:gml="http://www.opengis.net/gml/3.2">
                <core:CellSpace gml:id="cell_A">
                  <core:cellSpaceGeometry>
                    <gml:Solid>
                      <gml:surfaceMember>
                        <gml:Polygon>
                          <gml:exterior>
                            <gml:LinearRing>
                              <gml:pos>0 0 0</gml:pos>
                              <gml:pos>1 0 0</gml:pos>
                              <gml:pos>0 1 0</gml:pos>
                              <gml:pos>0 0 0</gml:pos>
                            </gml:LinearRing>
                          </gml:exterior>
                        </gml:Polygon>
                      </gml:surfaceMember>
                    </gml:Solid>
                  </core:cellSpaceGeometry>
                </core:CellSpace>
              </core:IndoorFeatures>
            XML

            assert_equal ['cell_A'], snapshot.keys
            face = snapshot['cell_A'][:faces].first
            assert_equal false, snapshot['cell_A'][:unsupported]
            assert_equal 3, face[:points].length
            assert_equal 1, face[:triangles].length
            assert_in_delta 1.0, face[:normal].length, 0.000001
          end

          def test_converts_declared_meter_coordinates_to_inches
            snapshot = read_snapshot(<<~XML)
              <core:IndoorFeatures xmlns:core="urn:test:core" xmlns:gml="http://www.opengis.net/gml/3.2">
                <core:GeneralSpace gml:id="cell_m">
                  <gml:Solid srsName="local-m">
                    <gml:surfaceMember>
                      <gml:Polygon>
                        <gml:exterior>
                          <gml:LinearRing>
                            <gml:pos>0 0 0</gml:pos>
                            <gml:pos>0.0254 0 0</gml:pos>
                            <gml:pos>0 0.0254 0</gml:pos>
                          </gml:LinearRing>
                        </gml:exterior>
                      </gml:Polygon>
                    </gml:surfaceMember>
                  </gml:Solid>
                </core:GeneralSpace>
              </core:IndoorFeatures>
            XML

            points = snapshot['cell_m'][:faces].first[:points]
            assert_in_delta 1.0, points[1].x, 0.000001
            assert_in_delta 1.0, points[2].y, 0.000001
          end

          private

          def read_snapshot(xml)
            file = Tempfile.new(['val3dity-reader', '.gml'])
            file.write(xml)
            file.close
            Val3dityExportedSolidSnapshotReader.new(file.path, numeric_epsilon: 0.000001).read
          ensure
            file&.unlink
          end
        end
      end
    end
  end
end
