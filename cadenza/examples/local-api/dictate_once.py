"""Record from the Mac microphone for a few seconds and print the recognized text.

    python3 dictate_once.py [seconds]
"""
import sys
from voice_client import Client, ApiError

seconds = int(sys.argv[1]) if len(sys.argv) > 1 else 5
api = Client()
caps = api.capabilities()
print("engine:", caps["engine"]["title"], "| uploads audio:", caps["uploads_audio"])
try:
    session = api.start(max_seconds=seconds + 5)
except ApiError as error:
    sys.exit("could not start: %s" % error)
print("recording for %d s... speak now" % seconds)
import time
time.sleep(seconds)
api.stop(session["id"])
result = api.wait(session["id"])
if result["state"] == "completed":
    print(result["text"])
else:
    print(result["state"], result.get("error", ""))
