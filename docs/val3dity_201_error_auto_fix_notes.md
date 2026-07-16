# val3dity 201 계열 오류 수정 방식 정리

## 목적

이 문서는 SketchUp IndoorGML CellSpace에서 사용자가 통칭한 "201 Error"를 수동으로 수정하면서 사용한 방법을 정리한다. 향후 자동 수정 로직을 구현할 때 성공한 전략, 실패한 전략, 안전 조건과 검증 순서를 그대로 재사용하는 것이 목적이다.

## 오류 코드 용어

현재 작업에서 실제로 반복 발생한 오류는 val3dity 2.2.0의 다음 오류였다.

```text
203 NON_PLANAR_POLYGON_DISTANCE_PLANE
distance to fitted plane: ... (tolerance=0.01)
```

사용자는 이를 대화에서 "201 Error"라고 불렀다. 자동 수정 로직은 화면의 통칭이나 상위 오류만 보고 동작하면 안 되며, report JSON의 `code`, `description`, `id`, `info`를 함께 확인해야 한다.

- 주 대상: `code == 203`
- 설명: `NON_PLANAR_POLYGON_DISTANCE_PLANE`
- polygon ID 형식: `polygon_<face_index>_cell_<cell_id>`
- primitive ID 형식: `solid_cell_<cell_id>`
- 기본 거리 허용오차: `0.01 mm`

진짜 `code == 201`이 들어오면 203 수정기로 보내지 말고 별도 정책으로 분기해야 한다.

## 공통 작업 원칙

### 1. `active_path`를 변경하지 않는다

모든 조회와 수정 전후에 다음 값을 비교했다.

```ruby
before = (model.active_path || []).map(&:persistent_id)
# 작업
after = (model.active_path || []).map(&:persistent_id)
raise 'active_path changed' unless before == after
```

CellSpace 그룹을 열거나 닫지 않고 `group.definition.entities`를 직접 수정한다.

### 2. CellSpace 단위로 transaction을 분리한다

```ruby
model.start_operation(operation_name, true)
begin
  # geometry change
  raise 'non-manifold' unless group.valid? && group.manifold?
  raise 'active_path changed' unless before_path == after_path
  model.commit_operation
rescue StandardError
  model.abort_operation
  raise
end
```

자동 수정기는 가능하면 오류 셀 하나당 Undo 한 번이 되도록 operation을 만든다.

### 3. 수정 직후 manifold를 확인한다

성공 조건은 단순히 SketchUp API 호출이 예외 없이 끝나는 것이 아니다.

- CellSpace group이 유효한가
- `group.manifold? == true`인가
- 면과 모서리가 비정상적으로 소실되지 않았는가
- 원래 bounds가 의도하지 않게 변하지 않았는가
- `active_path`가 유지됐는가

하나라도 실패하면 operation을 abort한다.

### 4. 최종 판단은 단일 셀 GML 재검증으로 한다

수정 후 해당 CellSpace만 `ExportSnapshot`으로 내보내고 bundled val3dity를 다시 실행했다.

```ruby
snapshot = ExportSnapshot.build(
  indoor_model: indoor_model,
  cell_spaces: [cell_space],
  transitions: []
)
```

```powershell
val3dity.exe input.gml --verbose --overlap_tol -1 -r report.json
```

최종 성공 조건은 다음과 같다.

- primitive `validity == true`
- primitive errors가 비어 있음
- 대상 셀의 201/203 오류가 0개
- SketchUp group이 manifold

## 오류 면을 찾는 방법

`ExportSnapshot#build_surfaces`는 다음 순서로 polygon ID를 만든다.

```ruby
group.definition.entities.grep(Sketchup::Face).map.with_index
```

따라서 최초 진단 시 `polygon_145_cell_d6lrqmha`의 `145`는 해당 시점의 Face 배열 index와 대응한다.

하지만 Face index는 안정적인 식별자가 아니다.

- face 추가 또는 삭제
- operation abort
- observer에 의한 runtime refresh
- SketchUp 내부 entity 재생성

위 작업 후 `grep(Sketchup::Face)` 순서가 달라질 수 있다. 실제로 abort 이후 같은 index가 전혀 다른 면을 가리키는 사례가 있었다.

