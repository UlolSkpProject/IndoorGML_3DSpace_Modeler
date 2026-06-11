# TODO: Create CellSpace Geometry Validation

## 목적

Create CellSpace 실행 전에 선택된 solid group의 geometry를 검사하고, 변환 가능한 형상만 CellSpace로 생성한다.

현재 SketchUp에서는 한 group 안에 서로 떨어진 여러 shell이 있어도 `manifold?`가 true로 나올 수 있다. 이런 경우 IndoorGML CellSpace로 바로 변환하면 실제로는 하나의 cell이 아닌 여러 solid가 하나의 CellSpace에 들어가게 되므로, 변환 전에 감지해서 실패 처리한다.

또한 solid 내부에 reversed face가 있으면 export 시 polygon orientation 문제가 발생할 수 있으므로, CellSpace 생성 전에 shell 기준으로 face 방향을 보정한다.

## 현재 Create CellSpace 흐름

1. 선택된 solid group을 확인한다.
2. toolbar / extension menu 경로에서는 active context 안의 group을 root context로 옮긴다.
3. RM_helper attr dict가 있으면 RM_helper mapping을 우선 적용한다.
4. `convert_single_group_to_cell_space`에서 CellSpace group으로 배치하고 runtime feature를 생성한다.
5. edit mode dialog에서도 최종적으로 같은 변환 메서드를 사용한다.

## 변경할 Create CellSpace 흐름

1. 선택된 group을 root context로 옮긴다.
2. disconnected shell 여부를 검사한다.
3. disconnected shell이 있으면 CellSpace로 변환하지 않고 실패 목록에 넣는다.
4. 변환 가능한 single shell solid에 대해 reversed face를 검사하고 보정한다.
5. 보정된 solid만 CellSpace로 변환한다.
6. batch 변환이 끝나면 실패한 solid 목록을 사용자에게 보여준다.
7. 실패 solid는 edge를 따라 3D overlay로 highlight한다.
8. message box를 닫으면 highlight가 약 1초 동안 fade out되며 사라진다.

## Disconnected Solid 검사

- group 내부의 face들을 shared edge 기준으로 connected component로 묶는다.
- component 수가 1개면 single shell 후보로 본다.
- component 수가 2개 이상이면 disconnected solid로 판단한다.
- disconnected solid는 자동 분리하지 않는다.

이유:
- 원본 group이나 component에 attr dict가 있을 수 있다.
- 자동 분리하면 RM_helper 등 metadata를 어떤 component에 어떻게 전달할지 애매하다.
- 따라서 현재 단계에서는 impossible 목록에 넣고 사용자에게 직접 수정하도록 안내한다.

## Reversed Face 판별 및 보정

개별 face의 `face.normal`만 신뢰하지 않는다. shell 전체의 topology 기준으로 reversed 여부를 판단한다.

판별 방식:

1. face graph를 만든다.
2. 두 face가 edge를 공유하면 인접 face로 연결한다.
3. 올바른 closed shell에서는 shared edge를 두 face가 서로 반대 방향으로 순회해야 한다.
   - face A: `v1 -> v2`
   - face B: `v2 -> v1`
4. 이 규칙으로 face orientation을 component 전체에 전파한다.
5. 전파된 orientation으로 signed volume을 계산한다.
6. signed volume이 inward 방향이면 전체 desired orientation을 반전한다.
7. 현재 SketchUp face 방향이 desired orientation과 다른 face에 `face.reverse!`를 호출한다.

즉 reversed face는 다음 기준으로 판단한다.

> shell 전체 orientation을 일관화했을 때 현재 face 방향이 desired orientation과 반대인 face

## 실패 처리

- disconnected shell group은 CellSpace 변환을 하지 않는다.
- batch 변환 중 실패 목록에 추가한다.
- 변환 완료 후 message box에 실패 group 이름 또는 entity id를 보여준다.
- 실패 group의 component boundary 또는 전체 edge를 overlay로 highlight한다.
- message box가 닫히면 highlight는 1초 동안 fade out 후 자동 제거한다.

## Overlay 계획

- 기존 `EditModeOverlay` 또는 별도 temporary overlay에 highlight state를 추가한다.
- highlight state는 다음 정보를 가진다.
  - edge point pairs
  - color
  - start time
  - duration
  - alpha
- draw 단계에서 `GL_LINES`로 edge를 표시한다.
- timer 또는 view invalidation loop로 alpha를 줄인다.
- duration이 끝나면 highlight state를 clear한다.

## 구현 후보 위치

- Geometry 분석:
  - `indoor3d/utils/geometry.rb`
- Create CellSpace 공통 변환 전 처리:
  - `indoor3d/application/indoor_model/feature_lifecycle.rb`
- toolbar / extension menu batch 실패 메시지:
  - `indoor3d/core.rb`
- edit mode dialog batch 실패 메시지:
  - `indoor3d/application/indoor_model/editor_control.rb`
- temporary 3D highlight:
  - `indoor3d/ui/edit_mode_overlay.rb`
  - 또는 별도 overlay class 추가

## 테스트 시나리오

1. 정상 cube 1개
   - CellSpace 1개 생성
   - 실패 없음

2. face 하나가 뒤집힌 cube
   - reversed face 자동 보정
   - CellSpace 1개 생성
   - export validity 통과

3. 한 group 안에 떨어진 cube 2개
   - CellSpace 생성 안 함
   - 실패 목록에 표시
   - 두 component edge highlight

4. RM_helper attr dict가 있는 disconnected group
   - 자동 분리하지 않음
   - 실패 목록에 표시
   - attr dict 손실 없음

5. toolbar / extension menu와 edit mode dialog
   - 동일한 검사/보정/실패 동작을 수행