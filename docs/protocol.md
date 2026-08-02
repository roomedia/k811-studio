# K811 HID Protocol Notes

Status labels:

- **Verified**: exercised against the connected K811 on macOS.
- **Static**: recovered from the official Windows binary, but not accepted as a shipping write contract.
- **Rejected**: a live experiment did not produce the expected observable behavior.

## Device identity

The application matches all of the following before opening a device:

| Property | Value |
| --- | --- |
| Vendor ID | `0x5566` |
| Product ID | `0x000A` |
| Primary Usage Page | `0xFF00` |
| Primary Usage | `0x0001` |
| Max Input Report | 64 bytes |
| Max Output Report | 64 bytes |

The device also exposes two keyboard interfaces. They are not opened by the application.

## Packet envelope — verified

macOS sends a 64-byte output report with report ID `0` passed separately to `IOHIDDeviceSetReport`.

| Offset | Meaning |
| --- | --- |
| `0` | Prefix `0x55` |
| `1` | Opcode |
| `2` | Subcommand/flags |
| `3` | Unsigned byte sum of offsets `4...63` for verified lighting/keymap and macro-page packets |
| `4...63` | Opcode-specific body |

Successful responses start with `0xAA`. The static macro finalize packet is a command-specific exception: it uses the literal prefix `55 10 A5 22` recovered from `DeviceDriver.exe`, rather than the generic checksum builder.

The Windows HID caps report 65 bytes because its `WriteFile` path includes the report-ID byte. macOS reports the corresponding payload length as 64 bytes.

## Global lighting — verified and shipped

Transaction:

1. `55 01` — begin
2. `55 05 00 20 20` — configure
3. `55 06` — lighting payload
4. `55 02` — commit

`55 06` fields:

| Offset | Meaning |
| --- | --- |
| `4` | `0x20` |
| `10` | mode (`0x00...0x0B`) |
| `11` | brightness |
| `12` | speed (`1...4`; firmware-fixed modes use `1`) |
| `14` | automatic color flag |
| `16...18` | RGB |

The SwiftUI application sent this transaction to the live K811 and received a successful IOKit result. The UI never sends it automatically; the user must press **조명 적용**.

### Agent attention lighting — verified

The K811 rendered both `breathe` and `shining` as rainbow effects when exercised with an explicit blue RGB value. This remained true for both observed values of offset `14`; therefore, those firmware animation modes are not used for severity colors.

The Agent helper uses bounded host-driven `fixed` transactions instead. It opens the HID interface once, alternates the calibrated fixed color and fixed black for the event's pulse count, leaves the calibrated color fixed, and disconnects. Physical checks confirmed green completion (2 pulses), blue question (3), orange approval (4), and red failure (6); clear applies fixed black. The helper process exits after the pulse sequence, so no resident app or daemon is required.

## Keymap read — verified, read-only

Transaction:

1. `55 01`
2. Fourteen `55 07` page requests
3. `55 02`

A page request uses a 56-byte body except for the final 40-byte page. The request length is at offset `4`, and the little-endian byte offset is at `5...6`. Response data starts at offset `8`.

The resulting base snapshot is 768 bytes. On the connected K811, all Standard/FN records for the 19 visible keys were `00 00 00 00` (factory-default implicit mapping).

`k811-dump` exposes this verified read-only operation. It must not be presented as the current keyboard-override profile.

## Keymap write — physically verified low-level contract

Static analysis of `DeviceDriver.exe` and a bounded live test confirm this transaction:

- Read base with `0x07` pages.
- Overlay host-side SQLite assignments.
- Write seventeen `0x09` pages (16 × 56 bytes + 40 bytes).
- Commit with `0x02`.

The host stages 17 × 56 = 952 bytes so every packet has a full 56-byte checksum region. The final packet declares only 40 bytes but still carries and checksums 56 staged bytes, matching the vendor serializer. Main-key writes are physically verified; the trailing special-control records remain static except for the bounded slot-114 experiment below.

The recovered record address formula is:

```text
recordOffset = (physicalSlot * 2 + layer) * 4
```

A keyboard override record is `[0x10, modifierMask, outputHIDUsage, 0x00]`. The modifier converter maps HID usages `E0...E7` to mask bits `0...7`.

The live test wrote `[10 00 05 00]` to ESC Standard (slot 0), received acknowledgements for all seventeen pages and commit, and observed raw HID usage `0x05` (B) from the exact K811 keyboard interface. It then immediately wrote a zero image, committed, and confirmed the readable snapshot returned to zero.

