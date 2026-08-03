# val3dity recheck clipped operand 연구

## 목적

val3dity가 지정한 701/704 CellSpace pair의 기존 SketchUp Solid Boolean 판정은 변경하지 않는다.
대신 복잡한 operand를 상대 CellSpace의 확장 bounding box로 국소화할 수 있는지 shadow probe로 측정한다.

연구 브랜치:

```text
experiment/recheck-clipped-operand
```

현재 단계는 **proxy Solid를 생성하지 않는 절단 topology 분석 단계**다.
production recheck 결과와 Boolean 호출은 기존 그대로 유지된다.

## 핵심 보존식

Solid A와 B에 대해 B가 포함되는 box를 C라고 하면:

```text
A ∩ B = (A ∩ C) ∩ B
```

따라서 `A ∩ C`를 동일한 형상과 topology의 manifold proxy로 정확히 만들 수 있다면,
전체 A 대신 proxy를 기존 SketchUp Boolean에 넣을 수 있다.

## 후보 선택 보완

vertex, edge, triangle 중 하나만으로 후보를 결정하지 않는다.

1. triangle AABB와 crop AABB overlap을 broad-phase로 사용한다.
2. vertex-in-box는 완전 포함과 clipping endpoint를 빠르게 확인한다.
3. edge-vs-box slab test는 box를 통과하는 edge를 확인한다.
4. 최종 surface 포함 여부는 triangle을 box의 6개 half-space로 실제 clipping하여 결정한다.

이 조합이 필요한 이유:

- vertex만 보면 모든 vertex가 밖에 있지만 box를 관통하는 큰 triangle을 놓친다.
- edge만 봐도 triangle 면이 box를 덮지만 세 edge가 box를 지나지 않는 경우를 놓칠 수 있다.
- triangle AABB만 보면 false positive가 많다.

## hole 처리 방향

clipped polygon의 edge 중 crop box plane 위에 놓인 edge를 plane별 cap segment로 수집한다.
segment endpoint를 tolerance로 weld한 뒤 그래프를 구성한다.

```text
segment graph
→ 모든 vertex degree 2 확인
→ closed loop 추출
→ plane 2D projection
→ loop containment depth 계산
→ outer / hole 분류
```

현재 probe는 loop와 hole 개수까지만 측정한다.
다음 단계에서 hole-aware planar triangulation과 proxy manifold 생성을 추가한다.

## containment 예외

source surface triangle이 crop box 내부에 하나도 나타나지 않아도 다음 두 경우가 가능하다.

- source Solid와 crop box가 완전히 분리됨
- crop box 전체가 source Solid 내부에 포함됨

따라서 현재 probe는 이를 다음 상태로 기록한다.

```text
surface_miss_requires_containment_test: true
```

이 상태를 empty proxy로 처리하지 않는다.
다음 단계에서 안정적인 point-in-solid 또는 기존 SketchUp API 기반 containment 확인을 추가한다.

## 실행

SketchUp Ruby Console에서 benchmark probe와 clipped operand probe를 순서대로 로드한다.

```ruby
root = File.expand_path('..', File.dirname(ULOL::Indoor3DGmlModeler::EXTENSION.extension_path))
load File.join(root, 'dev', 'val3dity_recheck_benchmark.rb')
load File.join(root, 'dev', 'val3dity_recheck_clipped_operand_probe.rb')
```

이후 평소처럼 Validation Check를 실행한다.

출력:

```text
<report_name>_recheck_benchmark.json
<report_name>_recheck_clipped_operand.json
```

## 주요 출력 항목

pair별:

- 더 복잡한 source operand와 상대 target operand
- source face/triangle 수
- source mesh cache hit 여부
- crop box margin
- triangle AABB 후보 수
- box 안에 들어간 vertex 수
- edge-vs-box hit 수
- clipping 후 polygon/triangle 수
- box plane별 cap segment, loop, outer loop, hole loop 수
- cap graph degree histogram과 closed 여부
- containment 검사가 필요한 surface miss 여부
- 기존 SketchUp Boolean status, reason, volume

## 현재 안전 정책

- 원본 CellSpace 수정 금지
- proxy Solid 생성 안 함
- production recheck 판정 변경 안 함
- 기존 Boolean 생략 안 함
- 특정 CellSpace ID 특례 없음
- geometry 분석 실패 시 기록만 남기고 기존 Boolean 계속 수행

## 다음 단계 진입 조건

실제 모델 결과에서 다음을 먼저 확인한다.

1. 병목 CellSpace pair에서 candidate triangle 수가 충분히 감소하는가
2. cap segment graph가 대부분 closed인가
3. hole이 얼마나 자주 발생하는가
4. coplanar crop-plane ambiguity가 얼마나 발생하는가
5. surface miss containment 사례가 존재하는가

이 결과를 확인한 뒤에만 hole-aware cap triangulation과 임시 manifold proxy 생성을 구현한다.
