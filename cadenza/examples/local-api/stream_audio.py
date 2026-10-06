"""Stand-in for an AI hardware bridge: stream audio from a WAV file (or the system voice) to the app and print the text.

    python3 stream_audio.py                      # speaks a sample sentence with `say`, then streams it
    python3 stream_audio.py recording.wav        # 16 kHz mono 16-bit WAV
    python3 stream_audio.py --token cdz_...      # use a device token instead of the owner token

A real bridge does the same thing with audio that arrives from the device (Bluetooth, USB, serial, Wi-Fi to the bridge):
read chunks of raw 16 kHz mono signed 16-bit PCM and pass them to `send_audio`.
"""
import subprocess
import sys
import tempfile
import time
import wave

from voice_client import ApiError, AudioSession


def load_wav(path):
    with wave.open(path, "rb") as wav:
        if (wav.getframerate(), wav.getnchannels(), wav.getsampwidth()) != (16000, 1, 2):
            sys.exit("need a 16 kHz mono 16-bit WAV (convert with: afconvert -f WAVE -d LEI16@16000 -c 1 in.wav out.wav)")
        return wav.readframes(wav.getnframes())


def speak(text):
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        subprocess.run(["say", "-o", tmp.name, "--file-format=WAVE", "--data-format=LEI16@16000", text], check=True)
        return load_wav(tmp.name)


args = sys.argv[1:]
token = None
if "--token" in args:
    index = args.index("--token")
    token = args[index + 1]
    del args[index:index + 2]
pcm = load_wav(args[0]) if args else speak("为什么还有本地模型这个选项？")
print("audio: %.1f s" % (len(pcm) / 32000))

try:
    with AudioSession(token=token) as session:
        print("ready:", session.start(max_seconds=60)["max_bytes"], "bytes allowed")
        started = time.time()
        for offset in range(0, len(pcm), 3200):           # 100 ms chunks, paced like a live microphone
            session.send_audio(pcm[offset:offset + 3200])
            time.sleep(0.1)
        result = session.finish()
        print("text:", result["text"], "| took %.1f s" % (time.time() - started))
except ApiError as error:
    sys.exit("failed: %s" % error)
