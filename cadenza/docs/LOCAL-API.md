# Local voice API (version 1)

Lets a program or an external button on **this Mac** use the Mac's voice input: start and stop a recording, and receive the recognized text. It uses the speech engine and credentials you already configured in the app.

Scope: **microphone control, audio submission from other sources (hardware), text results, and optional typing into the front app.** Not included: reaching the app from other devices on the network, translation, text clean-up. `capabilities` reports what the running build supports. How hardware fits in, and what is planned next, is in [HARDWARE-INTEGRATION.md](HARDWARE-INTEGRATION.md).

## Safety model

- **Off by default.** Turn it on in Settings → Developer.
- **Loopback only.** It listens on `127.0.0.1` and is not reachable from other devices. There is no option to open it to the network.
- **Bearer token.** Every request needs `Authorization: Bearer <token>`: the owner token, or a device token (below). The owner token is created on first use and stored in `~/Library/Application Support/Cadenza/local-api-token` (mode `0600`, readable only by your account). Regenerating it in Settings invalidates the old one for new requests.
- **Browsers are refused.** A request carrying an `Origin` header, or a `Host` other than `127.0.0.1:<port>` / `localhost:<port>`, gets `403`. A web page cannot read the token, so it cannot call the API, and DNS rebinding is blocked.
- **Text only.** Results are returned to the caller and are not typed into any app. Service keys are never returned.
- **Visible.** The normal recording indicator is shown while an API session records.
- **Bounded.** Request bodies are limited to 64 KB, headers to 16 KB, at most 16 connections and 4 WebSocket connections, one session at a time.

The recognized text is handed to the caller and then removed from the app's "recent result" area. With a cloud engine, the audio is uploaded to that provider exactly as for a normal recording.

## HTTP

Base URL `http://127.0.0.1:17420` (the port is configurable). All bodies are JSON. Errors look like `{"error":{"code":"busy","message":"..."}}`.

| Request | Purpose |
|---|---|
| `GET /v1/capabilities` | API version, engine, limits, event names |
| `POST /v1/sessions` | Start recording. Optional body `{"max_seconds": 1..120}` (default 60) |
| `POST /v1/sessions/{id}/stop` | Stop recording and recognize. Safe to repeat |
| `POST /v1/sessions/{id}/cancel` | Discard. Safe to repeat |
| `GET /v1/sessions/{id}?wait=N` | State, optionally waiting up to N seconds (max 25) for it to finish |
| `GET /v1/ws` | WebSocket upgrade (below) |

Session object: `{"id": "<32 hex>", "state": "recording|processing|completed|cancelled|failed", "elapsed_ms": 1234, "text": "...", "error": {"code","message"}}`. `text` appears when `completed`; `error` when `failed`. The last 16 sessions can be read afterwards.

A recording that is never stopped ends by itself after `max_seconds` and is then recognized.

| Status | `code` | Meaning |
|---|---|---|
| 400 | `bad_request` | Bad JSON or parameter; also oversized or malformed requests |
| 401 | `unauthorized` | Missing or wrong token |
| 403 | `forbidden` | `Origin` present or wrong `Host` |
| 404 | `not_found` | Unknown path or session |
| 405 | `method_not_allowed` | Wrong method |
| 409 | `busy` | A session is already active, or the Mac's own shortcut is recording |
| 413 / 431 | `payload_too_large` / `headers_too_large` | Limits above |
| 426 | `upgrade_required` | `/v1/ws` without a WebSocket upgrade |
| 403 | `permission_denied` | The token lacks the needed permission, or typing is not allowed |
| 503 | `unavailable` | Voice input off, app not in hold mode, permission or credentials missing. `message` says why |

Session failures: `no_result` (nothing recognized or the engine failed; `message` explains) and `timeout` (recognition did not finish within 20 s).

## WebSocket

`GET /v1/ws` with the `Authorization` header and a normal upgrade. Text frames only, JSON, one message per frame. Client frames must be masked (any standard client does this).

Commands: `{"op":"start","max_seconds":60}`, `{"op":"stop"}`, `{"op":"cancel"}`, `{"op":"ping"}`. `stop` and `cancel` act on the session this connection started, or on `{"session":"<id>"}`.

Events (sent to every connected client):

```
{"type":"state","session":"…","state":"recording"}      also "processing"
{"type":"partial","session":"…","text":"…"}              running text while recording
{"type":"final","session":"…","state":"completed","text":"…"}
{"type":"cancelled","session":"…","state":"cancelled"}
{"type":"error","session":"…","state":"failed","error":{"code","message"}}
```

Command failures arrive as `{"type":"error","error":{…}}` without a session.

**Ownership:** a session started over a WebSocket is cancelled the moment that connection closes. Use this for hardware buttons: if the script or cable dies, the microphone is released. Sessions started over HTTP are not owned by a connection and rely on `max_seconds`.

## Devices and permissions

Create one device per piece of hardware or program in Settings → Developer → Devices. Each gets its own token (shown once, stored only as a hash), a name and its own permissions, and can be removed at any time; removal takes effect on the next request and closes the device's open connections. At most 16 devices.

