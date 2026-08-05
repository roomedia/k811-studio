# K811 Studio for macOS

**English** · [한국어](README.ko.md)

Native macOS interoperability client for the K811 19-key macro keyboard (`VID 0x5566`, `PID 0x000A`).

## Current capability

- Discovers only the vendor-defined HID interface (`Usage Page 0xFF00`, Usage `0x0001`).
- Verifies 64-byte input/output report sizes before allowing a write.
- Controls the documented hardware lighting modes with color, brightness, speed, and automatic color selection.
- Adds an **에이전트** effect that stays dark at rest and signals completion, questions, approvals, and failures with fixed-color pulse counts.
- Agent hooks open the HID interface, apply one bounded sequence of fixed-color firmware transactions, and disconnect. K811 Studio does not need to be running and never holds the device open while idle.
- The GUI probes and releases the HID interface at startup; manual lighting changes are still explicit button actions.
- Includes a read-only device probe, a 19-key base-map dump, and protocol unit tests.
- Provides a Standard/FN key editor for the 19 verified main keys. Each assignment selects one keyboard-page output usage and an optional modifier. Eleven joystick/roller/volume/media controls are modeled but excluded from direct keyboard assignment because a physical detent did not emit key-up.
- Persists the local keymap draft under `~/Library/Application Support/K811 Studio/keymap-profile.json` with user-only directory/file permissions (`0700`/`0600`).
- Persists the last successfully applied recovery baseline separately in `keymap-applied-profile.json` and stores each pre-write 768-byte readable base snapshot under `Keymap Backups/`, also with user-only permissions.

Main-key assignment is physically verified and exposed through an explicit **키보드에 적용** action. A bounded ESC→B test received all page/commit acknowledgements and observed raw usage `0x05` from the exact K811 keyboard interface before restoring the zero override image. Because the device does not expose an authoritative overlay read-back, the GUI clearly treats its local profile as a draft and never writes automatically. Macro serialization is statically reconstructed and unit-tested but transport writes remain disabled until an unreadable macro overlay can be explicitly initialized from a known baseline; per-key RGB programming also remains disabled. See [`docs/protocol.md`](docs/protocol.md).

## Key assignment safety

- Editing a row saves only the local draft; it does not touch the device.
- The first safe write is **키보드 초기화**: after confirmation it backs up the readable base, writes a zero override image, registers that image as the automatic-recovery baseline, and clears the local draft only after the device transaction succeeds.
- **키보드에 적용** is disabled until a recovery baseline exists. It backs up the readable base, serializes the complete local profile, writes all 17 pages, requires every acknowledgement plus commit acknowledgement, and atomically saves the successful applied profile.
- A failed target write opens a fresh HID connection and automatically retransmits the previous applied image. If both target and recovery fail, the stale baseline is invalidated and the UI requires another confirmed initialization.
- A failed baseline save rolls the device back to the previous image. Every failure preserves the local draft. A malformed profile, duplicate key/layer pair, unsupported slot, invalid modifier, or out-of-range payload is rejected before opening the device.
- `0x07` base-map data is not shown as the current `0x09` overlay. Verification of a temporary assignment uses an exact-device IOHID observer rather than terminal input.

## Build and test

```sh
swift test
swift run k811-probe
swift run k811-dump
chmod +x scripts/build-app.sh
scripts/build-app.sh
open "dist/K811 Studio.app"
```

## First install

`scripts/build-app.sh` leaves the bundle in `dist/`, which is not where the hooks look for it. `scripts/install-agent-hooks.py` resolves the helper under `/Applications/K811 Studio.app` by default and refuses to run if it is not there, so copy the bundle first (`--app` overrides the location):

```sh
rm -rf "/Applications/K811 Studio.app"
cp -R "dist/K811 Studio.app" /Applications/
```

Then, in order:

