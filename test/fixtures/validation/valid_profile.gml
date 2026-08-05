<?xml version="1.0" encoding="UTF-8"?>
<core:IndoorFeatures xmlns="http://www.opengis.net/indoorgml/1.0/core"
  xmlns:core="http://www.opengis.net/indoorgml/1.0/core"
  xmlns:navi="http://www.opengis.net/indoorgml/1.0/navigation"
  xmlns:gml="http://www.opengis.net/gml/3.2"
  xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
  xmlns:xlink="http://www.w3.org/1999/xlink"
  gml:id="IF_001">
  <gml:boundedBy xsi:nil="true"/>
  <core:primalSpaceFeatures>
    <core:PrimalSpaceFeatures gml:id="PS1">
      <core:cellSpaceMember>
        <navi:GeneralSpace gml:id="cell_A">
          <gml:description>storey=F01</gml:description>
          <gml:name>Cell-A</gml:name>
          <gml:boundedBy xsi:nil="true"/>
          <core:cellSpaceGeometry>
            <core:Geometry3D>
              <gml:Solid gml:id="solid_cell_A" srsName="urn:ulol:def:crs:local-m" srsDimension="3" axisLabels="x y z" uomLabels="m m m">
                <gml:exterior>
                  <gml:Shell gml:id="shell_cell_A">
                    <gml:surfaceMember>
                      <gml:Polygon gml:id="polygon_0_cell_A" srsName="urn:ulol:def:crs:local-m" srsDimension="3" axisLabels="x y z" uomLabels="m m m">
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
                  </gml:Shell>
                </gml:exterior>
              </gml:Solid>
            </core:Geometry3D>
          </core:cellSpaceGeometry>
          <core:duality xlink:href="#state_A"/>
          <navi:class>Space</navi:class>
          <navi:function>Room</navi:function>
          <navi:usage>Room</navi:usage>
        </navi:GeneralSpace>
      </core:cellSpaceMember>
    </core:PrimalSpaceFeatures>
  </core:primalSpaceFeatures>
  <core:multiLayeredGraph>
    <core:MultiLayeredGraph gml:id="MG1">
      <core:spaceLayers gml:id="SL1">
        <core:spaceLayerMember>
          <core:SpaceLayer gml:id="IS1">
            <core:nodes gml:id="N1">
              <core:stateMember>
                <core:State gml:id="state_A">
                  <gml:description>storey=F01</gml:description>
                  <gml:name>State-A</gml:name>
                  <core:duality xlink:href="#cell_A"/>
                  <core:geometry>
                    <gml:Point gml:id="P0" srsName="urn:ulol:def:crs:local-m" srsDimension="3" axisLabels="x y z" uomLabels="m m m">
                      <gml:pos>0.2 0.2 0</gml:pos>
                    </gml:Point>
                  </core:geometry>
                </core:State>
              </core:stateMember>
            </core:nodes>
            <core:edges gml:id="E1"/>
          </core:SpaceLayer>
        </core:spaceLayerMember>
      </core:spaceLayers>
    </core:MultiLayeredGraph>
  </core:multiLayeredGraph>
</core:IndoorFeatures>
