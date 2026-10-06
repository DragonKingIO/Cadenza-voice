# Connecting AI hardware to the voice input

Goal: a person with their own AI hardware (a pendant, glasses, a recorder, a DIY board) speaks into the hardware's own
microphone and the words come back as text, or appear at the cursor on the Mac. The app stays private by default: nothing
listens beyond this Mac unless the owner turns it on, every device has its own revocable credential, and every power is a
separate permission.

## What exists today (interface version 1)

| Capability | Status |
|---|---|
| Control the Mac's microphone (start, stop, cancel), receive text | Built, loopback only |
| One owner token, shown in Settings → Developer | Built |
| Submit audio from another source | Built |
| Per-device credentials with their own permissions | Built |
| Type the text into the front app | Built, off by default |
| Reach the Mac from another device on the network | Not built (design notes below) |

## How hardware reaches the app

```
Hardware mic ── BLE / USB / serial / Wi-Fi ──► bridge program on the Mac ── loopback ──► app (127.0.0.1)
```

The app only listens on `127.0.0.1`. A small *bridge program* on the Mac, written by the hardware maker or the user,
receives audio from the device and forwards it to the app. A bridge can be a few dozen lines (see
`examples/local-api/stream_audio.py`). This keeps the trust boundary on the Mac and needs no network exposure.

## Design of what is built

### Credentials and permissions

- The **owner token** (existing) can control the microphone and submit audio. It can never type into other apps.
- A **device token** is created in Settings → Developer → Devices, with a name and any of three permissions:
  - `mic`: start, stop and cancel recordings with the Mac's microphone.
  - `audio`: submit audio and receive text.
  - `insert`: ask the app to type the final text into the front app. Works only while the global switch
    "Allow devices to type into the front app" is on (off by default), and only when the session asked for it.
- Tokens are shown once. The app stores only a SHA-256 hash, the name, the permissions and the creation time.
  A device can be revoked at any time, which takes effect on its next request and closes its open connections.
- At most 16 devices.

### Audio session (`GET /v1/audio`, WebSocket)

1. Client upgrades with `Authorization: Bearer <token>` (needs `audio`).
2. Client sends `{"op":"start","sample_rate":16000,"channels":1,"format":"pcm_s16le","max_seconds":60,"deliver":"none"|"insert"}`.
3. Server answers `{"type":"ready","session":"…","max_bytes":N}` or `{"type":"error",…}`.
4. Client sends binary frames: raw little-endian signed 16-bit mono PCM at 16 kHz, any size up to 64 KB, even length.
5. Server may send `{"type":"partial","text":"…"}` when the engine produces running text.
6. Client sends `{"op":"end"}`. Server replies `{"type":"final","text":"…","delivered":false}`, or `{"type":"error",…}`.
   `{"op":"cancel"}` discards everything.

Limits: 120 s and the matching byte count per session, 10 s without audio while streaming ends the session,
30 s to produce a result, one API session at a time (a second one gets `busy`).
A closed connection cancels the session.

Engines: a local model, or a configured and consented cloud service. The Mac's built-in recognition cannot take external
audio and returns `unsupported_engine`. When the "never go online" lock is on, only local models run.
Audio from a device is treated like a recording from the microphone: with a cloud engine it is uploaded to that provider,
and `capabilities.uploads_audio` says so.

### Typing into the front app

Only with `deliver:"insert"`, the `insert` permission and the global switch. The target (front app and window) is captured
when the session starts and must be unchanged when the text arrives; otherwise nothing is typed and `delivered` is `false`.
It uses the same checks as a normal recording: no secure input, no clipboard, window-bound delivery for apps that expose
no text field.

### Visibility

The Developer page lists devices, shows connected programs, and offers "Test the interface". Revoking a device closes its
connections. Every session start, end and refusal is logged without text or audio.

## Network access from other devices (not built)

Letting hardware reach the Mac directly over Wi-Fi needs a different threat model. Planned requirements:

- Off by default, behind its own switch with an explanation.
- Pairing: the device shows or enters a one-time code displayed by the app; the app issues a device token over that
  channel. No token in URLs or logs.
- Encrypted transport: TLS with a certificate generated on the Mac whose fingerprint is shown in the pairing step and
  pinned by the device. Plain `ws://` on the network is not offered.
- Per-device rate and size limits, an allow-list of network ranges, and an on-screen indicator while a remote device is
  streaming.
- Bonjour advertisement only while pairing is open.
- A security review before release.

## Acceptance

Automated: credential store, permission checks per route, audio session rules (formats, limits, timeouts, busy, cancel,
disconnect), insertion gating, the WebSocket binary path over a real loopback listener, and a real recognition run with
the installed local model fed from synthesized speech through the interface.

Not covered by automation: a physical device, a Bluetooth or USB bridge, real network conditions, a cloud provider
through the interface, and typing into a real third-party app. These are checked by hand and recorded separately.
