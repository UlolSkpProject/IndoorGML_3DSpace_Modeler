# Refactor TODO - IndoorGML SketchUp 2026 Extension

이 문서는 SketchUp 2026용 IndoorGML 1.0 플러그인 리팩토링 작업을 단계별로 진행하기 위한 체크리스트다.

## 진행 규칙

- Codex는 반드시 **한 번에 한 단계만** 수정한다.
- 각 단계는 `Codex 작업 완료` 체크박스까지만 Codex가 체크할 수 있다.
- `실제 SketchUp 테스트 완료` 체크박스는 **사용자만 체크할 수 있다**.
- `실제 SketchUp 테스트 완료`가 체크되지 않은 상태에서는 다음 단계로 넘어가면 안 된다.
- 각 단계의 수정은 기능 변경이 아니라 리팩토링이어야 한다.
- 스타일 변경, 포맷팅 변경, 네이밍 취향 변경은 하지 않는다.
- 각 단계마다 Undo/Redo 외의 관련 회귀 테스트를 수행한다.
- Undo/Redo 관련 문제는 최후방 치명적 버그 수정 단계로 미룬다. 단계별 리팩토링 진행 여부를 판단할 때 Undo/Redo 실패만으로는 다음 단계 진행을 막지 않는다.
- 테스트 실패 시 다음 단계로 진행하지 말고 해당 단계 안에서 수정한다. 단, Undo/Redo 실패는 최후방 보류 항목으로 기록한다.

## 공통 수동 테스트 기준

각 단계 이후 최소한 아래 항목은 확인한다.

- [ ] SketchUp 2026에서 플러그인이 정상 로드된다.
- [ ] Ruby Console에 로딩 예외가 없다.
- [ ] `Create CellSpace`가 정상 동작한다.
- [ ] CellSpace 타입 변경이 정상 동작한다.
- [ ] CellSpace 이동 후 State/Transition이 기존처럼 동작한다.
- [ ] Undo/Redo 외의 기본 기능이 정상 동작한다.
- [ ] Export GML이 예외 없이 실행된다.
- [ ] Check Validity가 예외 없이 실행된다.

---

# 0단계. 리팩토링 전 기준 동작 고정

## 목표

현재 프로젝트의 기준 동작을 문서화한다. 이 단계에서는 Ruby 코드를 수정하지 않는다.

## 수정해야 할 부분

- `README_DEV.md` 또는 `docs/refactor_checklist.md` 생성
- 현재 기능 기준 수동 테스트 체크리스트 작성

## 수정해야 하는 이유

리팩토링 전 기준 동작을 고정하지 않으면, 이후 변경이 기능 변경인지 내부 구조 개선인지 구분하기 어렵다.

## Codex 작업 내용

- [ ] 리팩토링 전 수동 테스트 체크리스트 문서를 추가한다.
- [ ] 아래 시나리오를 문서에 포함한다.
  - [ ] 플러그인 로드
  - [ ] IndoorGML 전용 그룹 생성
  - [ ] CellSpace 생성
  - [ ] CellSpace 타입 변경
  - [ ] CellSpace 이동
  - [ ] CellSpace 삭제
  - [ ] Undo
  - [ ] Redo
  - [ ] Export GML
  - [ ] Check Validity
- [ ] Ruby 코드는 수정하지 않는다.

## 테스트할 내용

- [ ] 문서만 추가되었는지 확인한다.
- [ ] Ruby 코드 diff가 없는지 확인한다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 1단계로 넘어가지 않는다.

---

# 1단계. Observer 내부 modal UI 제거

## 목표

Observer 흐름에서 직접 `UI.messagebox`를 호출하지 않도록 한다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/infrastructure/scene/scene_group_guard.rb
indoor3d/application/indoor_model.rb
indoor3d/application/indoor_model/runtime_support.rb
```

현재 문제 후보:

```ruby
UI.messagebox(...)
```

특히 `SceneGroupGuard#restore_name`, `SceneGroupGuard#restore_scale` 주변을 확인한다.

## 수정해야 하는 이유

SketchUp Observer는 SketchUp 내부 이벤트 처리 중 호출된다. 이 안에서 modal dialog를 띄우면 이벤트 루프 정지, observer 재진입, Undo/Redo 꼬임이 발생할 수 있다.

## Codex 작업 내용

- [ ] `SceneGroupGuard`가 직접 `UI.messagebox`를 호출하지 않도록 수정한다.
- [ ] `SceneGroupGuard`에 `notifier` callback을 주입한다.
- [ ] `IndoorModel` 또는 runtime support 쪽에 `defer_ui_message(message)` 메서드를 추가한다.
- [ ] `defer_ui_message`는 `UI.start_timer(0, false)` 안에서 `UI.messagebox`를 호출한다.
- [ ] 기존 사용자 알림 문구의 의미는 유지한다.
- [ ] observer 내부에서 직접 modal UI를 띄우는 다른 코드가 있는지 검색한다.

