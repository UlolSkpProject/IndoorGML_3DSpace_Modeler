# LVN maintenance tools

이 디렉터리의 LVN 도구는 검사 모드와 독립된 유지보수·회귀 확인용 스크립트다.
제품 loader에서는 자동으로 불러오지 않으며, 필요한 도구만 SketchUp Ruby Console에서 `load`한다.

## Retained tools

| File | Responsibility | Model mutation |
| --- | --- | --- |
| `lvn_all_cell_spaces_regression.rb` | 전체 CellSpace 정규화 결과와 모델 context 보존 확인 | LVN 실행 |
| `lvn_selected_cell_spaces_regression.rb` | 선택한 CellSpace의 정규화와 edit/root context 전환 확인 | LVN 실행 |
| `lvn_failure_recovery_regression.rb` | 실패 rollback, 동일 geometry 생략, geometry 변경 후 재시도 확인 | 의도적 실패와 미세 geometry 변경 |
| `lvn_undo_redo_regression.rb` | 전체 LVN이 단일 Undo/Redo history 항목으로 동작하는지 수동 확인 | LVN 실행 후 수동 Undo/Redo 필요 |
| `lvn_topology_change_diagnostic.rb` | LVN 전후 Transition·adjacency pair 차이 진단 | LVN 실행 |

## Naming policy

- `regression`: 성공 계약을 반복 검증하는 도구
- `diagnostic`: 성공 여부와 분리된 변화 정보를 수집하는 도구
- `smoke`, `probe`, 작업 브랜치명, 검사 모드명은 새 도구 이름에 사용하지 않는다.
- 제품 코드의 공개 API, report key, 저장된 attribute 이름은 별도 migration 없이 변경하지 않는다.

## Execution

```ruby
root = File.dirname(ULOL::Indoor3DGmlModeler::EXTENSION.extension_path)
load File.join(root, 'dev', '<tool_file>.rb')
nil
```

각 파일은 load 직후 `run`을 1회 실행한다. `lvn_undo_redo_regression.rb`만 화면 안내에 따라 `inspect_after_undo`, `inspect_after_redo`를 추가로 호출한다.
