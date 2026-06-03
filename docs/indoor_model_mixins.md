# IndoorModel Mixin 책임 정리

`IndoorModel`은 하나의 런타임 조정자이지만, 관련 기능을 작은 파일로 나누기 위해 여러 mixin으로 분리되어 있다. 새 메서드는 단순히 어떤 객체를 다루는지가 아니라, 그 메서드가 존재하는 이유를 기준으로 담당 mixin에 배치한다.

## RuntimeSupport

런타임 컬렉션 구성과 공통 저수준 helper를 담당한다.

- 현재 SketchUp 모델에서 IndoorGML 런타임 데이터를 재구성한다.
- `cell_spaces`, `states`, `transitions`, adjacency pair, cell pair별 transition 같은 registry 기반 컬렉션을 reset/rebind한다.
- `AttributeSerializer`를 통해 IndoorGML attribute를 기록한다.
- `sync`, `erase_guard`, `indoor_feature`, `converted_group?`, `find_cell_space_for_entity` 같은 공통 helper를 제공한다.
- lock/unlock 처리는 `EditorSession`에 위임한다.

## SceneGroups

IndoorGML space feature group의 SketchUp scene 배치와 좌표 helper를 담당한다.

- `IndoorGML_PrimalSpaceFeatures` group을 생성, 탐색, 보호한다.
- root/primal `EntitiesObserver`와 `SpaceFeaturesObserver`를 부착한다.
- CellSpace group이 primal group 아래에 위치하도록 배치한다.
- root 또는 active context에 있는 group을 primal group 아래로 복제/이동한다.
- CellSpace geometry의 원점을 재중심화한다.
- CellSpace와 State runtime position 사이의 local/world 좌표 변환을 관리한다.
- managed space feature group의 origin construction point와 group constraint를 관리한다.

## FeatureLifecycle

IndoorGML runtime feature의 생성, 변경, 삭제를 담당한다.

- solid SketchUp group을 `CellSpace` runtime 객체로 변환한다.
- CellSpace type/category를 변경하고, name/material/category text/attribute/adjacency/lock 상태를 갱신한다.
- CellSpace geometry 변경, close, erase 같은 CellSpace observer callback을 처리한다.
- CellSpace에 대응되는 dual `State` runtime 객체를 생성하고 등록한다.
- CellSpace, State, 관련 Transition을 lifecycle 흐름에 맞게 삭제한다.
- CellSpace별 observer를 부착하고 primal entities observer에 CellSpace entity를 track한다.

## Topology

CellSpace adjacency와 Transition runtime 동기화를 담당한다.

- `AdjacencyService`를 통해 특정 CellSpace의 adjacency를 동기화한다.
- 인접한 CellSpace pair에 대해 `Transition` runtime 객체를 생성하거나 갱신한다.
- adjacency가 사라지거나 State가 삭제될 때 관련 Transition을 제거한다.
- 각 State가 가진 transition 목록을 최신 상태로 유지한다.
- runtime refresh 시 CellSpace adjacency를 기반으로 Transition runtime 데이터를 다시 만든다.

## ObserverRouting

SketchUp observer event를 IndoorModel 동작으로 연결하는 라우팅을 담당한다.

- root entity added/removed event를 처리한다.
- primal group entity added/removed event를 처리한다.
- CellSpace 추가 event를 observer 부착, runtime refresh, adjacency 동기화로 연결한다.
- EditMode에서 새로 만들어진 solid group을 `GeneralSpace`로 자동 변환한다.
- managed space feature group의 변경 및 erase event를 처리한다.

## EntityRelocation

IndoorGML entity를 올바른 SketchUp entity collection으로 이동하는 작업을 담당한다.

- IndoorGML entity를 적절한 target entities collection으로 relocate한다.
- entity definition, transform, name, material, IndoorGML attribute를 복사한다.
- root context와 managed group context 사이에서 이동할 때 world transform을 보존한다.
- relocation guard를 사용해 observer callback이 같은 이동을 재귀적으로 다시 처리하지 않게 한다.

## EditorControl

EditMode와 editor UI 제어를 담당한다.

- `EditorSession`을 통해 EditMode를 시작하고 종료한다.
- EditMode용 selection observer를 부착/해제한다.
- overlay radius 설정을 외부에서 조절할 수 있게 한다.
- EditMode dialog action을 처리한다.
- 선택된 CellSpace snapshot, 선택 CellSpace type/category 변경을 처리한다.
- 사용자 확인을 받은 뒤 모든 IndoorGML 요소를 삭제한다.
- active path enforcement와 lock policy는 `EditorSession`에 위임한다.
