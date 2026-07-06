# POI 정리

## 개념

POI는 `Point of Interest`의 약자로, 사용자가 관심을 가질 만한 위치나 대상을 뜻한다. 실내 모델에서는 안내 데스크, 매장, 키오스크, 화장실, 소화기, 표지판, 엘리베이터 버튼 위치처럼 공간 안에 있는 의미 있는 지점이나 객체를 POI로 볼 수 있다.

POI는 `CellSpace`와 다르다. `CellSpace`는 방, 복도, 문, 계단처럼 공간 자체를 표현하고, POI는 그 공간 안이나 근처의 의미 있는 점 또는 객체를 표현한다. 따라서 POI를 CellSpace type 목록에 넣는 것은 적절하지 않다.

## IndoorGML 1.0 기준

IndoorGML 1.0 schema에는 `POI`, `Poi`, `PointOfInterest` 같은 공식 element가 없다. 공식적으로 직접 제공되는 주요 객체는 `CellSpace`, `CellSpaceBoundary`, `State`, `Transition`, `SpaceLayer`, `Route`, `RouteNode`, `RouteSegment` 등이다.

IndoorGML 안에서 POI와 비슷한 정보를 연결해야 한다면 `CellSpace` 또는 `CellSpaceBoundary`의 `externalReference`를 통해 외부 POI 데이터베이스나 별도 GIS layer를 참조하는 방식이 가장 표준에 가깝다.

즉 POI 자체를 IndoorGML 본체의 공식 객체로 export하는 것은 현재 범위에서는 하지 않는다.

## Legacy Project의 POI

legacy project에서 POI는 IndoorGML 공식 element가 아니라, SketchUp `ComponentInstance`에 의미 정보를 붙인 application-specific runtime 객체다.

legacy `Poi` 객체가 가진 항목:

- `id`
- `name`
- `component`
- `poi_type1`
- `poi_type2`
- `poi_type3`
- `position`
- `visible`

legacy UI에서 설정 가능한 항목:

- POI 표시/숨김
- 이름
- POI Type 1
- POI Type 2
- POI Type 3
- X 좌표
- Y 좌표
- Z 좌표

legacy POI Type 1에 들어갈 수 있는 값:

- `place`
- `things`
- `retail or services`
- `safety`
- `event`

legacy POI Type 2에 들어갈 수 있는 값:

- `pedestrian`
- `private`
- `relexation`

legacy POI Type 3에 들어갈 수 있는 값:

- `stairs`
- `slope way`
- `lobby`

Ruby runtime의 초기값은 `NONE`이다. legacy 코드에서는 Type 1, Type 2, Type 3의 값을 별도 enum으로 검증하지 않고 문자열로 저장한다.

legacy 생성 규칙:

- 선택된 entity가 `Sketchup::ComponentInstance`일 때만 POI를 생성한다.
- 이미 등록된 component에는 중복 POI를 만들지 않는다.
- 이름은 `poi_0`, `poi_1`처럼 생성 순서로 붙인다.
- 위치는 component의 bounds center 또는 transformation origin을 사용한다.
- runtime 목록은 `@pois` 배열로 관리한다.

legacy update 규칙:

- dialog에서 name, visible, type1, type2, type3, x, y, z를 받아 POI runtime 객체를 갱신한다.
- x, y, z 변경 시 component transformation도 함께 이동한다.

## 우리 프로젝트에서의 관리 방향

POI는 현재 미구현으로 남긴다. 구현한다면 IndoorGML 본체 객체가 아니라 별도 runtime feature로 관리한다.

권장 runtime 속성:

- `id`
- `name`
- `position`
- `category`
- `related_cell_space_id`
- `level`
- `visible`
- `sketchup_entity`

권장 SketchUp 표현:

- point/component/overlay 중 하나로 표현한다.
- CellSpace type과는 분리한다.
- 특정 CellSpace에 속하는 경우 `related_cell_space_id`로 연결한다.

권장 export 방향:

- 1차 구현에서는 IndoorGML export 대상에서 제외한다.
- QGIS 호환을 우선하면 별도 `poi.geojson` 또는 `poi.gpkg` point layer로 export한다.
- IndoorGML 내부 연결이 필요하면 `CellSpace.externalReference`로 외부 POI 정보를 참조한다.
- POI geometry까지 IndoorGML XML 안에 직접 넣고 싶다면 custom namespace 또는 별도 application schema가 필요하다.

## 현재 결정

- POI는 미구현으로 유지한다.
- AnchorNodeMarker와 마찬가지로 legacy 참고 항목으로만 남긴다.
- 현재 IndoorGML export에는 포함하지 않는다.
- CellSpace type 목록에는 포함하지 않는다.