## 테스트할 내용

- [ ] IndoorGML_PrimalSpaceFeatures 이름을 변경하면 원래 이름으로 복구된다.
- [ ] 이름 복구 알림이 뜨더라도 SketchUp이 멈추지 않는다.
- [ ] IndoorGML_PrimalSpaceFeatures 스케일을 변경하면 원래 스케일로 복구된다.
- [ ] 스케일 복구 알림이 중복으로 여러 번 뜨지 않는다.
- [ ] CellSpace 이름 변경 제한이 기존처럼 동작한다.
- [ ] Undo/Redo 시 messagebox가 무한 반복되지 않는다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [ ] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 2단계로 넘어가지 않는다.

---

# 2단계. Observer 재진입 guard 명확화

## 목표

Observer 안에서 entity를 수정할 때 같은 observer가 재호출되어 무한 반복되거나 중복 처리되지 않도록 guard 흐름을 명확하게 정리한다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/application/indoor_model/runtime_support.rb
indoor3d/application/indoor_model/observer_routing.rb
indoor3d/infrastructure/scene/scene_group_guard.rb
```

현재 guard 후보:

```ruby
@syncing
@erasing
@relocating_entity
@refreshing_runtime
@constraining_space_features
```

## 수정해야 하는 이유

Observer 콜백 안에서 이름 복구, transform 복구, lock 복구 같은 mutation이 발생하면 observer가 다시 호출될 수 있다. guard가 명확하지 않으면 재귀 이벤트와 중복 mutation이 발생한다.

## Codex 작업 내용

- [ ] observer 재진입 방지에 쓰이는 instance variable 목록을 확인한다.
- [ ] `space_features_changed` 흐름에 명확한 guard를 적용한다.
- [ ] `@constraining_space_features`가 항상 `ensure`에서 해제되도록 한다.
- [ ] 기존 동작을 바꾸지 않고 guard 흐름만 명확히 한다.
- [ ] guard helper를 추가하는 경우, 한 파일에만 적용하지 말고 같은 패턴을 사용하는 곳에 일관되게 적용한다.

## 테스트할 내용

- [ ] Primal group 이름 변경 시 한 번만 복구된다.
- [ ] Primal group 스케일 변경 시 한 번만 복구된다.
- [ ] 같은 `onChangeEntity` 흐름이 Ruby Console에 비정상적으로 반복되지 않는다.
- [ ] CellSpace 이동 시 State/Transition 갱신이 기존처럼 동작한다.
- [ ] Undo/Redo 후 guard flag가 남아서 기능이 막히지 않는다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 3단계로 넘어가지 않는다.

---

# 3단계. Observer attach 로직 통일

## 목표

Observer 중복 부착을 방지하는 기준을 통일한다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/application/indoor_model/feature_lifecycle.rb
indoor3d/application/indoor_model/scene_groups.rb
indoor3d/application/indoor_model/runtime_support.rb
```

현재 attach 관련 후보:

```ruby
attach_entity_observer
attach_space_features_observer
attach_existing_space_features_observer
attach_entities_observer
```

## 수정해야 하는 이유

검토 초기에는 observer attach 중복 방지 기준을 `persistent_id` 중심으로 바꾸는 방향을 고려했다. 그러나 3단계 테스트 중 생성 → Undo → Redo 이후 CellSpace observer가 다시 붙지 않는 문제가 확인되었다.

이 프로젝트에서 observer attach registry는 영속 데이터가 아니라 현재 Ruby runtime에서 "이 Ruby wrapper에 observer를 붙였는가"를 추적하는 상태다. 따라서 observer attach key는 기존 동작처럼 `object_id` 기준을 유지한다. `persistent_id`는 FeatureRegistry/CellSpace lookup처럼 SketchUp entity의 영속 정체성을 추적하는 곳에서 다루고, observer attach 여부 판단에는 사용하지 않는다.

## Codex 작업 내용

- [ ] entity observer attach key를 만드는 helper를 추가한다.
- [ ] entity observer attach key는 기존 동작처럼 `object_id` 기준을 유지한다.
- [ ] `persistent_id` 기반 observer attach key 전환은 Undo/Redo 재attach를 막을 수 있으므로 이 단계에서 적용하지 않는다.
- [ ] Entities collection observer는 기존처럼 collection object 기준을 유지한다.
- [ ] observer attach 관련 코드가 같은 helper를 사용하도록 정리한다.
- [ ] 기존 observer 종류와 attach 시점은 변경하지 않는다.

## 테스트할 내용

- [ ] 플러그인 로드 후 observer attach 예외가 없다.
- [ ] `refresh_runtime_data`를 여러 번 호출해도 같은 entity에 observer가 중복 부착되지 않는다.
- [ ] CellSpace 생성/삭제 반복 시 이벤트가 중복 호출되지 않는다.
- [ ] CellSpace 이동 시 State/Transition 갱신이 한 번만 일어난다.
- [ ] Undo/Redo 후 observer가 사라지거나 중복되지 않는다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 4단계로 넘어가지 않는다.

