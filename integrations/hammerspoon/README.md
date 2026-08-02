# Hammerspoon integration

K811의 노브와 미디어 버튼을 마우스 동작으로 바꾼다. 입력은 Karabiner가 `f16`~`f20`으로 번역해 넘겨준다 ([`../karabiner/`](../karabiner/) 먼저 설정할 것).

## 매핑

| 입력 | Karabiner 번역 | 동작 |
| --- | --- | --- |
| 노브 반시계 | `f16` | 커서 왼쪽 `STEP` px |
| 노브 시계 | `f17` | 커서 오른쪽 `STEP` px |
| 이전 곡 | `f18` | 좌클릭 |
| 다음 곡 | `f19` | 우클릭 |
| 재생/일시정지 (짧게) | `f20` | 휠(가운데) 클릭 |
| 재생/일시정지 + 노브 | `f20` + `f16`/`f17` | 커서 위/아래 `STEP` px |

## 설치

```sh
cp knob_mapping.lua knob_capture.lua ~/.hammerspoon/
```

`~/.hammerspoon/init.lua`에 추가한다.

```lua
knobMapping = require('knob_mapping')
knobMapping.start()

-- 진단이 필요할 때만 knobCapture.start() 를 호출한다
knobCapture = require('knob_capture')
```

## 세로 이동이 '창' 방식인 이유

K811은 consumer HID 리포트에 usage를 **한 번에 하나만** 담는다. 그래서 재생/일시정지를 누른 채 노브를 돌리면 하드웨어가 재생 버튼을 강제로 release 한다. 실측하면 회전 **13ms 전**에 key up이 들어온다.

```
605.432  f20 down          ← 재생 버튼 누름
  ...    f20 down (auto-repeat 1.09초)
606.526  f20 up            ← 강제 release
606.539  f16 down          ← 노브 회전, 13ms 뒤
```

버튼이 실제로 눌려 있는지 알 방법이 없으므로, **버튼을 뗀 직후 짧은 창 안에 노브가 들어오면 조합으로 간주**한다. 세로 모드는 회전이 이어지는 동안 계속 연장되고 손을 멈추면 가로로 돌아온다.

## 튜닝

`knob_mapping.lua` 상단 상수.

| 상수 | 기본값 | 의미 |
| --- | --- | --- |
| `STEP` | `100` | 한 스텝 이동 픽셀 |
| `COMBO_WINDOW` | `0.15` | 버튼을 뗀 뒤 이 시간 안에 노브가 오면 조합 |
| `VERTICAL_IDLE` | `1.0` | 세로 모드가 회전 없이 유지되는 시간 |
| `LONG_PRESS` | `0.7` | 이보다 오래 눌렀다 떼면 휠 클릭 없이 조합 의도로만 본다 |
| `CLICK_DELAY` | `0.15` | 휠 클릭을 미루는 시간. 이 사이 노브가 오면 취소 |

## knob_capture.lua

장치가 실제로 어떤 이벤트를 보내는지 `~/.hammerspoon/knob_capture.log`에 기록하는 진단 모듈. 이벤트를 소비하지 않으므로 캡처 중에도 원래 동작은 유지된다.

```lua
knobCapture.start()
knobCapture.stop()
```

> **모든 키 입력이 기록된다.** 진단이 끝나면 `stop()` 하고 로그 파일을 지울 것.
