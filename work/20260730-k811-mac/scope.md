# Case Scope

## meta
- case_id: 20260730-k811-mac
- created: 2026-07-30T22:43:58+09:00
- operator: local
- primary_skill: reverse-engineering
- lead_role: lead
- specialist_roles: [cre]

## auth
- status: granted
- basis: own_system
- evidence_of_auth: User owns and connected the K811 device and explicitly requested interoperability analysis and a macOS implementation.
- MUST NOT proceed if status != granted

## in_scope
- assets:
  - http://www.mkespnhk.com/upload/20250623104030.zip
  - https://github.com/Hthancder/Atas-K68D-Custom
  - work/20260730-k811-mac/samples/K811-official.zip
  - work/20260730-k811-mac/samples/extracted/
  - USB HID device VID 0x5566 / PID 0x000A
- surfaces: [binary, usb_hid, macos_application]
- activities:
  - preserve and hash the official artifact
  - offline installer and application extraction
  - static reverse engineering of the Windows application
  - USB HID message dictionary and state-machine recovery
  - native macOS interoperability implementation
  - read-only device discovery
  - bounded device writes only after exact report semantics are verified

## out_of_scope
- assets: [other USB devices, unrelated vendor infrastructure]
- activities:
  - firmware flashing
  - bootloader entry
  - destructive or fuzzed USB writes
  - credential collection
  - production network scanning
  - republishing vendor binaries

## network_profile
- mode: authorized_target_only
- notes: |
    Network access is limited to downloading the explicitly identified public vendor artifact and public documentation/source references. Binary analysis is offline. The K811 is a local owner-operated device.

## deliverables
- report: true
- field_journal: true
- diagrams: false
- timeline: true

## constraints
- timebox: iterative
- stealth: low
- data_handling: no_user_pii
- implementation_language: prefer Swift with native IOKit/HID APIs unless evidence forces a different choice
- safety: no device mutation until protocol bytes and target interface are validated

## signoff
- ready_for_act: true
- checklist:
  - [x] auth.status = granted
  - [x] in_scope.assets non-empty OR offline sample path set
  - [x] network_profile.mode chosen
  - [x] out_of_scope reviewed