안전한 절차는 다음과 같다.

1. report의 polygon index로 Face를 최초 1회 찾는다.
2. 즉시 `face.persistent_id`를 저장한다.
3. 이후 수정은 `model.find_entity_by_persistent_id(pid)`로 면을 다시 찾는다.
4. 수정 후 polygon index는 새 GML report에서 다시 읽는다.

## 사용한 수정 방식

## A. 지배 좌표 평면화

수평 또는 수직에 가까운 면의 정점을 동일한 좌표로 맞추는 방식이다.

적합한 경우:

- 바닥이나 천장처럼 거의 `z = constant`인 면
- 벽처럼 거의 `x = constant` 또는 `y = constant`인 면
- 최대 이동량이 작고 의도한 설계 평면이 명확한 경우

절차:

1. 면의 normal과 bounds를 검사한다.
2. 가장 지배적인 축을 선택한다.
3. 해당 축 좌표의 median 또는 설계 기준값을 구한다.
4. 관련 vertex를 그 좌표로 이동한다.
5. 인접면과 전체 group의 manifold를 확인한다.
6. 단일 셀 val3dity를 재실행한다.

사용 사례:

- `cell_osf2noh4`: 비평면 polygon의 일부 정점을 기준 평면에 snap했다.
- `cell_y9i38ajc`: 사각기둥 구멍 교체 후 바닥면의 z 좌표를 median 값으로 맞췄다.

장점:

- 면 수 증가가 거의 없다.
- 단순 수평·수직 형상에서 가장 작고 이해하기 쉬운 수정이다.

주의점:

- 공유 vertex 이동은 인접면을 함께 바꾼다.
- 한 면을 고치면서 다른 면에 새로운 203이 생길 수 있다.
- 얇은 면이나 복잡한 곡면 근사에서는 topology가 깨질 수 있다.
- 항상 예상 최대 이동량을 mm로 기록해야 한다.

권장 자동 적용 조건:

```text
dominant normal component >= 0.9999
maximum vertex displacement <= configured limit
group remains manifold
bounds delta is within configured limit
```

## B. Face plane으로 vertex 투영

SketchUp Face가 가진 `face.plane`에 각 vertex를 직교 투영하는 방식이다.

```ruby
projected = vertex.position.project_to_plane(face.plane)
vector = projected - vertex.position
entities.transform_by_vectors(vertices, vectors)
```

여러 오류 면이 vertex를 공유하면 면별로 즉시 이동하지 않고 모든 목표점을 먼저 계산해야 한다. 같은 vertex에 여러 투영 목표가 있으면 평균점 또는 constrained solve 결과를 한 번에 적용한다.

성공 가능성이 높은 경우:

- 이동량이 SketchUp tolerance보다 충분히 작음
- 오류 면의 경계가 단순함
- 인접면이 이동을 흡수할 수 있음

실패 사례와 교훈:

- `cell_d6lrqmha`에서 두 면을 순차 투영하자 첫 이동 후 두 번째 Face 객체가 삭제·재생성됐다.
- 두 면을 동시에 투영해도 일부 인접면 연결이 깨져 non-manifold가 됐다.
- 실패 시 operation abort는 정상 동작했지만 Face 배열 순서는 바뀔 수 있었다.

따라서 이 방식은 반드시 noncommit probe 또는 abort 가능한 operation 안에서 실행해야 한다.

## C. 중심점 또는 spoke를 이용한 면 분할

큰 비평면 polygon을 여러 작은 polygon으로 나누어 각 조각의 평면 편차를 허용오차 아래로 낮추는 방식이다.

사용 사례:

- `cell_pvphfx8s`: 큰 오류 면 두 개에 각각 4개의 spoke를 추가해 분할했고 단일 셀 val3dity가 VALID가 됐다.

장점:

- 외곽 형상과 기존 vertex 위치를 유지할 수 있다.
- 좌표 이동보다 인접 셀과의 경계 변화가 적다.

주의점:

