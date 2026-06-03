# AnchorNode 정리

## 개념

legacy project의 AnchorNode는 IndoorGML 표준 element라기보다, Node에 외부 지도 좌표 anchor를 붙이기 위한 application-specific 기능이다.

일반 Node는 SketchUp 모델 내부의 좌표를 가진다. AnchorNode 기능은 선택된 Node에 위경도와 회전값을 연결해서, 실내 모델 좌표와 외부 지도 좌표 사이의 기준점을 만드는 용도로 보인다.

## IndoorGML 기준

IndoorGML 1.0 schema에는 `AnchorNode` 또는 `AnchorNodeMarker` 같은 공식 element가 없다.

IndoorGML navigation schema에는 `AnchorSpace`가 있지만, legacy AnchorNode와 직접 같은 개념은 아니다.

- `AnchorSpace`: 실내 공간과 외부 공간을 연결하는 opening space 계열의 CellSpace
- legacy AnchorNode: 특정 Node에 지도 좌표와 회전값을 붙이는 별도 도구 기반 기능

따라서 AnchorNode는 현재 IndoorGML export 대상에 포함하지 않는다.

## Legacy Project의 AnchorNodeMarker

legacy project에는 `AnchorNodeMarker`라는 별도 Windows 실행 파일이 있다.

경로:

```txt
C:\ProgramData\SketchUp\SketchUp 2026\SketchUp\Devs\INDOOR_GML_MODELER\AnchorNodeMarker
```

주요 파일:

- `AnchorNodeMarker.exe`
- `AnchorNodeMarker.exe.config`
- `AnchorNodeMarker.pdb`
- `GMap.NET.Core.dll`
- `GMap.NET.WindowsForms.dll`
- `GeoAPI.dll`
- `Proj4Net.dll`
- `netDxf.dll`

`AnchorNodeMarker.exe.config` 기준으로 `.NET Framework 4.6.1` Windows application이다.

관련 DLL 추정 역할:

- `GMap.NET.Core.dll`: 지도 tile/provider/위경도 좌표 등 지도 핵심 기능
- `GMap.NET.WindowsForms.dll`: Windows Forms 지도 UI control
- `GeoAPI.dll`: geometry interface
- `Proj4Net.dll`: 좌표계 변환
- `netDxf.dll`: DXF 읽기/쓰기 또는 CAD geometry 연동
- `.pdb`: 디버깅 symbol
- `.xml`: DLL API 문서

## Legacy 실행 흐름

legacy toolbar의 `Create Anchor Node` 기능은 다음 순서로 동작한다.

1. 사용자가 Node component를 선택한다.
2. 선택된 component에서 runtime Node를 찾는다.
3. 모든 Cell의 모든 Face outer loop를 2D outline으로 변환한다.
4. `C:/Users/Public/Documents/outline.txt`에 outline 데이터를 쓴다.
5. `AnchorNodeMarker.exe`를 실행한다.
6. 외부 exe가 `C:/Users/Public/Documents/anchor.txt`를 생성하거나 갱신한다.
7. Ruby가 `anchor.txt`를 읽어서 선택된 Node의 `anchor`에 저장한다.

## outline.txt 입력 규칙

`outline.txt`는 AnchorNodeMarker.exe의 입력 파일로 사용된다.

파일 경로:

```txt
C:/Users/Public/Documents/outline.txt
```

작성 대상:

- legacy runtime의 `@cells`
- 각 Cell의 `group`
- 각 group 내부의 `Sketchup::Face`
- 각 Face의 `outer_loop`

작성 방식:

- Face 하나마다 `@@@` delimiter로 시작한다.
- 각 vertex는 `x,y` 한 줄로 기록한다.
- group transformation을 적용한 world 좌표를 사용한다.
- `z`는 강제로 `0`으로 만든다.
- 마지막에 첫 vertex를 다시 추가해서 ring을 닫는다.

형식:

```txt
@@@
x1,y1
x2,y2
x3,y3
...
x1,y1
@@@
x1,y1
x2,y2
...
```

실제 예:

```txt
@@@
~ 2225 mm,~ -950 mm
~ 2225 mm,~ -2733 mm
~ -215 mm,~ -2733 mm
~ -215 mm,~ -950 mm
~ 2225 mm,~ -950 mm
```

주의:

- 좌표는 `Length#to_s` 결과를 그대로 쓰기 때문에 `~ 2225 mm` 같은 문자열이 나올 수 있다.
- Cell 단위가 아니라 모든 Cell의 모든 Face outline이 순차적으로 들어간다.
- 내부 hole은 기록하지 않고 outer loop만 기록한다.

## anchor.txt 출력 규칙

`anchor.txt`는 AnchorNodeMarker.exe의 출력 파일로 보인다.

파일 경로:

```txt
C:/Users/Public/Documents/anchor.txt
```

legacy Ruby의 `Anchor#read`는 파일이 정확히 3줄일 때만 읽는다.

형식:

```txt
x
y
rotation
```

실제 예:

```txt
37.4871692157895
127.150526046753
0.0
```

파싱 규칙:

- 1번째 줄: `x`
- 2번째 줄: `y`
- 3번째 줄: `rotation`
- 모두 `to_f`로 변환한다.
- anchor position은 `Geom::Point3d.new(x, y, 0)`으로 저장한다.
- rotation은 별도 float 값으로 저장한다.

legacy 주석에는 `위경도`라고 되어 있으므로 `x`, `y`는 실제로 latitude/longitude로 쓰였을 가능성이 높다.

## Legacy Anchor 객체

legacy `Anchor` 객체가 가진 항목:

- `position`
- `rotation`

초기값:

- `position = Geom::Point3d.new`
- `rotation = 0.0`

`Anchor#read`:

- `anchor.txt`에서 3줄을 읽어 position과 rotation을 설정한다.

`Anchor#write`:

- id, position.x, position.y, rotation을 쓰도록 되어 있다.
- 다만 legacy 코드에서는 newline을 `'\n'` single quote로 쓰고 있어 실제 newline이 아니라 문자 `\n`이 기록될 가능성이 있다.
- 따라서 legacy의 write 규칙은 read 규칙과 맞지 않을 수 있다.

## 우리 프로젝트에서의 관리 방향

AnchorNode는 현재 미구현으로 남긴다.

권장 처리:

- `AnchorNodeMarker.exe`와 관련 DLL은 legacy/vendor 참고 자료로 보관한다.
- 현재 IndoorGML export에는 포함하지 않는다.
- Node/State와 직접 합치지 않는다.
- 나중에 구현한다면 State 또는 별도 Anchor runtime 객체에 외부 좌표 anchor를 연결한다.

권장 runtime 속성:

- `state_id`
- `latitude`
- `longitude`
- `rotation`
- `source`
- `created_at` 또는 갱신 시각

권장 export 방향:

- IndoorGML 1.0 core에는 AnchorNode 공식 element가 없으므로 직접 export하지 않는다.
- 필요 시 별도 metadata 파일 또는 externalReference 방식으로 연결한다.
- `AnchorSpace`와 혼동하지 않는다.

## 현재 결정

- AnchorNode는 미구현으로 유지한다.
- AnchorNodeMarker.exe는 vendor/legacy 참고 자료로 남긴다.
- 현재 CellSpace/State/Transition export에는 포함하지 않는다.
- POI와 마찬가지로 IndoorGML 본체 객체가 아니라 application-specific extension 후보로 본다.
