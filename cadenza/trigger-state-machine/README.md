# Trigger state machine

A small Swift package with no dependencies that decides what a press of the shortcut means: when a hold or a tap starts a
recording, when it is committed, and when it is discarded. It has no user interface and no system events, audio, network
or timers. The clock is injected, and every event returns the new state together with an ordered list of actions, so the
whole behavior can be tested deterministically with a fake clock.

The app can run its recordings through this state machine behind the `triggerCoordinatorEnabled` setting, which is off by
default; the app's normal path does not depend on it.

## Layout

| Path | Contents |
|---|---|
| `Sources/TriggerCore/TriggerStateMachine.swift` | The state machine |
| `Tests/TriggerCoreTests/` | Unit tests with an injected clock |
| `diagnostics/loopback_probe.py` | A local-only fixture for provider network checks; it uses synthetic audio and dummy credentials and stores nothing |
| `run-tests.sh` | Runs the tests |

## Run the tests

```sh
./cadenza/trigger-state-machine/run-tests.sh
```

The tests use Apple's Swift Testing. The Command Line Tools ship `Testing.framework` outside Swift's default search path, so
the script adds it; nothing is installed.

## Notes for contributors

- Keep the package free of dependencies and of platform APIs; time comes only from the injected `TriggerClock`.
- A change to trigger behavior needs a test that fails without it. Passing tests with a fake clock do not prove real shortcut
  behavior on a Mac; say what you tried on a real keyboard.
