#!/usr/bin/env python3
"""K811 이 USB 버스에서 떨어진 사건을 잠금 화면 전환과 함께 되짚는다.

잠금 후 키보드가 죽는 증상에서 알아야 할 것은 하나다. 장치가 버스에서 사라졌는가,
아니면 열거된 채로 입력만 안 오는가. 커널이 그 둘을 구분해 남긴다.

  terminateDevice ... hardware connection lost   장치가 사라졌다
  enumerateDeviceComplete ... enumerated         다시 붙었다

터미네이트 뒤에 열거가 없으면 장치는 지금도 버스에 없다. 그 상태는 사용자 공간에서
되살릴 수 없다(허브는 AppleUSB20Hub 가, 장치는 AppleUSBHostCompositeDevice 가
배타 점유한다). 반대로 열거가 따라왔는데도 키가 안 먹었다면 HID 쪽 문제이고
앱이 다시 열어 살릴 수 있다. 그래서 이 스크립트는 판정만 하고 아무것도 고치지 않는다.

상주 감시자는 두지 않는다. 통합 로그가 이미 남기고 있으므로 사후에 읽으면 된다.

    work/20260730-k811-mac/tools/k811-usb-drop-report.py --hours 24
"""

from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
import sys
from datetime import datetime, timedelta

VENDOR_ID = 0x5566
PRODUCT_ID = 0x000A
# 커널은 터미네이트·열거 양쪽에 이 형태로 장치를 적는다: 0x5566/000a/0008
DEVICE_TAG = f"0x{VENDOR_ID:04x}/{PRODUCT_ID:04x}"
# 키보드가 매달린 도크 허브. 이쪽이 같이 떨어졌다면 원인은 포트가 아니라 도크다.
HUB_TAG = "0x0bda/5409"
LINE = re.compile(
    r"^(?P<stamp>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)\s+\S+\s+kernel\[[^\]]*\]\s+(?P<message>.*)$"
)
LOCK_STATE = re.compile(r"gIOScreenLockState (?P<state>\d+)")
# IOScreenLockState: 1 NoLock, 2 Unlocked, 3 Locked, 4 FileVaultDialog
LOCKED_STATE = "3"


class Event:
    def __init__(self, at: datetime, kind: str, detail: str) -> None:
        self.at = at
        self.kind = kind
        self.detail = detail


