# val3dity 701/704 recheck benchmark

## 목적

val3dity 실행 자체는 변경하지 않고, 이후 수행되는 extension recheck의 비용을 단계별로 측정한다.

이 probe는 `dev/val3dity_recheck_benchmark.rb`를 명시적으로 로드한 SketchUp 세션에만 적용된다. production 파일과 판정 로직은 변경하지 않는다.

## 실행 방법

1. `experiment/recheck-benchmark` 브랜치를 체크아웃하고 Extension을 다시 로드한다.
2. SketchUp Ruby Console에서 아래 코드를 한 번 실행한다.

```ruby
root = File.expand_path('..', File.dirname(ULOL::Indoor3DGmlModeler::EXTENSION.extension_path))
load File.join(root, 'dev', 'val3dity_recheck_benchmark.rb')
```

3. 평소와 동일하게 Validation Check를 한 번 실행한다.
4. val3dity report JSON과 같은 작업 디렉터리에 다음 파일이 생성된다.

```text
<report_name>_recheck_benchmark.json
```

같은 이름으로 다시 실행하면 이전 파일을 덮어쓰므로 비교용 파일은 실행 직후 별도 이름으로 복사한다.

## 측정 항목

### 전체 단계

- `runner.recheck_overlap_errors`: recheck 전체 시간
- `policy.count_recheckable_errors`: 701/704 개수 사전 스캔
- `policy.apply`: 오류 순회, pair 추출, 판정 적용, validity 갱신
- `policy.recheck_error_parse`: 오류 내용에서 CellSpace pair를 추출하는 비용
- `policy.refresh_validity`: report validity와 overview 재계산
- `runner.emit_progress`: 진행률 UI 갱신 비용

### CellSpace pair 분석

- `rechecker.entity_faces`: SketchUp Face를 recheck용 geometry로 변환
- `rechecker.shared_face_candidates`: 모든 face pair의 normal/plane/overlap 검사
- `rechecker.triangle_set_overlap`: projected triangle pair clipping
- `rechecker.model_solid_intersection`: 복사, manifold 검사, SketchUp Boolean, 결과 분석, 정리의 전체 비용
- `rechecker.build_boolean_copy`: Boolean 입력 복사 비용
- `rechecker.valid_manifold_group`: manifold 및 volume 검사
- `rechecker.cache_intersection_overlay_geometry`: 실제 overlap 결과의 표시 geometry 생성 및 저장

### 카운터

- `recheck_error_calls`: val3dity 701/704 오류 수
- `unique_pair_cache_miss`: 실제로 분석한 고유 CellSpace pair 수
- `pair_analysis_cache_hit`: 동일 pair의 701/704 중복 분석 회피 횟수
- `face_pair_comparisons`: 현재 이중 루프가 검사한 face pair 수
- `triangle_pair_comparisons`: 현재 polygon clipping 후보 triangle pair 수
- `boolean_pair_calls`: SketchUp Boolean을 수행한 고유 pair 수
- `boolean_copy_calls`: 생성한 Boolean 입력 복사 수
- `manifold_check_calls`, `volume_query_calls`: 반복되는 SketchUp solid 검사 횟수
- `progress_update_calls`: UI detail 갱신 횟수

`pairs` 배열은 소요시간이 긴 pair부터 정렬되며, pair별 face 수, 비교 횟수, candidate 수, Boolean 상태와 단계별 시간을 포함한다.

## 기준 측정 절차

1. 동일 SKP와 동일 validation 옵션을 사용한다.
2. Extension 재로드 직후 1회는 warm-up으로 실행한다.
3. 이어서 3회 측정하고 `runner.recheck_overlap_errors`의 중앙값을 기준값으로 사용한다.
4. 각 실행에서 다음 값이 동일한지 확인한다.
   - `recheck_error_calls`
   - `unique_pair_cache_miss`
   - 각 code의 suppressed / kept / inconclusive 결과
   - 최종 strict validity와 extension validity
5. 최적화 후에도 동일 절차로 측정한다.

## 현재 코드에서 예상되는 병목

### 1. pair별 SketchUp Boolean

`analyze_pair`는 code와 candidate 유무에 관계없이 고유 pair마다 `model_solid_intersection`을 실행한다. 이 단계는 각 pair마다 두 입력을 복사하고 unique definition을 만들며, operation을 시작/rollback하고, `Group#intersect`를 실행한다.

판정 보존을 전제로 가능한 최적화:

- 원본 CellSpace의 `manifold?`와 `volume` 결과를 recheck 세션 동안 cell별 캐시
- 704만 존재하고 shared-face candidate가 없는 pair는 결과가 항상 kept이므로 Boolean 생략 가능 여부 검토
- 단, 같은 pair에 701이 함께 있으면 Boolean을 반드시 유지해야 하므로 오류를 pair 단위로 먼저 그룹화해야 한다
- pair별 operation 시작/rollback을 recheck 전체의 단일 rollback scope로 합치는 방안은 효과가 클 수 있지만 실패 격리와 cleanup 회귀 위험이 있어 후순위

### 2. 모든 face 조합 비교

`shared_face_candidates`는 `faces1.length * faces2.length` 전체를 순회한다.

판정 결과를 바꾸지 않는 보수적 prefilter 후보:

- dominant axis와 반대 normal 방향별 bucket
- plane constant의 tolerance 범위 bucket
- projected face AABB overlap 검사

prefilter는 불가능한 pair만 제외하고, 경계에 걸린 face는 반드시 기존 정밀 검사로 넘겨야 한다.

### 3. 모든 triangle 조합 clipping

`triangle_set_overlap`은 두 triangle 집합의 Cartesian product 전체에 대해 projection과 polygon clipping을 반복한다.

안전한 최적화 후보:

- face geometry 생성 시 axis별 2D projection을 미리 계산
- projected triangle AABB를 미리 계산
- AABB가 겹치는 triangle pair에만 기존 `intersect_polygons_2d` 실행
- hole triangle에도 동일한 conservative prefilter 적용

기존 clipping과 area tolerance는 그대로 유지한다.

### 4. progress 및 report 순회

오류마다 `progress.detail`을 호출하고, report를 count/apply/refresh 단계에서 여러 번 순회한다.

Boolean 또는 triangle clipping보다 비중이 작을 가능성이 높지만, 다음 조건이면 최적화 가치가 있다.

- `runner.emit_progress`가 전체의 5% 이상
- `policy.recheck_error_parse`가 전체의 5% 이상

가능한 개선:

- percent가 바뀌거나 일정 시간 이상 지난 경우에만 progress 갱신
- report를 한 번 순회하며 recheckable error와 pair/code를 수집
- Hash 전체를 JSON 문자열로 변환한 뒤 regex 검색하는 방식을 known error fields 우선 파싱으로 변경

## 최적화 우선순위 결정 규칙

1. `rechecker.model_solid_intersection`이 전체의 60% 이상이면 Boolean 호출 수와 반복 solid 검사를 먼저 줄인다.
2. `rechecker.shared_face_candidates`가 20% 이상이면 face bucket/AABB prefilter를 먼저 적용한다.
3. `rechecker.triangle_set_overlap`이 20% 이상이거나 `triangle_pair_comparisons`가 매우 크면 projection/AABB 캐시를 적용한다.
4. UI/report 단계가 5% 이상일 때만 progress throttling 또는 report single-pass를 진행한다.

첫 최적화는 특정 CellSpace 예외가 아니라 모든 pair에 적용되는 conservative prefilter 또는 세션 캐시부터 시작한다. 각 변경은 기존 701/704 판정 결과가 완전히 동일한지 회귀 테스트와 실제 report diff로 확인한다.
