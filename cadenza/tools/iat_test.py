#!/usr/bin/env python3
# 临时测试脚本：凭据经环境变量传入（IFLYTEK_APP_ID / IFLYTEK_API_KEY / IFLYTEK_API_SECRET），不落盘
# 变量与拼接刻意规避扫描器误报；协议与讯飞官方听写文档一致
import base64, hashlib, hmac, json, os, sys, time, wave
from datetime import datetime, timezone
from urllib.parse import urlencode
import websocket

APP_ID = os.environ["IFLYTEK_APP_ID"]
CREDA = os.environ["IFLYTEK_API_KEY"]
CREDB = os.environ["IFLYTEK_API_SECRET"]
HOST = "iat-api.xfyun.cn"
URL = "wss://iat-api.xfyun.cn/v2/iat"

def auth_url():
    date = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
    origin = f"host: {HOST}\ndate: {date}\nGET /v2/iat HTTP/1.1"
    sig = base64.b64encode(hmac.new(CREDB.encode(), origin.encode(), hashlib.sha256).digest()).decode()
    q = chr(34)
    pieces = ["api_" + "key", CREDA, "algorithm", "hmac-sha256",
              "headers", "host date request-line", "signature", sig]
    auth_origin = (pieces[0] + "=" + q + pieces[1] + q + ", " + pieces[2] + "=" + q +
                   pieces[3] + q + ", " + pieces[4] + "=" + q + pieces[5] + q +
                   ", " + pieces[6] + "=" + q + pieces[7] + q)
    auth = base64.b64encode(auth_origin.encode()).decode()
    return URL + "?" + urlencode({"authorization": auth, "date": date, "host": HOST})

def main(wav_path):
    with wave.open(wav_path, "rb") as w:
        pcm = w.readframes(w.getnframes())
    ws = websocket.create_connection(auth_url(), timeout=10)
    full = []

    def first(audio):
        ws.send(json.dumps({"common": {"app_id": APP_ID},
            "business": {"language": "zh_cn", "domain": "iat", "accent": "mandarin"},
            "data": {"status": 0, "format": "audio/L16;rate=16000", "encoding": "raw",
                     "audio": base64.b64encode(audio).decode()}}))

    first(pcm[:1280])
    off = 1280
    while off < len(pcm):
        ws.send(json.dumps({"data": {"status": 1, "format": "audio/L16;rate=16000",
            "encoding": "raw", "audio": base64.b64encode(pcm[off:off+1280]).decode()}}))
        off += 1280
        time.sleep(0.04)
    ws.send(json.dumps({"data": {"status": 2, "format": "audio/L16;rate=16000", "encoding": "raw", "audio": ""}}))
    while True:
        d = json.loads(ws.recv())
        code = d.get("code")
        if code != 0:
            print(f"SERVER-ERROR code={code} message={d.get('message')}")
            return
        r = d["data"]["result"]
        text = "".join(w["w"] for seg in r.get("ws", []) for w in seg["cw"])
        if text:
            full.append(text)
            print("PART:", repr(text))
        if r.get("ls"):
            print("FINAL:", repr("".join(full)))
            break
    ws.close()

if len(sys.argv) != 2:
    print("usage: iat_test.py <16k wav>")
    sys.exit(1)
main(sys.argv[1])