- 중심점이 polygon 내부에 있어야 한다.
- hole이 있는 face에는 단순 fan을 적용하면 안 된다.
- 비평면 편차가 SketchUp 면 허용오차에 가까우면 선이 face를 실제로 split하지 않고 dangling edge가 될 수 있다.

## D. SketchUp mesh 기반 전체 삼각 분할

`face.mesh(0).polygons`에서 얻은 삼각형의 내부 대각선을 추가하는 방식이다.

```ruby
mesh = face.mesh(0)
triangles = mesh.polygons.map do |polygon|
  polygon.map { |index| mesh.point_at(index.abs) }
end
```

성공 사례:

- 복잡하지만 hole이 없는 여러 세로 면
- 매우 얇은 사각면
- `jc442leo`, `gbpz9ybk`, `jviz997d`, `ulzjobi4`, `jdksrt02`, `3s8f15gl`의 오류 면

효과:

- triangle은 항상 평면이므로 203을 직접 제거할 수 있다.
- vertex를 이동하지 않아 외곽 좌표가 유지된다.

실패 사례:

- `uwwcqu5h`, `d6lrqmha`에서는 일부 mesh diagonal이 실제 face split에 실패해 dangling edge가 생겼다.
- hole이 있는 face에서 모든 triangle edge를 일괄 추가하면 non-manifold가 될 수 있었다.
- mesh 안에 높이가 거의 0인 degenerate triangle이 포함될 수 있다.

일괄 삼각 분할은 다음 조건을 모두 통과할 때만 commit해야 한다.

- 추가 후 face count가 증가함
- group이 manifold
- 새 edge가 고립되지 않음
- degenerate triangle이 없음

## E. 내부 대각선의 안전한 점진 적용

`cell_d6lrqmha`에서 최종 성공한 방식이다.

Face mesh의 모든 내부 edge 후보를 구한 뒤 하나씩 적용한다. 각 후보에 대해 실제로 면이 분할되고 group이 계속 manifold인 경우에만 edge를 유지한다.

내부 edge 후보는 triangle mesh에서 두 triangle이 공유하는 edge, 즉 출현 횟수가 2인 edge로 구한다.

```ruby
counts[sorted_vertex_pair] += 1
internal_edges = counts.select { |_pair, count| count == 2 }
```

각 후보의 적용 조건:

```text
face_count_after > face_count_before
group.manifold? == true
active_path unchanged
```

분할하지 못했거나 manifold를 깨는 새 edge는 즉시 제거한다.

실제 결과:

- 후보 103개
- 유지 67개
- 기존 edge이거나 변화가 없어서 제외 36개
- 최종 247 faces, 337 vertices
- manifold 유지
- 단일 셀 val3dity VALID, errors 0

이 방식은 자동 수정의 기본 fallback으로 가장 적합하다. 좌표를 움직이지 않고 성공한 split만 누적할 수 있기 때문이다.

## F. 곡선 구멍을 외접 사각기둥으로 교체

원·호 기둥 또는 곡선 구멍을 그대로 평면화하기 어려울 때 사용한 정책 기반 형상 단순화 방식이다.

사용 사례:

- `cell_y9i38ajc`
- 원형 또는 호 형태 구멍 5개를 각각 외접 사각기둥으로 교체
- 실제 구 형상 구멍은 해당 셀에서 발견되지 않음

절차:

1. 곡선 component의 중심, 반지름, z 범위를 계산한다.
2. 원의 외접 axis-aligned square를 만든다.
3. square를 z 방향으로 연장해 cutter box를 만든다.
4. CellSpace solid에서 cutter를 Boolean subtract한다.
5. 결과가 manifold인지 확인한다.
6. 원래 group의 PID, 속성, transform과 bounds를 보존해 geometry만 교체한다.

SketchUp Boolean operand 방향은 반드시 probe로 확인해야 한다. 사용한 환경에서는 `tool.subtract(work)`가 `work - tool` 결과를 반환했다.

실패 사례:

- 단순히 원형 vertex를 사각형으로 방사 투영하면 기존 사각 구멍과 ring이 겹쳐 `201 RING_INTERSECTION` 계열 문제가 생겼다.
- 45도 회전 사각형, 벽 이동, 직접 intersect 등은 manifold 조건을 통과하지 못했다.
- Boolean operand 순서를 반대로 적용하면 CellSpace 대신 cutter box만 남을 수 있다.