`0x07` is not an authoritative read-back oracle for the `0x09` overlay: it remained zero while the physical keyboard emitted B. The vendor executable also does not re-read `0x07` after commit. Physical verification must therefore use an exact-device IOHID observer rather than Orca/TUI input.

The vendor lookup identity, UI control/record slot, and factory output usage are separate concepts even when their numeric usages happen to agree. The K811 period key is looked up as `0x63`, occupies physical record slot 108, and was observed emitting `0x63`. The legacy usage-mapping array position is not the physical record slot. ESC occupies slot 0 and was observed as `0x29` before the override and `0x05` after the override.

### Special-control direct-keyboard experiment — rejected

A bounded slot-114 (`VOLUME DOWN`, large-knob counter-clockwise) overlay wrote direct keyboard record `[10 00 68 00]`. The physical detent suppressed the original volume event and produced F13 key-down plus autorepeat, but no matching key-up. Restoring the zero keymap image did not clear the already held host-side keyboard state. A subsequent bare physical ESC press generated a neutral report, after which an exact-device five-second F13 monitor timed out with `observedF13=false`.

The readable 768-byte snapshot matched the pre-probe image after restoration (`SHA-256 ef115a0e0c15cdc41958ca46b5b14b456115f4baec5e3ca68599d2a8f435e3b8`). Therefore joystick, roller, volume, and media controls reject direct keyboard records in Core and are not exposed by the direct-key editor. Their safe path must emit explicit key-down and key-up macro events.

The Core package contains the verified record/page builders, fail-closed profile validation, private-permission draft/applied-profile stores, a raw base-snapshot backup store, and a recovery coordinator. The application exposes the 19 verified keys on Standard/FN layers. Row edits update only the local draft; no keymap write occurs on launch or selection changes.

Every GUI write follows this order:

1. Read `0x07` and save the exact 768-byte base snapshot under `~/Library/Application Support/K811 Studio/Keymap Backups/` (`0700` directory, `0600` file). This is evidence/backup of the readable base, not an overlay oracle.
2. Write the target 952-byte image with a fresh HID connection and require all page/commit acknowledgements.
3. Atomically save the target as `keymap-applied-profile.json` (`0600`).
4. If target write or applied-profile persistence fails, open a fresh connection and retransmit the previous applied image. If that recovery also fails, invalidate the applied baseline and require confirmed initialization before another normal apply.

Confirmed **키보드 초기화** uses the same flow with a zero image and registers that zero image as the first recovery baseline. **키보드에 적용** remains disabled until this baseline exists.

The GUI can prove transaction acknowledgement but cannot claim byte-for-byte overlay read-back. Persistence across a disconnect or power cycle and physical recovery from a deliberately interrupted write have not yet been separately verified; coordinator failure phases are covered by fault-injection tests.

## Macro table — statically reconstructed, live write disabled

`DeviceDriver.exe` function `0x0041D580` serializes a maximum 3584-byte macro image:

- Bytes `0...63` are 32 little-endian two-byte event-stream offsets.
- Event data starts at offset `0x40`.
- Every event is `[delayLow, delayHigh, flags, serializedUsage]`; non-positive vendor delays are clamped to 1 ms.
- Keyboard down uses flag `0x40`; keyboard up omits it. Keyboard-page records add `0x02`, and the final event adds `0x80`.
- A one-shot F13 pulse is exactly `[01 00 42 68] [01 00 82 68]` after the vendor's `VK_F13 0x7C → HID usage 0x68` conversion.
- The image is sent as full 56-byte `0x0D` pages, followed by literal finalize packet `55 10 A5 22`, then `55 02` commit.

Function `0x0041E9D0` serializes a physical-control macro reference as `[0x70, macroIndex, optionA, optionB]`. Core currently exposes only the statically recovered one-shot form `[0x70, macroIndex, 0x00, 0x00]`; unknown repeat modes are not exposed.

`K811MacroTableImage`, macro packet framing, and special-control macro-reference encoding are covered by unit tests. No transport write API or GUI action is exposed yet because the device/vendor program provides no macro-table read-back. A live write would overwrite an unreadable overlay and requires explicit approval to initialize it from a known local baseline.

## Other static commands

- `0x0B`: custom per-key RGB table, seven pages covering a 400-byte working buffer.
- `0xEE`: factory-reset path.

These commands are not exposed by the application.