1. Install the hooks. [Agent light hooks](#agent-light-hooks) has the preview/apply pair and the one-time Codex trust step.
2. Install Karabiner-Elements, allowing its driver extension and input monitoring when its own setup asks for them. Then set up [`integrations/karabiner/`](integrations/karabiner/), device-grab setting included.
3. Install Hammerspoon and grant it **Accessibility** in System Settings → Privacy & Security. Every click and cursor move here comes from a Hammerspoon event tap, and without that permission they fail silently rather than loudly. Then set up [`integrations/hammerspoon/`](integrations/hammerspoon/).

The lighting and keymap client needs no Privacy & Security grant of its own. It opens the vendor-defined HID interface (`Usage Page 0xFF00`) rather than a keyboard or pointing interface, which is what input monitoring gates.

## Agent light hooks

The app bundle includes `Contents/Helpers/k811-agent-event`, a transient local helper that writes directly to the K811 HID interface. It does not open a network port, require a resident app/daemon, or persist prompts and response text.

Severity is carried by color and pulse count, not by dimming. All four signals stay at full brightness (255) — a notification exists to be noticed.

- **Completion:** green, two pulses, then solid.
- **Question:** blue, three pulses, then solid.
- **Approval:** hardware-calibrated orange, four pulses, then solid.
- **Failure:** red, six fast pulses, then solid.
- **Clear / acknowledgement:** fixed black and no pending state.
- **Required sources:** Claude Code and Codex hooks work directly, including sessions launched inside Orca. Orca automations can call the universal `emit` command. Generic Orca terminal-idle/gate detection is intentionally not polled because that would require a resident watcher.
- **Optional sources:** OpenCode has a bundled adapter. Pi and Antigravity can use the universal `emit` command when a supported hook becomes available.

The helper stays alive only for the bounded pulse sequence (under two seconds for the built-in patterns), leaves the final fixed color on the keyboard, and exits. It keeps only `source`, `event`, opaque `session`, and timestamp under `~/Library/Application Support/K811 Studio/agent-state.json`. The directory and files are user-only (`0700`/`0600`), updates are serialized with a file lock, and state is saved only after the HID transaction succeeds. Records older than 24 hours are pruned on the next hook. The most recent event is the one on the keyboard; clearing it restores the next most recent one still pending.

The light reports the last thing that happened, and the state file remembers what is still waiting. Ranking by severity instead would mean an unanswered approval keeps the keyboard orange, so a completion arriving underneath it only re-pulses orange and says nothing about the turn that just ended. The cost of choosing recency is real and deliberate: a completion does cover a pending approval, and only the state file still knows the approval is there.

### When the light goes out

A waiting state can only be cleared by a person; a finished state may also be cleared by time. Completion is past-tense information that costs nothing to miss, while a question or an approval means the agent is actually blocked — turning those off on a timer would quietly hide the fact that something is still waiting.

| Event | Auto-off | Cleared by |
| --- | --- | --- |
| Completion | after `K811_COMPLETED_TIMEOUT_SECONDS` (default 600) | next prompt in that session |
| Question | never | next prompt in that session |
| Approval | never | the approval response |
| Failure | never | next prompt in that session |

Two rules make that hold in practice.

**Clears are scoped to one session.** `SessionStart` and `SessionEnd` clear only their own session. Opening a new window is not evidence that you saw a pending approval belonging to a different session. `SessionEnd` is what reclaims a session that was simply closed while its light was still on.

**Nothing lights up while you are already looking at it.** Before signalling, the hook walks its own ancestor process chain and compares it against the frontmost application. If the terminal hosting this session is in front, the hook records nothing and stays dark — the light would be noise, not information. When the chain cannot be resolved (a terminal that spawns shells from a separate server process, or a session behind tmux) the check fails open and the light comes on, because a redundant notification is less harmful than a missed one.

Completion auto-off keeps the no-resident-daemon property. Recording a completion writes the deadline into the state file and spawns a detached child to wait it out. The child holds no pipes from the hook runner and never opens the HID interface until the moment it turns the light off.

At most one child exists per session: it takes a per-key file lock, and a later child that cannot take the lock exits immediately. The holder re-reads the deadline each time it wakes, so a fresh completion simply pushes the deadline out and the same child sleeps longer. A cleared signal is not signalled to the child — it wakes at its deadline, finds nothing to expire, and exits.

| Variable | Default | Effect |
| --- | --- | --- |
| `K811_COMPLETED_TIMEOUT_SECONDS` | `600` | Seconds before a completion turns itself off. `0` or less disables auto-off. |
| `K811_AGENT_SUPPRESS_WHEN_FOCUSED` | on | Set to `0` to signal even when the hosting terminal is frontmost. |

Both apply to hook-driven signals. The `emit` command stays unconditional so manual adapters and scripts behave predictably.

### Which hooks are registered

`scripts/install-agent-hooks.py` registers exactly the events needed to raise a signal and to retire it again. Nothing is subscribed per tool call: `PreToolUse`/`PostToolUse` fire constantly and would say nothing about whether a person is needed.

| Agent | Event | Becomes |
| --- | --- | --- |
| Claude Code | `Notification` (`idle_prompt`, `agent_completed`) | completion, or failure when the message reads as one |
| | `Notification` (`permission_prompt`) | approval |
| | `Notification` (`elicitation_dialog`, `agent_needs_input`) | question |
| | `Notification` (`elicitation_complete`, `elicitation_response`) | clear |
| | `Stop` | completion |
| | `StopFailure` | failure |
| | `UserPromptSubmit`, `SessionStart`, `SessionEnd` | clear |
| Codex | `PermissionRequest` | approval |
| | `Stop` | question when the reply ends in one, otherwise completion |
| | `UserPromptSubmit`, `SessionStart` | clear |
| OpenCode | `permission.asked` | approval |
| | `session.idle` / `session.error` | completion / failure |
| | `permission.replied`, `session.status` = busy | clear |

Codex has no event that says "the agent is asking you something", so it guesses from a question mark at the end of the reply. Claude Code does not need that guess — it raises questions and approvals as their own `Notification` events — so its `Stop` always means completion. Applying the same heuristic there would paint an ordinary answer containing a question mark as a question.

Every clear is scoped to the session that emitted it. `SessionEnd` exists for exactly one reason: with session-scoped clears, a session that is simply closed would otherwise leave its light on forever — the 24-hour prune only runs when some later hook fires. Codex and OpenCode have no session-end event, so a closed session there is retired by the next `SessionStart`/`UserPromptSubmit` in that same session, or by `k811-agent-event clear --all`.

An unattended source is exactly what this rule cannot retire. A scheduled job that fails on its own session ID never emits another hook for that session, so its failure sits in the state file until the 24-hour prune reaches it. Under the severity ranking this project used to apply, one job failing every fifteen minutes pinned the keyboard red and hid every other signal. Recency removes that specific failure, but the record still accumulates, so K811 Studio only accepts sources with an interactive session behind them.

Preview and install hooks without replacing existing handlers:

```sh
scripts/install-agent-hooks.py --dry-run
scripts/install-agent-hooks.py --apply
```

Codex hashes non-managed command hooks. After installation, review and trust the new K811 handler once with `/hooks` inside Codex; the installer does not bypass that security gate.

Manual adapters and acknowledgement use the same one-shot helper:

```sh
"/Applications/K811 Studio.app/Contents/Helpers/k811-agent-event" \
  emit --source orca --event completed --session opaque-session-id
"/Applications/K811 Studio.app/Contents/Helpers/k811-agent-event" clear --all
```

## Evidence basis

The implementation is an independent interoperability client based on:

- Static analysis of the official `SXS-K811 V1.2.0.4` Windows application.
- The live K811 HID descriptors exposed by macOS.
- Cross-checking the shared 64-byte lighting protocol against the public, non-commercial `Hthancder/Atas-K68D-Custom` reference.

The vendor executable and extracted assets were kept locally for analysis only. They are not packaged into the macOS application and are not published in this repository: `work/` here contains the handoff and the diagnostic scripts, while the samples, extracted references, captured evidence, and disassembly dumps stay on the analysis machine.

The resulting protocol description — the interoperability output this project depends on — is in [`docs/protocol.md`](docs/protocol.md).

## Input remapping

Besides the lighting and keymap client, this repository carries the host-side remapping that turns the K811 knob into a macro wheel and its joystick and media buttons into mouse actions. The client half needs nothing besides the app bundle; this half needs two host apps installed and running.

| Component | Host app | Role |
| --- | --- | --- |
| [`integrations/karabiner/`](integrations/karabiner/) | [Karabiner-Elements](https://karabiner-elements.pqrs.org/) | Device-scoped remaps. Translates the knob and media buttons to `f16`–`f20`, and documents the device-grab setting the K811 needs. |
| [`integrations/hammerspoon/`](integrations/hammerspoon/) | [Hammerspoon](https://www.hammerspoon.org/) | Turns those keys into clicks, moves the cursor finely from the joystick while the wheel-click button is held, and drives a radial macro picker from the knob. Also holds a capture module for diagnosing what the device actually emits. |

Set Karabiner up first — Hammerspoon only ever sees the keys Karabiner produces. The split is not stylistic. Karabiner is the only side that can scope a rule to one device; Hammerspoon is the only side that can produce a fixed-pixel relative cursor move. Each integration's README explains its own constraints.

The knob no longer moves the cursor. One notch opens a radial picker and each further notch advances one entry, wrapping at the end. Play or Return pastes the selected text; the previous-track button or Escape dismisses it without typing anything, and the keyboard keys are intercepted only while the picker is up. A rotary encoder reports direction and never position, so the picker drops its selection on close and always counts from the first entry — that is the only way "two notches" can always mean the same macro. Retiring the knob-and-button combination also retired the forced-release window that the old vertical cursor mode depended on, which was the least reliable judgement in the integration.

### Dictation is assumed, not required

Nothing here calls a speech-to-text app and nothing breaks without one — [Whispree](https://github.com/Arsture/whispree) in this setup, though any dictation app does. It is still worth having, because the macro wheel's default list was picked on the assumption that dictation is there: commands you can simply say out loud, such as `/review` or `/commit`, were left off the wheel on purpose, and what remains is the few client-side commands that talking to an agent cannot trigger. Without dictation that criterion is the wrong one, and three entries are too few to be worth a knob — fill the wheel with your own boilerplate in `~/.hammerspoon/init.lua` instead.