이 방식은 geometry 의미를 바꾸므로 일반 203 자동 수정의 기본 전략으로 사용하면 안 된다. 사용자 또는 도메인 정책에서 곡선 구멍의 사각화가 허용된 경우에만 실행한다.

## G. validation GML에서 원본 CellSpace 복원

Undo 또는 반복 실험으로 원래 geometry를 신뢰하기 어려울 때 최신 validation run의 `input.gml`에서 대상 CellSpace polygon을 읽어 임시 solid를 재구성했다.

사용 사례:

- `cell_y9i38ajc`
- validation GML의 469 polygon을 이용해 원본과 같은 469 faces, 1401 edges, manifold solid를 복원
- 복원한 임시 solid에 사각기둥 Boolean 작업을 수행

안전 조건:

- GML의 cell ID가 정확히 일치해야 한다.
- 모든 exterior/interior ring을 보존해야 한다.
- 임시 group이 manifold인지 먼저 확인한다.
- 원본 group 자체를 교체하지 말고 definition geometry만 전달해 CellSpace PID와 metadata를 유지한다.

이 방식은 recovery fallback이며 일반적인 첫 수정 방법이 아니다.

## H. 면을 제거한 뒤 mesh triangle로 다시 채우기

비평면 face를 삭제하고 `face.mesh`의 triangle을 새 face로 추가하는 방법도 시험했다.

장점:

- 단순 edge 추가가 split에 실패하는 경우에도 triangle face를 직접 만들 수 있다.

문제점:

- mesh에 거의 collinear한 triangle이 포함되면 `Points are not planar` 또는 `add_face == nil`이 발생한다.
- degenerate triangle을 제외하면 셸에 미세한 gap이 생겨 non-manifold가 될 수 있다.
- 복잡한 hole face에서는 주변 face의 subdivision과 정확히 일치하지 않을 수 있다.

`cell_d6lrqmha`에서는 이 방식이 실패했고 최종적으로 안전한 점진 대각선 적용 방식으로 전환했다.

## 실패한 접근과 자동 수정 금지 조건

다음 상황에서는 수정 결과를 commit하면 안 된다.

- `group.manifold? == false`
- face split을 기대했지만 face count가 증가하지 않음
- 새 edge가 face를 가지지 않는 dangling edge임
- target Face가 수정 중 삭제됐는데 stale Ruby object를 계속 사용함
- abort 이후 예전 face index를 다시 사용함
- Boolean 결과 bounds가 원본 CellSpace 범위를 벗어남
- group PID 또는 CellSpace ID가 바뀜
- active edit path가 바뀜
- 재검증에서 새로운 201/203/204/205 오류가 발생함

## 권장 자동 수정 우선순위

```text
1. report 파싱 및 대상 CellSpace/Face 식별
2. Face index를 즉시 persistent_id로 고정
3. 원본 상태 측정
   - group PID
   - active_path
   - bounds
   - face/edge/vertex count
   - manifold
4. 단순 지배 평면이면 축 좌표 평면화 probe
5. 일반 polygon이면 안전한 mesh 내부 대각선 점진 적용
6. 단순 대형 polygon이면 spoke 분할 probe
7. 정책이 허용한 곡선 구멍이면 외접 사각기둥 Boolean
8. geometry가 손상됐거나 복원이 필요하면 validation GML recovery
9. 단일 셀 GML export 및 val3dity 재실행
10. VALID일 때만 commit, 아니면 abort
```

권장 기본값은 좌표 이동보다 안전한 내부 대각선 분할을 먼저 시도하는 것이다. 단, 수평 바닥처럼 기준 평면이 명확하고 이동량이 극히 작다면 평면화가 더 단순하다.

## 자동 수정기 구조 제안

