# P0-2 Undo/Redo Replay Flow

이 문서는 CellSpace 관련 작업에서 `Undo` 이후 `Redo`가 사라지던 문제와 P0-2 수정의 코드 흐름을 정리한다.

## 1. 기존 방법의 문제

기존 구조는 Undo/Redo를 "사용자 변경 이후의 일반 모델 변경"과 충분히 구분하지 않았다.

SketchUp이 Undo/Redo로 모델을 복원하면 CellSpace group의 transformation, attribute, entity add/remove 이벤트가 다시 발생한다. 기존 코드는 이 이벤트를 일반 사용자 편집처럼 처리했다.

대표적인 위험 경로는 다음과 같았다.

- `ModelObserver#onTransactionUndo` / `onTransactionRedo`
- timer callback
- `IndoorModel#reconcile_runtime_after_transaction`
- active path handling
- `recover_unlocked_primal_after_transaction`
- `EditorSession#begin_editing`
- `apply_lock_policy`
- `model.active_path = ...`
- `entity.locked = ...`

이 흐름은 runtime을 복구하는 것처럼 보이지만, 실제로는 Undo 직후 SketchUp 모델을 다시 수정할 수 있었다. Undo 직후 새로운 모델 변경이나 transparent operation이 만들어지면 SketchUp의 기존 Redo stack이 무효화될 수 있다.

또 다른 위험 경로는 transform observer였다.

- `CellSpaceObserver#onChangeEntity`
- `IndoorModel#cell_space_changed`
- `handle_cell_space_transform_changed`
- `with_transparent_cell_space_operation('IndoorGML CellSpace Transform Change')`
- `mark_cell_space_dirty`
- dirty sync timer 예약

여기서 transform handler는 실제 모델을 바로 수정하지 않고 Ruby dirty queue와 timer만 갱신했는데도 transparent operation을 열었다. Undo/Redo replay 중 이런 후처리가 실행되면 Redo stack을 끊을 수 있다.

## 2. 버그가 발생하는 예시와 그 때 흐름

예시는 EditMode에서 CellSpace를 이동한 뒤 Undo/Redo를 실행하는 경우다. Move 자체는 SketchUp 기본 operation이다.

### 기존 흐름

1. 사용자가 CellSpace를 이동한다.
2. SketchUp이 Move operation을 commit한다.
3. `CellSpaceObserver#onChangeEntity`가 호출된다.
4. `cell_space_changed`가 transformation 변경으로 분류한다.
5. `handle_cell_space_transform_changed`가 transparent operation을 열고 dirty sync timer를 예약한다.
6. 사용자가 Undo를 실행한다.
7. SketchUp이 CellSpace transformation을 이전 값으로 복원한다.
8. Undo 과정에서 `onChangeEntity`, `onElementAdded`, `onElementRemoved`, `onActivePathChanged`, `onTransactionUndo`가 다시 발생할 수 있다.
9. 기존 observer는 이 이벤트를 일반 변경처럼 처리한다.
10. transaction timer가 `recover_unlocked_primal_after_transaction`을 호출할 수 있다.
11. 이 경로가 `begin_editing`으로 이어지면 `active_path=`와 `locked=`가 실행될 수 있다.
12. Undo 직후 플러그인이 새 모델 변경을 만든다.
13. SketchUp의 Redo stack이 사라진다.
14. 사용자가 Redo를 눌러도 방금 Undo한 Move operation이 다시 적용되지 않는다.

Solid to CellSpace 변환도 같은 구조로 깨질 수 있었다. 변환 operation 자체가 문제가 아니라, Undo로 Solid/CellSpace entity 상태가 복원된 뒤 observer 후처리가 다시 모델을 만지는 것이 문제였다.

## 3. 해결 방법

P0-2의 핵심 원칙은 다음이다.

Undo/Redo replay 중에는 SketchUp 모델을 고치지 않는다. 현재 SketchUp 모델을 source of truth로 보고 Ruby runtime과 EditMode cache만 맞춘다.

이번 수정은 다음을 적용했다.

- `IndoorModel`에 모델별 transaction replay state를 추가했다.
- `ModelObserver#onTransactionUndo` / `onTransactionRedo`가 호출되면 즉시 replay pending을 켠다.
- replay generation을 증가시켜 오래된 timer callback을 무효화한다.
- replay pending 동안 active path enforcement와 EditMode 자동 재진입을 하지 않는다.
- replay pending 동안 CellSpace, Primal, Root, SpaceFeatures observer의 persistent 후처리를 막는다.
- Undo/Redo 시작 시 기존 dirty queue와 예약된 dirty sync timer를 generation으로 무효화한다.
- transform dirty mark에서는 더 이상 transparent operation을 열지 않는다.
- 최신 transaction replay timer만 read-only runtime reconciliation을 실행한다.
- reconciliation이 끝나면 같은 generation일 때만 replay pending을 해제한다.

