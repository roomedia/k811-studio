# Karabiner-Elements integration

K811(`VID 0x5566` / `PID 0x000A`)에만 적용되는 장치 한정 remap 모음.

## 파일

| 파일 | 내용 |
| --- | --- |
| `k811-studio-remaps.json` | K811 전용 키 remap (`Command+Escape` → `Command+Q` 등) |
| `k811-knob-media-to-fkeys.json` | 노브·미디어 버튼을 `f16`~`f20`으로 번역. Hammerspoon 쪽 마우스 동작의 입력원이다 |

조이스틱은 여기 없다. 장치가 방향마다 화살표 키를 그대로 내보내므로 번역할 것이 없고, Hammerspoon 이 직접 받는다.

## 설치

두 파일을 `~/.config/karabiner/assets/complex_modifications/`에 복사한 뒤 Karabiner Settings → Complex Modifications → Add rule 에서 활성화한다.

## 장치 grab 설정 (필수)

**asset 파일만으로는 동작하지 않는다.** K811은 HID 노드를 3개 노출하는데, 미디어 키를 내보내는 노드에 pointing device 컬렉션 `(usage page 1, usage 2)`이 섞여 있다. Karabiner는 pointing device를 기본으로 건드리지 않으므로 그 노드를 통째로 무시하고, 노브·버튼 이벤트는 Karabiner를 그냥 통과한다.

Karabiner Settings → Devices 에서 해당 항목의 **Modify events** 를 켜거나, `~/.config/karabiner/karabiner.json`의 `profiles[].devices`에 직접 추가한다.

```json
{
    "identifiers": {
        "is_keyboard": true,
        "is_pointing_device": true,
        "product_id": 10,
        "vendor_id": 21862
    },
    "ignore": false
}
```

## 확인

설정이 맞으면 인터페이스 **두 개**가 grab 된다.

```sh
grep "Mechanical Keyboard" /var/log/karabiner/core_service.log | grep grabbed | tail -2
```

```
Mechanical Keyboard (device_id:4296556541) hid queue value monitor is started (grabbed).
Mechanical Keyboard (device_id:4296556537) hid queue value monitor is started (grabbed).
```

한 줄만 나오면 위 `ignore: false` 항목이 빠졌거나 식별자가 맞지 않는 것이다.

## 왜 Karabiner와 Hammerspoon을 나눴나

- Hammerspoon의 eventtap은 이벤트의 **출처 장치를 알 수 없다.** 볼륨 키를 여기서 가로채면 내장 키보드를 포함한 모든 키보드의 볼륨 키가 같이 죽는다. 장치 한정은 Karabiner만 할 수 있다.
- Karabiner는 **고정 픽셀 상대 이동을 만들 수 없다.** `mouse_key`는 키를 누르고 있는 동안 연속 이동이라 노브의 1ms 펄스로는 이동량이 사실상 0이고, `software_function.set_mouse_cursor_position`은 절대 좌표다.

그래서 Karabiner는 "어느 장치의 어떤 키인가"만 번역하고, 동작 정의는 전부 Hammerspoon 쪽 한 파일에 둔다.