---

# 4단계. FeatureRegistry key 이름 정리

## 목표

`entityID`, `persistent_id`, entity object key의 의미를 이름으로 명확히 구분한다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/application/feature_registry.rb
```

현재 후보:

```ruby
@cell_spaces_by_entity
@cell_spaces_by_entity_id
@cell_spaces_by_sketchup_entity_id
```

## 수정해야 하는 이유

`@cell_spaces_by_entity_id`가 실제로 `persistent_id`를 의미하는 등 이름과 의미가 섞여 있다. 삭제 callback 대응용 `entityID`와 영속 식별용 `persistent_id`는 반드시 구분되어야 한다.

## Codex 작업 내용

- [ ] `FeatureRegistry` 내부 hash 이름을 의미가 드러나게 변경한다.
- [ ] `persistent_id` 기반 hash와 `entityID` 기반 hash를 명확히 분리한다.
- [ ] 삭제 callback 대응용 메서드는 이름에 removed callback 용도임을 드러낸다.
- [ ] 외부 호출부의 메서드명도 함께 변경한다.
- [ ] 기능 변경 없이 이름과 의미 정리만 한다.

권장 이름 예시:

```ruby
@cell_spaces_by_entity_object
@cell_spaces_by_persistent_id
@cell_spaces_by_entity_id_for_removed_callback
```

권장 메서드명 예시:

```ruby
find_cell_space_for_entity(entity)
find_cell_space_by_persistent_id(pid)
find_cell_space_by_removed_entity_id(entity_id)
```

## 테스트할 내용

- [ ] CellSpace 생성 후 registry 등록이 정상이다.
- [ ] CellSpace 선택 후 타입 변경이 정상이다.
- [ ] CellSpace 이동 후 State/Transition 갱신이 정상이다.
- [ ] CellSpace 삭제 시 삭제 대상 CellSpace를 정상적으로 찾는다.
- [ ] Undo 삭제 복구 후 runtime refresh가 정상이다.
- [ ] Export GML이 기존처럼 동작한다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 5단계로 넘어가지 않는다.

---

# 5단계. Feature 객체 valid accessor 추가

## 목표

삭제된 SketchUp Entity에 직접 접근하는 위험을 줄이기 위해 안전 접근자를 추가한다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/domain/cell_space.rb
indoor3d/domain/state.rb
indoor3d/domain/transition.rb
```

현재 직접 접근 후보:

```ruby
cell_space.sketchup_group
state.sketchup_component_instance
transition.edge
```

## 수정해야 하는 이유

SketchUp Entity가 삭제되면 Ruby wrapper가 남아 있어도 `valid?`가 false가 된다. 호출부마다 직접 `valid?`를 확인하면 누락이 생긴다.

## Codex 작업 내용

- [ ] `CellSpace#valid_sketchup_group` 추가
- [ ] `State#valid_component_instance` 추가
- [ ] `Transition#valid_edge` 추가
- [ ] 각 메서드는 entity가 없거나 invalid이면 `nil`을 반환한다.
- [ ] 기존 accessor는 제거하지 않는다.
- [ ] 호출부 변경은 최소화한다.
- [ ] 우선 AttributeSerializer, Exporter, Overlay처럼 invalid entity 접근 가능성이 큰 곳부터 안전 접근자를 사용한다.

예시:

```ruby
def valid_sketchup_group
  return nil unless @sketchup_group&.valid?

  @sketchup_group
rescue StandardError
  nil
end
```

## 테스트할 내용

- [ ] CellSpace 삭제 후 Export GML 실행 시 예외가 없다.
- [ ] CellSpace 삭제 후 Overlay 표시 시 예외가 없다.
- [ ] Undo/Redo 후 invalid entity 접근 예외가 없다.
- [ ] 기존 CellSpace 생성/타입변경/이동 동작이 유지된다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 6단계로 넘어가지 않는다.

---

# 6단계. AttributeSerializer write 방어 강화

## 목표

