# Workitems

## WI-001 Preserve and triage the official artifact
- status: completed
- owner: cre
- output: sample hashes, extracted payload inventory, packer/language classification

## WI-002 Recover the K811 USB HID protocol
- status: completed_with_boundary
- owner: cre
- output: verified interface map, lighting protocol, read-only keymap dump, physically verified main-key write, statically reconstructed macro table/reference serializer

## WI-003 Implement the native macOS application
- status: completed
- owner: lead
- output: buildable application, tests, safe device access layer

## WI-004 Validate against the connected device
- status: completed_with_safe_boundary
- owner: lead
- output: verified lighting/main-key writes, rejected direct special-control write due missing key-up, verified zero restore/hash and held-state quiet monitor

## WI-005 Produce evidence-backed report and closeout
- status: completed
- owner: doc
- output: Evidence → Finding → Path report and Pitch/Explainer

## WI-006 Initialize and validate the unreadable macro overlay
- status: blocked_on_explicit_user_approval
- owner: lead
- output: static macro image/page/reference builders and unit tests complete; bounded live F13 pulse probe pending approval to replace any unknown existing macro table
