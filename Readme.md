# IndoorGML 3D Modeler

> SketchUp 2026에서 solid group을 IndoorGML CellSpace로 변환하고, dual graph를 편집·검증·Export하는 Ruby Extension입니다.

![IndoorGML 3D Modeler](docs/images/preview.png)

![Version](https://img.shields.io/badge/version-1.0.3-blue)
![SketchUp](https://img.shields.io/badge/SketchUp-2026-brightgreen)
![IndoorGML](https://img.shields.io/badge/IndoorGML-1.0.3-orange)
![val3dity](https://img.shields.io/badge/val3dity-2.2.0-lightgrey)

## Overview

IndoorGML 3D Modeler는 SketchUp 모델 안의 manifold solid group을 IndoorGML `CellSpace` 런타임 객체로 관리하고, 인접한 CellSpace 사이의 `State`/`Transition` dual graph를 자동으로 동기화합니다.

주요 목표는 다음과 같습니다.

- SketchUp group 기반 3D 공간을 IndoorGML 1.0 Core/Navigation XML로 Export
- CellSpace 타입, 카테고리, 층 정보를 Edit Mode에서 편집
- State/Transition을 SketchUp geometry가 아닌 Overlay로 표시
- `.skp` 저장 후 다시 열어도 CellSpace runtime을 attribute에서 복원
- val3dity v2.2.0으로 임시 GML을 검증하고 HTML report 제공

## Project Scope

이 프로젝트는 연구보고서와 legacy extension이 목표로 했던 전체 기능을 모두 복원하지 않습니다. 대신 실제 작업 경로인 **CellSpace -> State -> Transition -> Validation -> Export** 흐름에 집중합니다.

### 지원

- Solid 기반 3D CellSpace 생성
- `GeneralSpace`, `TransitionSpace`, `ConnectionSpace`, `AnchorSpace`, `CellSpace`
- `Room`, `Door`, `Stair`, `Elevator`, `ExteriorDoor`, `Window` 분류
- CellSpace별 State 생성
- 인접 CellSpace 간 Transition 자동 생성
- `.skp` 저장 후 재오픈 시 IndoorGML 정보 복원
- Edit Mode, visibility filter, geometry toggle, State/Transition Overlay
- val3dity 기반 Validation과 GML Export

### 미지원

- IndoorGML Import
- POI 입력·편집·Export
- `CellSpaceBoundary`, `NavigableBoundary`
- Multi-Layer와 `InterLayerConnection`
- `Route`, `RouteNode`, `RouteSegment`
- legacy AnchorNode 방식의 외부 지도 좌표계 연계
- Transition 방향, 접근 조건, 사용자 지정 통행 비용
- IndoorGML 1.0.3 전체 Conformance Class

## Version Policy

코드에서는 확장/저장 포맷 버전과 OGC schema 버전을 분리합니다.

| 항목 | 값 | 정의 |
| --- | --- | --- |
| Extension/storage version | `1.0.3` | `Definition::INDOOR_GML_VERSION` |
| Extension package version | `1.0.3` | `Definition::EXTENSION_VERSION` |
| IndoorGML XML schema version | `1.0` | `Definition::INDOOR_GML_SCHEMA_VERSION` |
| Validator runtime | `val3dity-windows-x64-v2.2.0` | `Val3dityRunner::VENDOR_ROOT` |

`schemas.opengis.net/indoorgml/1.0.3/*.xsd`는 존재하지 않으므로 Export XML의 namespace와 `xsi:schemaLocation`은 공식 IndoorGML 1.0 schema 경로를 사용합니다. 반면 SketchUp attribute에 기록되는 extension/storage version은 `1.0.3`입니다.

## Installation

### RBZ 설치

1. Releases에서 `IndoorGML_3D_Modeler-x.x.x.rbz`를 내려받습니다.
2. SketchUp 2026에서 `Extension Manager`를 엽니다.
3. `Install Extension`으로 `.rbz`를 선택합니다.
4. SketchUp을 재시작합니다.

### 개발용 직접 배치

SketchUp plugin 경로에 다음 구조로 배치합니다.

```text
Plugins/
├── indoor3d.rb
└── indoor3d/
```

현재 진입 파일은 [indoor3d.rb](indoor3d.rb)이고, 실제 extension loader는 [indoor3d/core.rb](indoor3d/core.rb)를 로드합니다.

## Quick Start

### 1. Solid Group 준비

SketchUp에서 CellSpace로 변환할 공간을 solid group 또는 component instance로 모델링합니다. 변환 대상은 manifold solid여야 합니다.

![Solid Group 준비](docs/images/step1_solid_group.png)

### 2. CellSpace 생성

변환할 group을 선택한 뒤 `Create CellSpace`를 실행합니다.

![Create CellSpace 결과](docs/images/step2_create_cellspace.png)

변환된 객체는 `IndoorGML_PrimalSpaceFeatures` group 아래로 이동되며, 대응되는 `State`가 1:1로 생성됩니다. 선택 객체가 이미 CellSpace이면 재변환하지 않습니다.
여러 group을 한 번에 선택한 경우 변환 가능한 항목만 CellSpace로 생성하고, 조건을 만족하지 못한 항목은 결과 메시지의 `Failed` 목록에 group 이름 또는 entity id와 함께 표시합니다.

### 3. Edit Mode 진입

`Edit CellSpace Property`를 실행하면 Edit Mode가 켜지고, CellSpace 편집 dialog와 viewport overlay가 활성화됩니다.

![EditMode 진입](docs/images/step3_edit_mode.png)

Edit Mode에서는 CellSpace 이동, 타입 변경, 층 변경, visibility filter, geometry 표시 토글, State/Transition overlay 확인을 수행합니다.

### 4. CellSpace 편집

CellSpace를 이동하거나 타입/층 정보를 변경하면 runtime attribute와 topology가 갱신됩니다. 인접 관계가 생기거나 사라지면 Transition도 자동 생성·삭제됩니다.

![CellSpace 편집](docs/images/step4_edit_cellspace.png)

### 5. Export 또는 Validity Check

- `Export GML`: 현재 모델을 바로 `.gml`로 저장합니다.
- `Check Validity`: 임시 GML을 만들고 val3dity로 검증한 뒤 report를 표시합니다. 검증 결과를 확인한 뒤 별도 저장이 필요하면 `Export GML`을 실행합니다.

## Toolbar Commands

| Command | Icon | 동작 |
| --- | --- | --- |
| Create CellSpace | ![](indoor3d/assets/icons/create_cellspace.svg) | 선택한 solid group을 CellSpace로 변환 |
| Edit CellSpace Property | ![](indoor3d/assets/icons/edit_cellspace_property.svg) | Edit Mode 시작/종료 |
| Change CellSpace Type | ![](indoor3d/assets/icons/change_cellspace_type.svg) | 선택한 CellSpace 타입/카테고리 변경 |
| Show/Hide Geometry | ![](indoor3d/assets/icons/toggle_geometry.svg) | CellSpace geometry 표시 토글 |
| Show/Hide State/Link Overlay | ![](indoor3d/assets/icons/toggle_dual_overlay.svg) | State/Transition overlay 표시 토글 |
| Dual Overlay Scale | ![](indoor3d/assets/icons/dual_overlay_scale.svg) | State 크기 조절 |
| Export GML | ![](indoor3d/assets/icons/export_gml.svg) | IndoorGML 1.0 GML 파일 저장 |
| Check Validity | ![](indoor3d/assets/icons/check_validity.svg) | 임시 GML 생성, val3dity 실행, report 생성 |

Context menu는 상황에 따라 `Edit IndoorGML`, `Change CellSpace Type` 항목을 추가합니다.

## CellSpace Types

현재 선택 가능한 CellSpace 타입과 기본 카테고리는 다음과 같습니다.

| CellSpace type | Category | Export tag |
| --- | --- | --- |
| `GeneralSpace` | `Room` | `navi:GeneralSpace` |
| `TransitionSpace` | `Stair` | `navi:TransitionSpace` |
| `TransitionSpace` | `Elevator` | `navi:TransitionSpace` |
| `ConnectionSpace` | `Door` | `navi:ConnectionSpace` |
| `AnchorSpace` | `ExteriorDoor` | `navi:AnchorSpace` |
| `CellSpace` | `Window` | `Core:CellSpace` |

Navigation semantic code는 [indoor3d/domain/navigation_semantic.rb](indoor3d/domain/navigation_semantic.rb)에 정의되어 있으며, 기본값은 IndoorGML Annex D code space를 사용합니다. CellSpace attribute에 navigation semantic override 값이 있으면 export 시 override가 우선합니다.

## Tag-Based Classification

일부 SketchUp tag 이름은 CellSpace 타입과 카테고리로 자동 매핑됩니다.

| Tag suffix | CellSpace |
| --- | --- |
| `MV_RM_01` | `TransitionSpace / Elevator` |
| `MV_RM_02` | `TransitionSpace / Stair` |
| `IP_RM_05` | `TransitionSpace / Stair` |
| `IP_RM_23` | `GeneralSpace / Room` |
| `RM_DR` | `ConnectionSpace / Door` |
| `RM_WD` | `CellSpace / Window` |

Tag 이름 앞부분은 `F01F02_` 또는 `B01F01_` 같은 층 패턴이어야 합니다. 예를 들어 `F01F02_MV_RM_02`는 `TransitionSpace / Stair`로 해석됩니다. Tag로 타입이 결정된 선택 항목은 Edit Mode dialog에서 classification이 잠길 수 있습니다.

## Storey

CellSpace는 `storey` attribute를 가집니다. 기본값은 `F01`입니다.

지원 형식:

- `F01`, `F02`, ... `F99`
- `B01`, `B02`, ... `B99`
- `F01~F03` 같은 range

층 range 편집은 `TransitionSpace` 중 `Stair`, `Elevator` 카테고리에 허용됩니다. 일반 CellSpace는 첫 번째 층 값만 저장합니다.

Edit Mode dialog는 Storey filter와 Type filter를 제공하여 특정 층 또는 타입만 표시할 수 있습니다.

![Dialog 요약](docs/images/dialog_summary.png)

![Dialog CellSpace](docs/images/dialog_cellspace.png)

## Edit Mode Behavior

Edit Mode는 SketchUp scene 상태를 보호하면서 IndoorGML 편집을 수행하기 위한 작업 모드입니다.

주요 동작:

- `IndoorGML_PrimalSpaceFeatures`와 CellSpace lock 상태를 편집 상태에 맞게 조정
- 선택 변경을 감지하여 dialog snapshot 갱신
- CellSpace type/category/storey 변경
- Solid group 선택 시 dialog에서 CellSpace 변환
- Storey/Type visibility filter 적용
- State/Transition overlay invalidation
- 모든 IndoorGML 요소 삭제
- validation report에서 오류 CellSpace focus 및 오류 요소 재검사

Edit Mode dialog의 `편집 완료`는 Edit Mode를 종료하고, 필요한 경우 PrimalGroup child 정규화를 수행합니다.

## Topology and Transition Policy

CellSpace 인접 관계는 `AdjacencyService`가 동기화합니다.

현재 Transition 생성 정책:

- 두 CellSpace가 모두 valid여야 합니다.
- 두 CellSpace 모두 valid dual State를 가져야 합니다.
- geometry adjacency detector가 인접 축을 찾으면 Transition을 허용합니다.
- CellSpace 타입 또는 `x/y/z` 방향에 따른 추가 차단 정책은 현재 없습니다.

즉, 현재 정책은 `transition_allowed_for_axis?(adjacency_axis)`가 `nil`이 아닌 축을 받으면 Transition을 생성하는 구조입니다. 이 정책은 [docs/architecture_decisions.md](docs/architecture_decisions.md)에 명시되어 있습니다.

Window의 경우 NavigableSpace가 아닌 CellSpace로, State는 생성되지만 Transition은 생기지 않습니다.

성능 관련 구현:

- CellSpace별 incremental sync
- dirty queue와 `UI.start_timer`를 사용한 지연 topology sync
- bounding box 후보 필터
- face-level adjacency 검사
- 전체 동기화 시 20,000 pair 이상이면 worker thread 병렬 처리

## Persistence

IndoorGML runtime 데이터는 SketchUp attribute dictionary `IndoorGml`에 저장됩니다.

주요 저장 값:

- `feature`
- `name`
- `indoor_gml_version`
- `id`
- `cell_type`
- `category_code`
- `storey`
- `duality_state_id`
- navigation semantic override fields

파일을 다시 열면 `RuntimeRestorer`가 PrimalGroup 아래의 CellSpace attribute를 읽어 `CellSpace`와 `State`를 복원합니다. Transition은 저장된 선형 geometry가 아니라 CellSpace adjacency를 다시 계산해 runtime에서 재구성합니다.

## Export

Exporter는 현재 SketchUp 모델을 root context 기준으로 정규화한 뒤 `ExportSnapshot`을 만들고, `GmlWriter`가 IndoorGML XML을 생성합니다.

Export 구조:

- root: `core:IndoorFeatures`
- `core:primalSpaceFeatures`
- `core:PrimalSpaceFeatures`
- `core:cellSpaceMember`
- `core:multiLayeredGraph`
- 단일 `core:SpaceLayer` (`IS1`)
- `core:nodes` 아래 `core:State`
- `core:edges` 아래 `core:Transition`

GML 좌표:

- SketchUp 내부 좌표는 inch입니다.
- export 시 모델의 `UnitsOptions/LengthUnit`에 따라 `in`, `ft`, `mm`, `cm`, `m` 중 하나로 변환합니다.
- `gml:Point`, `gml:LineString`, `gml:Solid`, `gml:Polygon`에는 `srsName`, `srsDimension`, `axisLabels`, `uomLabels`를 기록합니다.

지원하지 않는 IndoorGML 요소:

| 요소 | 상태 |
| --- | --- |
| 다중 `SpaceLayer` | 미지원, 단일 `IS1`만 생성 |
| `CellSpaceBoundary` | 미출력 |
| `NavigableBoundary` | 미출력 |
| `InterLayerConnection` | 미출력 |
| `Route`, `RouteNode`, `RouteSegment` | 미지원 |
| POI | application-specific 후보, 현재 export 제외 |
| legacy AnchorNode | application-specific 후보, 현재 export 제외 |

## Validity Check

`Check Validity`는 다음 순서로 동작합니다.

1. 현재 Edit Mode가 켜져 있으면 종료합니다.
2. `tmp/indoorgml/validation-runs/run-*` 아래 isolated workspace를 만듭니다.
3. 임시 `input.gml`을 생성합니다.
4. bundled `val3dity.exe`를 실행합니다.
5. stdout progress를 dialog에 표시합니다.
6. val3dity report JSON을 UTF-8로 정규화합니다.
7. 701/704 overlap error를 SketchUp geometry 기준으로 재검사합니다.
8. 최종 JSON과 HTML report를 생성합니다.

검증 report에서 가능한 작업:

- report 열기
- 검증 실패 CellSpace focus
- 오류 요소 Edit Mode 진입
- focus된 오류 요소만 재검사

주의: bundled val3dity runtime은 Windows x64용입니다. 현재 validation은 Windows에서만 지원됩니다.

## Legacy and Stabilization Notes

현재 프로젝트는 legacy `une-young/indoorgml-modeler`의 모든 UI 기능을 복구한 것이 아니라, 저장·복원, topology, export, validation을 실제 사용 가능한 흐름으로 재작성한 버전입니다.

| 영역 | Legacy 또는 이전 구현의 문제 | 현재 처리 |
| --- | --- | --- |
| 저장·복원 | SketchUp 재오픈 후 runtime 정보가 사라질 수 있음 | Attribute dictionary 기반 복원 |
| State 중복 | 같은 entity 재변환 시 State 중복 가능 | 이미 변환된 CellSpace 검사 |
| Node/Link 표시 | 보조선·geometry 기반 표시로 모델 오염 가능 | 3D Overlay로 분리 표시 |
| Transition 중복 | 같은 CellSpace pair에 중복 Transition 가능 | pair key 기준 단일 Transition 관리 |
| Duality/Connects | 끊어진 참조가 export에 남을 수 있음 | Export snapshot에서 유효 관계만 작성 |
| GML 생성 | 외부 converter 내부 구조 확인 어려움 | Ruby exporter로 Core/Navigation subset 직접 생성 |
| Validation | report만으로 오류 위치 추적이 어려움 | report ID를 CellSpace/State/Transition focus로 연결 |

최근 안정화 작업:

- Bulk 변환을 하나의 동기 transaction으로 처리하되, 개별 항목 실패는 전체 rollback이 아니라 실패 목록으로 보고
- Undo/Redo 이후 runtime reconciliation 수행
- Validation 실행별 isolated workspace 사용
- val3dity process 종료를 stdout EOF가 아닌 process handle/exit code로 판정
- 모델 New/Open/Close 시 stale validation callback 정리
- Windows process handle 상속을 stdout/stderr pipe로 제한
- Validation report에서 오류 CellSpace focus와 오류 요소 재검사 제공

## Architecture

```text
indoor3d/
├── definition.rb                  # version constants
├── core.rb                        # extension runtime loader
├── domain/                        # CellSpace, State, Transition, semantics
├── application/                   # IndoorModel and application services
│   ├── adjacency_service/         # adjacency sync and geometry query
│   └── indoor_model/              # IndoorModel mixins
├── infrastructure/
│   ├── observers/                 # SketchUp observer adapters
│   ├── persistence/               # AttributeSerializer, RuntimeRestorer
│   └── scene/                     # active path, locks, editor session
├── export/                        # snapshot, exporter, XML writer
├── validity/                      # val3dity runner, report, recheck policy
├── ui/                            # commands, dialogs, overlay
└── utils/                         # geometry, transform, materials
```

`IndoorModel`은 다음 mixin으로 나뉩니다.

| Mixin | 책임 |
| --- | --- |
| `RuntimeSupport` | runtime collection, registry binding, attribute helper |
| `SceneGroups` | PrimalGroup 생성/보호, 좌표 변환, scene 배치 |
| `FeatureLifecycle` | CellSpace 생성/변경/삭제 lifecycle |
| `Topology` | adjacency와 Transition runtime sync |
| `ObserverRouting` | SketchUp observer event 라우팅 |
| `EntityRelocation` | entity 복제/이동과 transform 보존 |
| `PrimalNormalization` | PrimalGroup child 정규화 |
| `EditorControl` | Edit Mode dialog action과 validation focus 제어 |

## Development

### Test

```powershell
ruby -Itest test\run_all.rb
```

현재 테스트는 SketchUp API를 직접 실행하지 않는 부분을 중심으로 구성되어 있습니다. 최근 기준 전체 테스트는 다음 규모입니다.

```text
195 runs, 1199 assertions
```

### Useful Checks

```powershell
# Ruby syntax check
Get-ChildItem -Recurse -Filter *.rb indoor3d,test | ForEach-Object { ruby -c $_.FullName }

# 미사용 인자 후보 확인은 Prism 기반 정적 스캔으로 보조 확인
ruby -Itest test\run_all.rb
```

## Known Limitations

- Validation은 bundled Windows x64 val3dity runtime에 의존합니다.
- Export는 IndoorGML 1.0 Core/Navigation의 단일 SpaceLayer 모델만 생성합니다.
- Transition 생성 정책은 현재 CellSpace 타입과 수직/수평 방향을 구분하지 않습니다.
- State/Transition을 사용자가 직접 생성·연결·해제하는 topology editor는 없습니다.
- Undo/Redo는 runtime reconciliation이 있지만 SketchUp `active_path`, observer callback, transparent operation이 얽히는 경우가 있어 대형 모델에서는 재동기화 비용이 발생할 수 있습니다.
- Edit Mode 밖에서 `IndoorGML_PrimalSpaceFeatures`나 CellSpace group을 직접 이동·삭제하면 runtime과 저장 attribute가 일시적으로 어긋날 수 있습니다. 가능한 한 Edit Mode와 제공 명령을 통해 수정하세요.

## References

- IndoorGML: https://www.ogc.org/standards/indoorgml
- IndoorGML schemas: http://schemas.opengis.net/indoorgml/1.0/
- val3dity: https://github.com/tudelft3d/val3dity
- Legacy reference: https://github.com/une-young/indoorgml-modeler
- Project notes: https://u-lo-l.notion.site/IndoorGML-3DSpace-Modeler-395be883973b805dba28c890c9c7e225