| Permission | Allows |
|---|---|
| `mic` | `POST /v1/sessions…` and `GET /v1/ws`: record with the Mac's microphone |
| `audio` | `GET /v1/audio`: submit audio and receive text |
| `insert` | Ask for the final text to be typed into the front app. Also needs the global switch "Allow devices to type into the front app" (off by default) |

The owner token has `mic` and `audio`, never `insert`. A token without the needed permission gets `403 permission_denied`; every valid token can read `capabilities`.

## Submitting audio (`GET /v1/audio`, WebSocket)

For hardware with its own microphone. A bridge program on the Mac receives the audio (Bluetooth, USB, serial, Wi-Fi to the bridge) and forwards it here; the interface itself stays on `127.0.0.1`.

1. Upgrade with `Authorization: Bearer <token>` (needs `audio`).
2. Send `{"op":"start","sample_rate":16000,"channels":1,"format":"pcm_s16le","max_seconds":60,"deliver":"none"}`. The audio format is fixed: raw little-endian signed 16-bit mono PCM at 16 kHz. `deliver` may be `"insert"` (see below).
3. Receive `{"type":"ready","session":"…","max_bytes":1920000}`.
4. Send binary frames of PCM, an even number of bytes, up to 64 KB each. Real-time pacing is not required.
5. Receive `{"type":"partial","text":"…"}` while the engine produces running text (not every engine does).
6. Send `{"op":"end"}`. Receive `{"type":"final","session":"…","state":"completed","text":"…"}` (plus `"delivered":true|false` when `deliver` was `"insert"`), or `{"type":"error",…}`. `{"op":"cancel"}` discards everything and returns `cancelled`.

Rules: at most `max_seconds` of audio (default 60, up to 120); 10 seconds without a frame ends the session (`idle_timeout`); 30 seconds to produce a result (`timeout`); one API session at a time, including Mac-microphone sessions (`busy`); a closed connection cancels the session.

**Pace of audio:** with a local model, audio can be sent as fast as the connection allows. With a cloud engine the recognizer uploads at real-time speed and buffers about 8 seconds, so send frames at roughly real time (for example 100 ms of audio every 100 ms). A faster sender with a long clip gets an error instead of silently losing audio.

Errors on this endpoint: `permission_denied`, `bad_request` (parameters), `bad_frame` (odd length), `limit_exceeded`, `no_session` (audio before `start`), `no_audio`, `no_result`, `idle_timeout`, `timeout`, `busy`, and engine problems: `unsupported_engine` (the Mac's built-in recognition cannot take submitted audio), `local_only` (the "never go online" lock is on and the engine is not local), `consent_required`, `unavailable` (voice input off, no local model, no credentials).

Privacy: submitted audio is handled like a recording. With a local model nothing leaves the Mac. With a cloud engine it is uploaded to that provider, after the same consent as any recording. `capabilities.uploads_audio` tells which.

### Typing into the front app

`deliver:"insert"` is honoured only when the token has `insert`, the global switch is on, and there is a front window. The target is captured when the session starts; if the front app or window has changed when the text arrives, nothing is typed and `delivered` is `false` (the text is still returned). It never uses the clipboard and never types into secure fields.

## Other behaviour

- The microphone is released and the session ends as `cancelled` if the Mac sleeps, the app is quit, the API is turned off, or the user cancels from the recording indicator.
- If you press the Mac's own shortcut while an API session is active, the API session is unaffected; starting another via the API returns `409`.
- Out-of-date results never leak into the next session: each session has its own random id.

## Examples

`examples/local-api/` (Python 3, standard library only):

- `voice_client.py`: small client for HTTP and WebSocket.
- `dictate_once.py`: record a few seconds and print the text.
- `push_to_talk_button.py`: hold-to-talk or tap-to-toggle button. Replace the two functions `pressed()` / `released()` with your hardware's callbacks.

```bash
curl -H "Authorization: Bearer $(cat ~/Library/Application\ Support/Cadenza/local-api-token)" \
     http://127.0.0.1:17420/v1/capabilities
```

## Verified and not verified

Automated checks (run by `--selftest`) cover request parsing limits, the WebSocket codec, token and host/origin checks, routing, the session lifecycle with a fake recorder (stop, repeated stop, cancel, owner disconnect, `max_seconds`, processing timeout, concurrent start), and a real loopback listener with HTTP and WebSocket clients. They do not use a microphone or a speech service.

Audio sessions are covered by checks for the device store, permissions per route, every session rule (formats, limits, timeouts, busy, cancel, disconnect), typing gating, binary frames over a real loopback listener, and a real recognition run with the installed local model fed from synthesized speech. A real recording and a real audio session through the installed app are verified separately and recorded in the project notes. No physical hardware, Bluetooth or USB bridge, cloud provider through the audio endpoint, or typing into a third-party app has been tested. Direct access from other devices on the network is not offered (see HARDWARE-INTEGRATION.md for the plan).