def device_is_present() -> bool:
    """지금 이 순간 장치가 IOUSB 평면에 있는가."""
    try:
        dump = subprocess.run(
            ["ioreg", "-p", "IOUSB", "-a", "-l", "-w0"],
            capture_output=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return False
    if not dump:
        return False
    try:
        nodes = plistlib.loads(dump)
    except plistlib.InvalidFileException:
        return False
    return _contains_device(nodes)


def _contains_device(node: object) -> bool:
    if isinstance(node, list):
        return any(_contains_device(item) for item in node)
    if not isinstance(node, dict):
        return False
    if node.get("idVendor") == VENDOR_ID and node.get("idProduct") == PRODUCT_ID:
        return True
    return _contains_device(node.get("IORegistryEntryChildren", []))


def sleep_windows(hours: float) -> list[datetime]:
    """되짚는 구간 안의 잠자기 시각.

    잠자기 동안에는 통합 로그가 커널 메시지를 남기지 않는다. 실측하면 잠자기 전후로
    장치 노드가 새로 만들어졌는데도(sessionID 변경) 이탈·열거 기록은 한 줄도 없었다.
    그래서 잠자기가 끼어 있으면 '이탈 0건'을 근거로 쓸 수 없다는 것을 알려야 한다.
    """
    try:
        listing = subprocess.run(
            ["pmset", "-g", "log"], capture_output=True, text=True, check=True
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return []

    found: list[datetime] = []
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) < 4 or fields[3] != "Sleep":
            continue
        try:
            at = datetime.strptime(" ".join(fields[:2]), "%Y-%m-%d %H:%M:%S")
        except ValueError:
            continue
        found.append(at)
    return found


def read_events(hours: float) -> list[Event]:
    predicate = (
        'process == "kernel" AND ('
        f'eventMessage CONTAINS "{DEVICE_TAG}" OR '
        f'eventMessage CONTAINS "{HUB_TAG}" OR '
        'eventMessage CONTAINS "gIOScreenLockState")'
    )
    result = subprocess.run(
        [
            "/usr/bin/log",
            "show",
            "--last",
            f"{hours:g}h",
            "--style",
            "compact",
            "--predicate",
            predicate,
        ],
        capture_output=True,
        text=True,
        check=True,
    )

    events: list[Event] = []
    for raw in result.stdout.splitlines():
        parsed = LINE.match(raw)
        if parsed is None:
            continue
        at = datetime.strptime(parsed["stamp"], "%Y-%m-%d %H:%M:%S.%f")
        message = parsed["message"]

        lock = LOCK_STATE.search(message)
        if lock is not None:
            state = "locked" if lock["state"] == LOCKED_STATE else "unlocked"
            events.append(Event(at, state, ""))
            continue
        if HUB_TAG in message and "terminateDevice" in message:
            events.append(Event(at, "hub-gone", ""))
            continue
        if DEVICE_TAG not in message:
            continue
        if "terminateDevice" in message:
            reason = message.rsplit(": ", 1)[-1]
            events.append(Event(at, "gone", reason))
        elif "enumerated" in message:
            speed = message.rsplit(" at ", 1)[-1] if " at " in message else ""
            events.append(Event(at, "back", speed))
    return events


def report(events: list[Event], hours: float) -> int:
    drops = [event for event in events if event.kind == "gone"]
    present = device_is_present()
    print(f"# K811 USB 연결 이력 (최근 {hours:g}시간)")
    print(f"지금 버스에 있는가: {'예' if present else '아니오'}")
    print(f"떨어진 횟수: {len(drops)}")

    slept = [at for at in sleep_windows(hours) if at >= datetime.now() - timedelta(hours=hours)]
    if slept:
        stamps = ", ".join(f"{at:%m-%d %H:%M}" for at in slept[-3:])
        print(
            f"\n주의: 이 구간에 잠자기가 있었다 ({stamps}). 잠자기 동안의 커널 메시지는"
            " 남지 않으므로, 그때 일어난 이탈·열거는 아래 집계에 빠져 있다."
        )

    if not drops:
        print("\n기록된 이탈이 없다. 로그 보존 기간을 넘겼거나 아직 재현되지 않았다.")
        return 0

    unresolved = 0
    print("\n시각\t\t\t잠금 상태\t복귀\t도크\t사유")
    for drop in drops:
        # 이탈 직전의 잠금 전환. 잠금이 방아쇠였다면 여기 몇 초 전으로 찍힌다.
        before = [
            event
            for event in events
            if event.at <= drop.at and event.kind in ("locked", "unlocked")
        ]
        if before:
            last = before[-1]
            gap = drop.at - last.at
            lock_state = f"{last.kind} ({format_gap(gap)} 전)"
        else:
            lock_state = "알 수 없음"

        recovery = next(
            (event for event in events if event.kind == "back" and event.at > drop.at),
            None,
        )
        if recovery is None:
            unresolved += 1
            recovered = "없음 — 재연결 필요"
        else:
            recovered = f"{format_gap(recovery.at - drop.at)} 후"

        # 허브까지 같이 떨어졌으면 포트 하나가 아니라 도크 전체가 나간 것이다.
        hub_fell = any(
            event.kind == "hub-gone" and abs((event.at - drop.at).total_seconds()) <= 5
            for event in events
        )
        dock = "같이 떨어짐" if hub_fell else "유지"

        print(f"{drop.at:%Y-%m-%d %H:%M:%S}\t{lock_state}\t{recovered}\t{dock}\t{drop.detail}")

    print()
    if unresolved:
        print(
            f"복귀하지 않은 이탈 {unresolved}건. 장치가 버스에서 사라진 상태라 "
            "사용자 공간에서는 되살릴 수 없다 — 허브 포트 전원을 끊는 것만이 방법이고, "
            "그 허브는 커널이 배타 점유한다."
        )
    else:
        print(
            "모든 이탈이 스스로 복귀했다. 그래도 키가 안 먹는다면 세 번째 상태다 — "
            "버스에 있고 vendor 명령에도 응답하지만(k811-dump 성공) 키 스캔과 LED 가 죽어 있다. "
            "MCU 의 USB 처리만 살고 메인 루프가 멈춘 것이라 인터페이스를 다시 열어도 살지 않는다. "
            "전원 재투입이 필요하고, 화면 잠금·시스템 잠자기가 이 포트의 전원을 내리므로 "
            "선을 뽑기 전에 그쪽을 먼저 시도한다."
        )
    return 1 if unresolved else 0


def format_gap(gap: timedelta) -> str:
    seconds = gap.total_seconds()
    if seconds < 90:
        return f"{seconds:.1f}초"
    if seconds < 5400:
        return f"{seconds / 60:.1f}분"
    return f"{seconds / 3600:.1f}시간"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hours", type=float, default=24, help="되짚을 시간 (기본 24)")
    arguments = parser.parse_args()
    return report(read_events(arguments.hours), arguments.hours)


if __name__ == "__main__":
    sys.exit(main())
