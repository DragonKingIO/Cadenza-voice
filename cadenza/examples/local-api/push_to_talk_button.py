"""External push-to-talk button, hold-to-talk or tap-to-toggle.

The button logic is two functions, `pressed()` and `released()`. Wire them to your hardware: a USB or serial button, a
GPIO pin (for example with gpiozero: `Button(17).when_pressed = pressed`), or a MIDI foot pedal. This demo uses the
terminal so it runs anywhere: type `h` + Enter to simulate press/release of a hold button, `t` for a toggle button.

The WebSocket connection owns the recording. If this script or the cable dies, the Mac cancels the recording, so the
microphone is never left open.
"""
import threading
import time
from voice_client import Events, ApiError

events = Events()
state = {"session": None}


def listener():
    while True:
        try:
            event = events.recv()
        except ApiError:
            print("connection closed")
            return
        if not event:
            continue
        kind = event.get("type")
        if kind == "state":
            state["session"] = event["session"] if event["state"] in ("recording", "processing") else None
            print("[%s]" % event["state"])
        elif kind == "partial":
            print("... " + event["text"])
        elif kind == "final":
            state["session"] = None
            print("TEXT:", event["text"])
        elif kind in ("cancelled", "error"):
            state["session"] = None
            print("[%s]" % kind, event.get("error", ""))


def pressed():
    if state["session"] is None:
        events.send({"op": "start", "max_seconds": 60})


def released():
    if state["session"] is not None:
        events.send({"op": "stop"})


threading.Thread(target=listener, daemon=True).start()
print("h = hold button down/up, t = toggle button, q = quit")
while True:
    key = input().strip().lower()
    if key == "q":
        break
    if key == "h":
        pressed()
        input("holding... press Enter to release ")
        released()
    elif key == "t":
        released() if state["session"] else pressed()
    time.sleep(0.05)
events.close()  # an unfinished recording is cancelled by the Mac