invalid entity에 attribute write를 시도하지 않도록 방어한다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/infrastructure/persistence/attribute_serializer.rb
```

현재 후보:

```ruby
write_cell_space
write_state
write_transition
write_space_features
```

## 수정해야 하는 이유

Undo/Redo, 삭제 callback, observer 재진입 중에는 entity가 invalid 상태일 수 있다. 이때 `set_attribute`를 호출하면 예외가 발생할 수 있다.

## Codex 작업 내용

- [ ] 모든 write 계열 메서드 입구에서 entity 유효성을 확인한다.
- [ ] entity가 invalid이면 write하지 않고 `false`를 반환한다.
- [ ] write 성공 시 `true`를 반환하도록 통일한다.
- [ ] 예외 발생 시 Ruby Console에 최소한의 로그를 남기고 `false`를 반환한다.
- [ ] 기존 attribute key/value 구조는 변경하지 않는다.

## 테스트할 내용

- [ ] CellSpace 생성 시 attribute가 정상 저장된다.
- [ ] CellSpace 타입 변경 시 attribute가 정상 갱신된다.
- [ ] CellSpace 삭제 중 attribute write 예외가 없다.
- [ ] Undo/Redo 반복 중 Ruby Console에 attribute 관련 예외가 없다.
- [ ] 저장 후 재열기 시 runtime 복원이 정상이다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 7단계로 넘어가지 않는다.

---

# 7단계. Transformation 유틸 이름과 의미 정리

## 목표

active edit context에 의존하는 transformation 함수를 일반 world transformation처럼 오해하지 않도록 이름을 정리한다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/utils/transformation.rb
```

이전 후보:

```ruby
def self.entity_world_transformation(entity)
  Sketchup.active_model.edit_transform * entity.transformation
end
```

현재 상태:

```ruby
def self.entity_transformation_in_active_context(entity)
  Sketchup.active_model.edit_transform * entity.transformation
end
```

## 수정해야 하는 이유

이 함수는 이름상 world transformation처럼 보이지만 실제로는 `Sketchup.active_model.edit_transform`에 의존한다. active_path가 바뀌면 결과가 달라질 수 있다.

## Codex 작업 내용

- [x] `entity_world_transformation`의 실제 의미를 확인한다.
- [x] active context 기준 변환이라면 이름을 `entity_transformation_in_active_context`처럼 변경한다.
- [x] 호출부를 새 이름으로 수정한다.
- [x] 기존 함수명을 바로 제거하지 말고 deprecated wrapper로 남길지 판단한다. 내부 API라서 wrapper 없이 삭제했다.
- [x] 위치 계산 동작은 변경하지 않는다.

## 테스트할 내용

- [ ] 최상위 group을 CellSpace로 변환해도 위치가 변하지 않는다.
- [ ] PrimalSpaceFeatures 내부 group을 CellSpace로 변환해도 위치가 변하지 않는다.
- [ ] 편집 모드 안에서 새 group 생성 후 자동 CellSpace 변환이 정상이다.
- [ ] Undo/Redo 후 위치가 기존처럼 복구된다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 8단계로 넘어가지 않는다.

---

# 8단계. direct_child_of_root? 판정 명확화

## 목표

SketchUp entity parent 판정을 명확하게 만든다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/utils/transformation.rb
```

이전 후보:

```ruby
entity.parent == root_group.entities.parent
```

현재 상태:

```ruby
entity.parent == root_group.definition
```

## 수정해야 하는 이유

현재 코드는 동작할 수는 있지만 의도가 불명확하다. Group 내부 entities의 child parent가 무엇인지 SketchUp API 기준으로 명확히 고정해야 한다.

## Codex 작업 내용

- [x] `direct_child_of_root?`가 실제로 어떤 상황에서 호출되는지 확인한다.
- [x] 필요하면 임시 debug helper를 추가했다가 최종 커밋 전 제거한다.
- [x] `entity.parent`, `root_group.entities.parent`, `root_group.definition` 관계를 확인한다.
- [x] 의도에 맞는 명확한 조건식으로 변경한다.
- [x] 기존 방식 유지가 맞다면 주석으로 SketchUp parent 구조를 설명한다.

## 테스트할 내용

- [ ] Primal group 바로 아래 group 판정이 true다.
- [ ] Primal group 안의 group 안의 group 판정이 false다.
- [ ] 최상위 model.entities 아래 group 판정이 false다.
- [ ] ComponentInstance도 기존 의도대로 판정된다.
- [ ] CellSpace 변환 위치가 기존과 동일하다.
- [ ] Primal group 내부 CellSpace들을 다시 그룹으로 묶으면 wrapper group이 CellSpace로 변환되지 않고 내부 CellSpace들이 Primal group 직속으로 복구된다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 9단계로 넘어가지 않는다.

---

# 9단계. SceneGroupGuard 내부 책임 정리

## 목표

`SceneGroupGuard#enforce` 내부 책임을 작은 private method로 분리해서 재진입/복구 흐름을 추적하기 쉽게 만든다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/infrastructure/scene/scene_group_guard.rb
```

현재 책임:

```text
expected name 저장
last transform 저장
name 복구
scale 복구
transformation 동기화
unlock 처리
알림 요청
```

## 수정해야 하는 이유

현재 `SceneGroupGuard`는 정책, 상태, SketchUp mutation이 한곳에 모여 있다. 테스트와 디버깅을 어렵게 만든다.

## Codex 작업 내용

- [ ] `enforce`의 외부 동작을 유지한다.
- [ ] 내부 판단 로직을 private method로 분리한다.
- [ ] 이름 복구, 스케일 복구, transform 동기화를 각각 별도 method로 나눈다.
- [ ] `with_unlocked` 호출 범위를 기존과 동일하게 유지한다.
- [ ] notifier 호출 시점은 1단계에서 정한 지연 UI 정책을 유지한다.

권장 private method 예시:

```ruby
expected_name_for(group)
last_transform_for(group)
update_last_transform(group)
name_changed?(group)
scaled?(group)
transform_changed?(group)
restore_name_if_needed(group)
restore_scale_if_needed(group)
synchronize_transform_if_needed(group, groups)
```

## 테스트할 내용

- [ ] 이름 변경 복구가 정상이다.
- [ ] 스케일 변경 복구가 정상이다.
- [ ] Primal group 이동 시 기존과 같은 transform 동기화가 일어난다.
- [ ] CellSpace group 이동 시 기존과 같은 동작을 한다.
- [ ] Undo/Redo 후 guard 상태가 꼬이지 않는다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 10단계로 넘어가지 않는다.

---

# 10단계. RuntimeRestorer 생성자 의존성 정리

## 목표

`RuntimeRestorer` 생성자에 흩어진 의존성을 명확히 정리한다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/infrastructure/persistence/runtime_restorer.rb
indoor3d/application/indoor_model.rb
```