허용되는 replay 작업은 Ruby runtime 복구와 cache 갱신이다.

- 현재 모델 탐색
- CellSpace/State runtime registry 재구축
- runtime-only Transition 재계산
- observer tracking Hash 재구축
- SceneGroupGuard tracking 재구축
- EditMode target/cache reconciliation
- dialog update
- overlay cache invalidate
- view invalidate

금지되는 replay 작업은 SketchUp 모델 write다.

- `model.active_path = ...`
- `model.close_active`
- `entity.locked = ...`
- `entity.hidden = ...`
- `entity.visible = ...`
- `set_attribute`
- entity 생성/삭제/이동
- persistent Transition/State/CellSpace attribute write
- `start_operation`
- transparent operation
- EditMode 자동 재진입

## 4. 같은 동작에 대한 변경 후 코드 흐름

같은 CellSpace 이동 후 Undo/Redo 흐름은 이제 다음과 같다.

### 이동 수행

1. 사용자가 CellSpace를 이동한다.
2. SketchUp이 Move operation을 commit한다.
3. `CellSpaceObserver#onChangeEntity`가 호출된다.
4. `IndoorModel#cell_space_changed`가 transformation 변경으로 분류한다.
5. `handle_cell_space_transform_changed`는 transparent operation을 열지 않는다.
6. `sync { mark_cell_space_dirty(cell_space) }`만 실행한다.
7. dirty sync timer가 예약된다.

### Undo 시작

1. 사용자가 Undo를 실행한다.
2. `ModelObserver#onTransactionUndo`가 호출된다.
3. `IndoorModel#begin_transaction_replay(source: :undo, generation: n)`이 실행된다.
4. dirty queue가 clear되고 dirty sync generation이 증가한다.
5. 이전에 예약된 dirty timer는 generation mismatch로 no-op 된다.
6. replay pending 상태가 켜진다.

### Undo 중 observer 이벤트

Undo로 transformation이나 entity 상태가 복원되면서 observer callback이 발생할 수 있다.

이때 replay pending 상태이므로 다음 경로는 no-op 된다.

- `cell_space_changed`
- `cell_space_closed`
- `cell_space_erased`
- `root_entity_added`
- `primal_entity_added`
- `primal_entity_removed`
- `space_features_changed`

따라서 replay 중에는 다음이 발생하지 않는다.

- transparent operation
- attribute write
- recenter
- name/material 보정
- adjacency persistent sync
- entity relocation
- lock policy

### Undo transaction timer

1. 최신 generation timer만 실행된다.
2. `IndoorModel#reconcile_runtime_after_transaction(source: :undo, generation: n)`이 실행된다.
3. 현재 SketchUp 모델을 읽어서 runtime을 재구축한다.
4. `rebuild_runtime_transitions_from_cell_adjacency_without_persistence`가 runtime-only Transition을 만든다.
5. `EditorSession#reconcile_after_transaction`은 replay mode를 감지한다.
6. `EditActivePathController#reconcile_transaction_replay_path`가 현재 active path를 읽고 target/cache만 갱신한다.
7. `model.active_path = ...`는 호출하지 않는다.
8. `begin_editing`은 호출하지 않는다.
9. `recover_unlocked_primal_after_transaction`은 replay 경로에서 호출되지 않는다.
10. 같은 generation이면 `finish_transaction_replay`가 pending을 해제한다.

### Redo

1. 사용자가 Redo를 실행한다.
2. Undo 직후 플러그인이 새 모델 transaction을 만들지 않았으므로 SketchUp Redo stack이 유지되어 있다.
3. SketchUp이 Move operation을 다시 적용한다.
4. Redo replay도 Undo와 같은 read-only 경로를 탄다.
5. runtime은 Redo 후 모델 상태에 맞게 재구축된다.

결과적으로 `Do -> Undo -> Redo -> Undo`가 CellSpace 생성, 이동, 회전, 스케일, 삭제, type 변경에서 정상적으로 왕복한다.

## 5. 이번 수정에서 일부러 하지 않은 것

이번 P0-2 수정은 Undo/Redo replay 중 모델 write를 막는 데 집중한다.

다음은 후속 이슈로 남긴다.

- Primal group 제거
- bulk conversion의 root close/restore 제거
- active path ancestor cleanup 구조 변경
- EditMode suspended UX 정리
- persistent adjacency 기록 시점 재설계

Primal group은 유지한다. 현재 CellSpace 배치는 이미 `@primal_group.entities`에 직접 복사하고 Primal local transformation을 계산하는 구조다. 따라서 P0-2의 핵심은 Primal group이 아니라 replay 중 observer side effect를 막는 것이다.