```text
ValidationReportParser
  -> ErrorTargetResolver
  -> CellGeometrySnapshot
  -> StrategySelector
       -> DominantAxisPlanarizer
       -> FacePlaneProjector
       -> SafeMeshEdgeSplitter
       -> SpokeFaceSplitter
       -> CurvedHoleBoxReplacer (policy-gated)
       -> GmlRecoveryRebuilder (fallback)
  -> GeometryInvariantChecker
  -> SingleCellValidationRunner
  -> AutoFixResult
```

`AutoFixResult`에는 최소한 다음 정보를 남기는 것이 좋다.

```ruby
{
  cell_id:,
  source_error_code:,
  source_polygon_id:,
  source_face_pid:,
  strategy:,
  operation_name:,
  max_vertex_move_mm:,
  added_edges:,
  face_count_before:,
  face_count_after:,
  bounds_delta_mm:,
  manifold_before:,
  manifold_after:,
  validation_errors_before:,
  validation_errors_after:,
  active_path_before:,
  active_path_after:
}
```

## 구현 시 추가 고려사항

### Observer와 runtime refresh

geometry 변경 중 observer가 CellSpace runtime object를 갱신할 수 있다. operation 안에서는 `IndoorModel#cell_spaces`를 반복 조회하기보다 시작 전에 대상 group 객체와 PID를 확보한다.

### shared definition

`group.definition.instances.length > 1`이면 definition 수정이 다른 instance에도 적용된다. 자동 수정 전 `make_unique` 정책 또는 수정 거부 정책이 필요하다.

### tolerance 단위

SketchUp 내부 좌표는 inch이고 val3dity GML은 현재 mm로 export한다. 비교와 로그는 명시적으로 mm로 변환한다.

```ruby
distance_mm = distance_inch * 25.4
```

### degenerate triangle

triangle의 품질은 단순 면적보다 최소 altitude로 판단하는 것이 안전하다.

```ruby
double_area = (p2 - p1).cross(p3 - p1).length.to_f
max_edge = [p1.distance(p2), p2.distance(p3), p3.distance(p1)].max.to_f
altitude = max_edge.positive? ? double_area / max_edge : 0.0
```

하지만 degenerate triangle을 제외한 뒤 manifold가 보장되는 것은 아니다. 제외 후 전체 셸 검사를 반드시 수행한다.

## 지금까지 확인된 성공 결과

| CellSpace | 적용 방식 | 결과 |
| --- | --- | --- |
| `osf2noh4` | 오류 정점 평면 snap | targeted validation VALID |
| `pvphfx8s` | 큰 면 spoke 분할 | targeted validation VALID |
| `y9i38ajc` | GML 복원, 곡선 구멍 외접 사각기둥 Boolean, 바닥 평면화 | 78 faces, targeted validation VALID |
| `jc442leo` | mesh 기반 삼각 분할 | 203 제거 |
| `gbpz9ybk` | mesh 기반 삼각 분할 | 203 제거 |
| `uwwcqu5h` | Face plane vertex 투영 | 203 제거, manifold 유지 |
| `jviz997d` | mesh 기반 삼각 분할 | 203 제거 |
| `ulzjobi4` | mesh 기반 삼각 분할 | 203 제거 |
| `jdksrt02` | 얇은 사각면 삼각 분할 | 203 제거 |
| `3s8f15gl` | mesh 기반 삼각 분할 | 203 제거 |
| `d6lrqmha` | mesh 내부 대각선의 안전한 점진 적용 | 247 faces, 337 vertices, targeted validation VALID |

## 결론

203 비평면 오류는 한 가지 방식으로 일괄 수정하기 어렵다. 자동 수정기는 다음 원칙을 가져야 한다.

- 오류 면을 persistent ID로 고정한다.
- 가장 작은 geometry 변경부터 시도한다.
- 각 후보 변경을 transaction 안에서 시험한다.
- manifold와 active path를 즉시 확인한다.
- 단일 셀 val3dity가 VALID일 때만 성공으로 처리한다.
- 실패한 전략은 깨끗하게 abort하고 다음 전략으로 넘어간다.

현재 사례에서는 `SafeMeshEdgeSplitter`가 가장 일반적인 fallback이었고, 축 정렬 면에는 `DominantAxisPlanarizer`, 정책 기반 곡선 단순화에는 `CurvedHoleBoxReplacer`가 효과적이었다.