현재 후보:

```ruby
RuntimeRestorer.new(..., cell_space_registrar: method(...), state_registrar: method(...))
```

## 수정해야 하는 이유

복원 대상이 늘어날수록 method 주입이 계속 증가한다. 생성자 인자가 길어지면 복원 흐름 파악이 어려워진다.

## Codex 작업 내용

- [ ] 현재 `RuntimeRestorer` 생성자 인자를 확인한다.
- [ ] 기능 변경 없이 의존성 전달 구조만 정리한다.
- [ ] 필요하면 `callbacks` hash 또는 작은 context struct를 사용한다.
- [ ] 과도한 추상화는 하지 않는다.
- [ ] restore 동작과 attribute format은 변경하지 않는다.

예시 방향:

```ruby
RuntimeRestorer.new(
  registry: @feature_registry,
  serializer: @attribute_serializer,
  callbacks: {
    cell_space_registrar: method(:register_cell_space),
    state_registrar: method(:register_state)
  }
)
```

## 테스트할 내용

- [ ] 기존 모델 파일을 저장한다.
- [ ] SketchUp을 재시작한다.
- [ ] 파일을 다시 연다.
- [ ] CellSpace runtime이 복원된다.
- [ ] State 위치가 복원된다.
- [ ] Transition 정보가 기존처럼 동작한다.
- [ ] Export GML이 정상 동작한다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 11단계로 넘어가지 않는다.

---

# 11단계. 보류 - Undo/Redo 후 runtime refresh schedule 추가

## 목표

Undo/Redo 이후 SketchUp model 상태와 Ruby runtime registry 상태를 다시 동기화한다.

> 보류 결정: Undo/Redo는 SketchUp active_path, observer callback, transparent operation, runtime registry가 동시에 얽혀 있어 단순 schedule 추가만으로 해결되지 않을 수 있다. 구조를 바닥부터 다시 봐야 할 가능성이 있으므로, 이 단계는 즉시 진행하지 않고 최후방 치명적 버그 수정 단계로 미룬다.

## 이전 단계에서 미룬 이슈

- 2단계 테스트 중 확인: `primal_group` 내부 CellSpace를 이동/scale/rotate 한 뒤 Undo가 되지 않는 문제가 있다.
- 이 문제는 Observer 재진입 guard 명확화 범위를 벗어나며, 단순 runtime refresh schedule만으로 해결되지 않을 수 있다.
- Undo/Redo 관련 실패는 이 문서의 마지막 치명적 버그 수정 단계에서 active_path, lock policy, observer 재부착, runtime registry 동기화를 함께 검토한다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/infrastructure/observers/model_observer.rb
indoor3d/application/indoor_model/runtime_support.rb
indoor3d/application/indoor_model/observer_routing.rb
```

## 수정해야 하는 이유

Undo/Redo는 SketchUp model의 entity 상태를 바꾸지만 Ruby runtime registry가 자동으로 정확히 맞춰지지는 않는다. 삭제/복구/이동 후 stale runtime이 남을 수 있다.

## Codex 작업 내용

- [ ] SketchUp Ruby API에서 사용 가능한 transaction observer callback 이름을 현재 코드와 호환되게 확인한다.
- [ ] Undo/Redo 후 직접 refresh하지 말고 timer로 schedule한다.
- [ ] `schedule_runtime_refresh` 메서드를 추가한다.
- [ ] 중복 schedule을 방지하는 flag를 둔다.
- [ ] refresh 중 observer 재진입이 발생하지 않도록 기존 guard와 연동한다.

예시 방향:

```ruby
def schedule_runtime_refresh
  return if @runtime_refresh_scheduled

  @runtime_refresh_scheduled = true
  UI.start_timer(0, false) do
    @runtime_refresh_scheduled = false
    refresh_runtime_data
  end
