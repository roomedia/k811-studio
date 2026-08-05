# Handoff — building further on this

The reverse-engineering case that produced this repository is closed. This file keeps only what a later change still needs: where the boundaries are, which facts cost the most to rediscover, and what each diagnostic tool proves. The protocol itself is in [`../../docs/protocol.md`](../../docs/protocol.md).

## Where the boundaries are

| Area | State | What is missing |
| --- | --- | --- |
| Lighting — global modes, fixed color | Verified live, shipped | — |
| Main-key overrides, 19 keys | Physically verified, shipped behind an explicit action | No authoritative overlay read-back, so the local profile stays a draft |
| Special controls — 11 joystick/roller/volume/media slots | Modeled, deliberately not assignable | A physical detent emits key-down and autorepeat but never key-up |
| Macro table | Serializers reconstructed and unit-tested, transport disabled | No macro-table read-back, so a first write could erase an unknown existing table. Needs explicit approval and a bounded live probe |
| Per-key RGB | Command family recovered | Not implemented |
| Firmware flashing, bootloader entry, fuzzed or destructive writes | Out of scope, permanently | — |

## Facts that cost the most to rediscover

- **`0x07` is not the overlay oracle.** It stays zero while a `0x09` overlay is active, so reading it back to confirm a write will always report that the write did nothing.
- **A terminal is not a physical-key oracle.** The first round of key-remap experiments looked dead because Orca/TUI swallowed the events. Verify against an exact-device IOHID observer instead — that is what `tools/k811-keymap-verify.swift` is for.
- **Keymap write format.** `[0x10, modifierMask, outputUsage, 0x00]` at offset `(slot * 2 + layer) * 4`, seventeen `0x09` pages, then a `0x02` commit. ESC output usage is `0x29`; period is `0x63` and its physical record slot is 108 — a legacy lookup-array position is not a record slot.
- **Macro format.** Offset table, 4-byte key-down/key-up events, `0x0D` pages, a literal `0x10/A5/22` finalize packet, and `[0x70, macroIndex, 0, 0]` as the one-shot reference. Recovered from vendor functions `0x0041D580`, `0x0041E9D0`, and `0x00435900`.
- **Restore is checked by hash.** The zero-image restore path was confirmed against readable snapshot hash `ef115a0e…`, and a bare ESC neutral report clears a stuck held state.
- **The lighting write cannot move to the host-side integrations.** Neither Karabiner nor Hammerspoon can send a vendor-defined HID output report: Karabiner only rewrites input events, and Hammerspoon exposes USB as an attach/detach watcher (`hs.usb`) plus capslock state (`hs.hid`). Writing 64 bytes to `Usage Page 0xFF00` needs `IOHIDDeviceSetReport`, so a native helper is the floor — Hammerspoon can only call one.

## Tools here

| Tool | What it proves |
| --- | --- |
| `tools/k811-keymap-verify.swift` | An override actually reaches the host, observed on the exact K811 interface rather than through a terminal |
| `tools/k811-hid-monitor.swift` | What the device emits on each of its interfaces |
| `tools/k811-f13-pulse-monitor.swift` | Whether a special-control override produces key-up — it did not |
| `tools/k811-usb-drop-report.py` | Whether a write causes a USB drop or re-enumeration |

## Rules that outlive the case

- The device is owner-operated. Writes stay bounded and are attempted only after the exact report semantics are verified.
- Vendor binaries and extracted assets are not published here. Samples, disassembly dumps, and captured evidence stay on the analysis machine.
