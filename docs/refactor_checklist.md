# 리팩토링 기준 수동 테스트 체크리스트

이 문서는 단계별 리팩토링을 진행하기 전에 현재 기대 동작을 고정하기 위한
수동 테스트 체크리스트다. 각 리팩토링 단계 이후 SketchUp 2026에서 기존 동작이
유지되는지 확인하는 기준으로 사용한다.

## 범위

- SketchUp 버전: SketchUp 2026
- 확장 프로그램: IndoorGML SketchUp extension
- IndoorGML 대상 버전: IndoorGML 1.0.3
- 목적: 구현 구조를 리팩토링하는 동안 기능 동작이 바뀌지 않았는지 확인한다.

## 기준 테스트 시나리오

### 플러그인 로드

- [x] SketchUp 2026을 실행한다.
- [x] IndoorGML 확장 프로그램이 Ruby Console 예외 없이 로드되는지 확인한다.
- [x] IndoorGML 툴바 또는 메뉴 명령이 표시되는지 확인한다.

### IndoorGML 필수 그룹

- [x] 확장 프로그램이 로드된 모델을 새로 만들거나 연다.
- [x] IndoorGML 장면 구조를 초기화하는 워크플로를 실행한다.
- [x] 예상되는 IndoorGML 루트 그룹과 PrimalSpaceFeatures 그룹이 생성되는지 확인한다.
- [x] 보호 대상 장면 그룹의 이름과 transform이 기존처럼 유지되는지 확인한다.

### CellSpace 생성

- [x] CellSpace로 변환할 수 있는 유효한 geometry를 선택한다.
- [x] `Create CellSpace`를 실행한다.
- [x] CellSpace group이 생성되는지 확인한다.
- [x] CellSpace에 대응하는 State가 생성되는지 확인한다.
- [x] 예상 attribute가 저장되는지 확인한다.

### CellSpace 속성 변경

- [x] 기존 CellSpace를 선택한다.
- [x] 편집 가능한 CellSpace 속성을 변경한다.
- [x] 화면 표시와 저장된 attribute가 선택한 값과 일치하는지 확인한다.
- [x] Ruby Console에 예외가 발생하지 않는지 확인한다.

### CellSpace 이동

- [x] 기존 CellSpace를 이동한다.
- [x] State가 CellSpace 이동을 따라가는지 확인한다.
- [x] 관련 Transition geometry가 기존처럼 갱신되는지 확인한다.
- [x] adjacency 동작이 기존과 동일한지 확인한다.

### CellSpace 삭제

- [x] 기존 CellSpace를 삭제한다.
- [x] 연결된 runtime 객체와 표시 요소가 기존처럼 제거되는지 확인한다.
- [x] 하나의 CellSpace 삭제가 다른 CellSpace를 손상시키지 않는지 확인한다.
- [x] Ruby Console에 예외가 발생하지 않는지 확인한다.

### Undo

- [x] CellSpace 생성을 Undo한다.
- [x] CellSpace 속성 변경을 Undo한다.
- [x] CellSpace 이동을 Undo한다.
- [x] CellSpace 삭제를 Undo한다.
- [x] runtime data, State, Transition, attribute가 이전 기대 상태로 돌아가는지 확인한다.

### Redo

- [x] CellSpace 생성을 Redo한다.
- [x] CellSpace 속성 변경을 Redo한다.
- [x] CellSpace 이동을 Redo한다.
- [x] CellSpace 삭제를 Redo한다.
- [x] runtime data, State, Transition, attribute가 Redo 이후 기대 상태로 돌아가는지 확인한다.

### Export GML

- [x] CellSpace가 있는 모델에서 `Export GML`을 실행한다.
- [x] 예외 없이 export가 완료되는지 확인한다.
- [x] export된 파일에 예상 IndoorGML 내용이 포함되는지 확인한다.

### Check Validity

- [x] 대표 모델에서 `Check Validity`를 실행한다.
- [x] 예외 없이 명령이 완료되는지 확인한다.
- [x] 보고되는 validity 결과가 모델 상태와 일치하는지 확인한다.

## 단계별 회귀 테스트 메모

- [x] 각 리팩토링 단계 이후 위 기준 시나리오 중 관련 항목을 반복한다.
- [x] 각 단계마다 Undo와 Redo 확인을 포함한다.
- [x] SketchUp 수동 테스트가 완료되기 전에는 다음 단계로 진행하지 않는다.
- [x] Ruby Console 예외가 발생하면 다음 단계로 진행하기 전에 기록하고 수정한다.

## 0단계 코드 변경 범위

- [x] 0단계는 문서만 추가한다.
- [x] 0단계에서는 Ruby 코드를 변경하지 않는다.
- [x] 0단계에서는 기능 동작, UI 문구, 데이터 형식, 스타일을 변경하지 않는다.