end
```

## 테스트할 내용

- [ ] CellSpace 생성 후 Undo하면 runtime에서 제거된다.
- [ ] Redo하면 runtime에 다시 등록된다.
- [ ] CellSpace 이동 후 Undo하면 State/Transition 위치가 맞는다.
- [ ] CellSpace 이동 후 Redo하면 State/Transition 위치가 맞다.
- [ ] CellSpace 삭제 후 Undo하면 CellSpace/State/Transition이 다시 잡힌다.
- [ ] Export GML이 Undo/Redo 이후에도 예외 없이 실행된다.

## 단계 완료 조건

- [ ] Codex 작업 완료
- [ ] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 12단계로 넘어가지 않는다.

---

# 12단계. CellSpace dirty queue 도입

## 목표

Observer에서 CellSpace 변경을 즉시 처리하지 않고, 변경 표시 후 안전한 시점에 동기화한다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/application/indoor_model/observer_routing.rb
indoor3d/application/indoor_model/feature_lifecycle.rb
indoor3d/application/indoor_model/topology.rb
```

현재 후보:

```ruby
cell_space_changed(entity)
update_state_position
synchronize_adjacency_and_transitions_for_cell_space
```

## 수정해야 하는 이유

Observer callback 안에서 topology mutation을 바로 수행하면 SketchUp operation과 Undo stack이 꼬일 수 있다.

## Codex 작업 내용

- [ ] CellSpace 변경을 표시하는 dirty set을 추가한다.
- [ ] dirty key는 가능하면 `persistent_id`를 사용한다.
- [ ] dirty sync는 `UI.start_timer(0, false)`로 schedule한다.
- [ ] 같은 frame 안에서 여러 CellSpace가 변경되면 한 번에 처리한다.
- [ ] 기존 즉시 처리 흐름은 필요한 경우에만 유지한다.
- [ ] `onClose`처럼 origin recenter가 필요한 흐름은 별도로 판단하고 기존 동작을 깨지 않는다.

예시 방향:

```ruby
@dirty_cell_space_pids = {}
@cell_space_sync_scheduled = false
```

```ruby
def mark_cell_space_dirty(entity)
  pid = entity.persistent_id
  @dirty_cell_space_pids[pid] = true
  schedule_dirty_cell_space_sync
end
```

## 테스트할 내용

- [ ] CellSpace 이동 후 State가 따라온다.
- [ ] CellSpace 이동 후 Transition이 갱신된다.
- [ ] 여러 CellSpace를 연속 이동해도 중복 transition 생성이 없다.
- [ ] 이동 후 Undo 한 번으로 이동이 되돌아간다.
- [ ] 이동 후 Redo가 정상이다.
- [ ] Export GML이 이동 후에도 정상이다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 14단계로 넘어가지 않는다.

---

# 14단계. Transition 순환 참조 완화 준비

## 목표

`Transition`이 State/CellSpace 객체를 강하게 직접 참조하는 구조를 완화할 준비를 한다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/domain/transition.rb
indoor3d/application/feature_registry.rb
indoor3d/application/indoor_model/topology.rb
```

현재 구조:

```text
CellSpace -> State
State -> Transition
Transition -> State1, State2
Transition -> Cell1, Cell2
```

## 수정해야 하는 이유

Ruby GC는 순환 참조를 처리할 수 있지만, SketchUp Entity wrapper와 observer가 함께 얽히면 수명 관리가 어려워진다. 우선 id 기반 참조를 병행 저장해서 이후 전환을 준비한다.

## Codex 작업 내용

- [ ] `Transition`에 state/cell id 저장 필드를 추가한다.
- [ ] 기존 객체 참조는 아직 제거하지 않는다.
- [ ] export/serialize에서 기존 결과가 바뀌지 않게 한다.
- [ ] transition 생성 시 id 필드가 채워지도록 한다.
- [ ] transition 삭제 시 id 기반으로도 추적 가능하게 준비한다.
- [ ] 이 단계에서는 대규모 구조 변경을 하지 않는다.

예시 방향:

```ruby
@state1_id
@state2_id
@cell1_id
@cell2_id
```

## 테스트할 내용

- [ ] Transition 생성이 정상이다.
- [ ] Transition 삭제가 정상이다.
- [ ] CellSpace 삭제 시 연결 Transition이 삭제된다.
- [ ] Export GML의 transition 관련 id가 기존과 동일하다.
- [ ] Overlay에서 transition 표시가 정상이다.
- [ ] Undo/Redo 후 transition이 중복 생성되지 않는다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 15단계로 넘어가지 않는다.

---

# 15단계. IndoorModel.current 호환 유지하며 모델별 인스턴스 준비

## 목표

전역 singleton 구조를 유지하면서도 모델별 인스턴스로 전환할 수 있는 호환 레이어를 추가한다.

## 수정해야 할 부분

주요 파일:

```text
indoor3d/application/indoor_model.rb
indoor3d/infrastructure/observers/app_observer.rb
indoor3d/infrastructure/observers/model_observer.rb
indoor3d/core.rb
```

현재 구조:

```ruby
def self.current
  @current ||= new
end
```

## 수정해야 하는 이유

SketchUp은 여러 모델/문서를 열 수 있다. 전역 singleton은 모델 A의 runtime 상태가 모델 B에 섞일 수 있다.

## Codex 작업 내용

- [x] `IndoorModel.for(model = Sketchup.active_model)` 메서드를 추가한다.
- [x] `IndoorModel.current`는 기존 호환을 위해 `for(Sketchup.active_model)`을 호출하게 한다.
- [x] `initialize`는 model 인자를 받을 수 있게 한다.
- [x] AppObserver / ModelObserver에서 model을 받을 수 있는 곳은 `IndoorModel.for(model)`을 사용한다.
- [x] 기존 호출부를 한 번에 모두 바꾸지 않는다.
- [x] 현재 모델 기준 동작이 깨지지 않게 한다.

예시 방향:

```ruby
def self.for(model = Sketchup.active_model)
  @instances ||= {}
  key = model.object_id
  @instances[key] ||= new(model)
end

def self.current
  for(Sketchup.active_model)
end
```

## 테스트할 내용

- [ ] 모델 A에서 CellSpace를 생성한다.
- [ ] 모델 B를 새로 만든다.
- [ ] 모델 B에서 CellSpace를 생성한다.
- [ ] 모델 A로 돌아갔을 때 A의 runtime 상태가 유지된다.
- [ ] 모델 B로 돌아갔을 때 B의 runtime 상태가 유지된다.
- [ ] A/B의 CellSpace 개수가 섞이지 않는다.
- [ ] 현재 모델 기준 Export GML이 정상이다.
- [ ] Undo/Redo가 모델별로 정상이다.

## 단계 완료 조건

- [x] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

> 다음 단계 진행 금지 조건: `실제 SketchUp 테스트 완료`가 체크되지 않았다면 추가 리팩토링으로 넘어가지 않는다.

---

# 마지막 단계. 치명적 버그 수정 - EditMode CellSpace 복붙 중복

## 목표

EditMode에서 발견된 치명적 기능 버그를 리팩토링 완료 후 별도로 수정한다.

## 현재 확인된 문제

### CellSpace 복사/붙여넣기 중복

EditMode에서 CellSpace entity를 복사/붙여넣기 하면 원본 CellSpace의 IndoorGML attribute가 그대로 복사된다. 그 결과 복제본이 원본과 같은 CellSpace id, feature metadata, duality/state 연결 정보를 가진 것처럼 보일 수 있다.

### Ctrl+Z 후 EditMode active_path/lock 불일치

0단계 기준 코드에서도 재현됨. EditMode 진입 상태에서 `Ctrl+Z`를 누르면 EditMode UI/상태는 켜진 채로 SketchUp editing context가 root entities로 빠질 수 있다. 이때 `primal_group`이 unlock 상태로 남아 사용자가 primal group을 이동/회전할 수 있고, 그 결과 내부 CellSpace 좌표/관계가 손상될 수 있다.

### Undo/Redo 구조 불안정

Undo/Redo는 단순 runtime refresh schedule만으로 해결되지 않을 수 있다. SketchUp active_path 변경이 undo stack에 들어가고, observer callback과 transparent operation이 사용자 작업과 분리되어 기록될 수 있으며, Redo 후 observer/runtime 상태가 기대대로 복구되지 않는 사례가 있다. 이 문제는 단계별 리팩토링을 계속 막지 않도록 최후방으로 미루고, 마지막 단계에서 구조적으로 다시 검토한다.

## 수정해야 하는 이유

CellSpace는 IndoorGML feature identity를 가져야 하며, 복사본이 원본과 같은 id/duality 정보를 유지하면 runtime registry, State/Transition 연결, Export GML 결과가 손상될 수 있다.

또한 EditMode 상태와 SketchUp active_path/lock 상태가 어긋나면 보호되어야 할 `primal_group`이 조작 가능해지고, 내부 CellSpace geometry와 topology가 깨질 수 있다. 이 문제들은 리팩토링 단계 중 확인된 기존 치명적 기능 버그이므로, 단계별 리팩토링을 마친 뒤 별도 마지막 단계에서 수정한다.

Undo/Redo 불안정성은 개별 observer guard나 단순 refresh timing의 문제가 아닐 수 있다. active_path 전환, edit mode 상태, lock policy, transparent operation, runtime registry 재구성을 함께 보지 않으면 부분 수정이 다른 동작을 다시 깨뜨릴 위험이 크다.

## Codex 작업 내용

- [ ] EditMode에서 CellSpace 복사/붙여넣기 시 어떤 observer callback이 발생하는지 확인한다.
- [ ] 복사된 entity가 기존 IndoorGML attribute를 그대로 가진 상태로 들어오는지 확인한다.
- [ ] 복사본을 새 CellSpace로 취급할지, 복사 자체를 막을지 정책을 결정한다.
- [ ] 새 CellSpace로 취급하는 경우 기존 id/duality/transition 관련 attribute를 재생성한다.
- [ ] 복사를 막는 경우 사용자에게 안전하게 되돌리거나 원본 외 복제본을 제거한다.
- [ ] Export GML에 중복 CellSpace id가 나오지 않도록 한다.
- [ ] EditMode 중 `Ctrl+Z`로 active_path가 root로 빠지는지 확인한다.
- [ ] active_path가 root로 빠져도 EditMode를 종료하거나 target edit context를 복구한다.
- [ ] EditMode 상태에서 `primal_group`이 이동/회전 가능하게 unlock 상태로 남지 않도록 한다.
- [ ] Undo/Redo 처리 방향을 runtime refresh schedule만으로 해결할지, edit mode/observer/runtime 구조를 함께 수정해야 하는지 결정한다.
- [ ] Redo 후 observer/runtime 상태가 복구되지 않는 원인을 별도로 확인한다.
- [ ] transparent operation이 사용자 작업의 Undo/Redo 단위와 어떻게 결합되는지 재검토한다.

## 테스트할 내용

- [ ] EditMode에서 CellSpace를 복사/붙여넣기 한다.
- [ ] 원본과 복사본의 CellSpace id가 중복되지 않는다.
- [ ] 복사본의 State/Transition이 원본과 섞이지 않는다.
- [ ] Undo/Redo 후 원본과 복사본의 runtime 상태가 유지된다.
- [ ] Export GML에 중복 `gml:id`가 없다.
- [ ] EditMode에서 `Ctrl+Z` 후 active_path/lock 상태가 일관된다.
- [ ] EditMode에서 `Ctrl+Z` 후 `primal_group`을 이동/회전할 수 없다.
- [ ] 기존 CellSpace 생성/이동/삭제 동작이 유지된다.

## 단계 완료 조건

- [ ] Codex 작업 완료
- [x] 실제 SketchUp 테스트 완료 - 사용자만 체크

---

# 단계별 진행 현황 요약

Codex는 이 표에서 `Codex 작업 완료`만 체크할 수 있다. `실제 SketchUp 테스트 완료`는 사용자만 체크한다.

|   단계 | 작업                                                   | Codex 작업 완료 | 실제 SketchUp 테스트 완료 |
| -----: | ------------------------------------------------------ | --------------- | ------------------------- |
|      0 | 리팩토링 전 기준 동작 고정                             | [x]             | [ ]                       |
|      1 | Observer 내부 modal UI 제거                            | [x]             | [ ]                       |
|      2 | Observer 재진입 guard 명확화                           | [x]             | [ ]                       |
|      3 | Observer attach 로직 통일                              | [x]             | [ ]                       |
|      4 | FeatureRegistry key 이름 정리                          | [x]             | [ ]                       |
|      5 | Feature 객체 valid accessor 추가                       | [x]             | [ ]                       |
|      6 | AttributeSerializer write 방어 강화                    | [x]             | [ ]                       |
|      7 | Transformation 유틸 이름과 의미 정리                   | [x]             | [ ]                       |
|      8 | direct_child_of_root? 판정 명확화                      | [x]             | [ ]                       |
|      9 | SceneGroupGuard 내부 책임 정리                         | [x]             | [x]                       |
|     10 | RuntimeRestorer 생성자 의존성 정리                     | [x]             | [x]                       |
|     11 | 보류 - Undo/Redo 후 runtime refresh schedule 추가      | [ ]             | [ ]                       |
|     12 | CellSpace dirty queue 도입                             | [x]             | [x]                       |
|     14 | Transition 순환 참조 완화 준비                         | [x]             | [ ]                       |
|     15 | IndoorModel.current 호환 유지하며 모델별 인스턴스 준비 | [x]             | [ ]                       |
| 마지막 | 치명적 버그 수정 - EditMode CellSpace 복붙 중복        | [ ]             | [ ]                       |

---

# Codex 작업 지시 공통 문구

각 단계 시작 시 Codex에게 다음 원칙을 함께 전달한다.

```text
이번 작업은 RefactorTODO.md의 현재 단계만 수행한다.
다음 단계는 수행하지 않는다.
스타일 변경, 포맷팅 변경, 불필요한 네이밍 변경은 하지 않는다.
기능 변경은 하지 않는다.
수정 후 어떤 파일을 바꿨는지, 왜 바꿨는지, 어떤 수동 테스트가 필요한지 요약한다.
Codex는 실제 SketchUp 테스트 완료 체크박스를 체크하지 않는다.
실제 SketchUp 테스트 완료가 체크되어 있지 않으면 다음 단계로 넘어가지 않는다.
```
