"""Голосовой мост: часы Garmin -> STT (Whisper) -> claude -p в ~/ws/memory -> TTS (Piper) -> часы.

Всё локально. Секрет: ~/ws/memory/.secrets/voice.env (VOICE_TOKEN=...).

API (все запросы с заголовком Authorization: Bearer <token>):
  POST /v1/ask            тело: сырой audio/wav | audio/ogg, или JSON {"audio": base64, "text": "..."}
                          -> {"id": "..."}  (обработка асинхронная)
  GET  /v1/result/<id>    -> {"status": "pending|done|error", "heard": "...", "text": "...", "audio": bool}
  GET  /v1/audio/<id>     ?fmt=wav|ogg -> application/octet-stream (ответ голосом)
  GET  /v1/health         -> {"ok": true}  (без токена)
"""
from __future__ import annotations

import base64
import datetime as dt
import hmac
import json
import os
import re
import secrets
import subprocess
import threading
import time
import uuid
import wave
from pathlib import Path

import imageio_ffmpeg
import numpy as np
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response

HOME = Path.home()
VAULT = Path(os.environ.get("VOICE_VAULT", HOME / "ws/memory"))
HERE = Path(__file__).resolve().parent
MODELS = HERE / "models"
LOG_DIR = HOME / "ws/memory-logs"
WORK = HERE / "work"  # временные аудио, чистятся по TTL
FFMPEG = imageio_ffmpeg.get_ffmpeg_exe()

WHISPER_MODEL = os.environ.get("VOICE_WHISPER", "large-v3-turbo")
PIPER_VOICE = os.environ.get("VOICE_PIPER", "ru_RU-dmitri-medium")
CLAUDE_MODEL = os.environ.get("VOICE_CLAUDE_MODEL", "sonnet")
SESSION_TTL = 15 * 60  # секунд: продолжаем диалог, если прошлый вопрос был недавно
JOB_TTL = 60 * 60
MAX_AUDIO = 4 * 1024 * 1024

PROMPT_FILE = HERE / "prompt.md"
ALLOWED_TOOLS = (
    "Read,Write,Edit,Glob,Grep,Skill,"
    "Bash(git:*),Bash(date:*),Bash(cat:*),Bash(ls:*),"
    "Bash(_agent/jobs/garmin-api.sh:*),"
    "mcp__claude_ai_Garmin__*"
)


def load_token() -> str:
    env = VAULT / ".secrets/voice.env"
    for line in env.read_text().splitlines():
        if line.startswith("VOICE_TOKEN="):
            return line.split("=", 1)[1].strip()
    raise RuntimeError("VOICE_TOKEN not found")


def viktor_tz() -> str:
    """Часовой пояс берём из daily-health.sh — там его поддерживает сессия памяти."""
    try:
        m = re.search(r"^export TZ=(\S+)", (VAULT / "_agent/jobs/daily-health.sh").read_text(), re.M)
        if m:
            return m.group(1)
    except OSError:
        pass
    return "Europe/Warsaw"


def log(event: dict) -> None:
    LOG_DIR.mkdir(exist_ok=True)
    event = {"ts": dt.datetime.now().isoformat(timespec="seconds"), **event}
    with open(LOG_DIR / f"voice-{dt.date.today()}.log", "a") as f:
        f.write(json.dumps(event, ensure_ascii=False) + "\n")


# ---------- модели (ленивая загрузка) ----------
_whisper = None
_piper = None
_model_lock = threading.Lock()


def whisper():
    global _whisper
    with _model_lock:
        if _whisper is None:
            from faster_whisper import WhisperModel

            _whisper = WhisperModel(WHISPER_MODEL, device="cpu", compute_type="int8",
                                    download_root=str(MODELS / "whisper"), cpu_threads=8)
    return _whisper


def piper():
    global _piper
    with _model_lock:
        if _piper is None:
            from piper import PiperVoice

            _piper = PiperVoice.load(str(MODELS / "piper" / f"{PIPER_VOICE}.onnx"))
    return _piper


def decode_to_pcm16k(data: bytes) -> np.ndarray:
    p = subprocess.run([FFMPEG, "-v", "error", "-i", "pipe:0", "-f", "s16le", "-ac", "1", "-ar", "16000", "pipe:1"],
                       input=data, capture_output=True, timeout=60)
    if p.returncode != 0 or not p.stdout:
        # часы могут прислать «голый» PCM без заголовка WAV
        if len(data) > 3200 and data[:4] not in (b"RIFF", b"OggS"):
            return np.frombuffer(data[: len(data) // 2 * 2], np.int16).astype(np.float32) / 32768
        raise ValueError("cannot decode audio: " + p.stderr.decode(errors="replace")[-300:])
    return np.frombuffer(p.stdout, np.int16).astype(np.float32) / 32768


def transcribe(data: bytes) -> str:
    audio = decode_to_pcm16k(data)
    segs, _ = whisper().transcribe(audio, language="ru", beam_size=1, vad_filter=True,
                                   initial_prompt="Дневник, питание, калории, белок, сон, пульс, тренировка, Garmin.")
    return " ".join(s.text.strip() for s in segs).strip()


def synthesize(text: str, base: Path) -> None:
    """Пишет base.wav (16 кГц моно, LPCM) и base.ogg (Opus 16 кГц, 24 кбит/с)."""
    raw = base.with_suffix(".raw.wav")
    with wave.open(str(raw), "wb") as w:
        piper().synthesize_wav(text, w)
    subprocess.run([FFMPEG, "-v", "error", "-y", "-i", str(raw), "-ac", "1", "-ar", "16000",
                    "-c:a", "pcm_s16le", str(base.with_suffix(".wav"))], check=True, timeout=60)
    subprocess.run([FFMPEG, "-v", "error", "-y", "-i", str(raw), "-ac", "1", "-ar", "16000",
                    "-c:a", "libopus", "-b:a", "24k", "-application", "voip", str(base.with_suffix(".ogg"))],
                   check=True, timeout=60)
    raw.unlink(missing_ok=True)


# ---------- claude -p ----------
_session = {"id": None, "t": 0.0}
_claude_lock = threading.Lock()  # одна сессия за раз: правки и коммиты в хранилище не должны пересекаться


def ask_claude(question: str) -> str:
    tz = viktor_tz()
    now = dt.datetime.now(dt.timezone.utc).astimezone(__import__("zoneinfo").ZoneInfo(tz))
    system = PROMPT_FILE.read_text().replace("{NOW}", now.strftime("%Y-%m-%d %H:%M (%A)")).replace("{TZ}", tz)
    cmd = ["claude", "-p", question, "--model", CLAUDE_MODEL, "--output-format", "json",
           "--permission-mode", "acceptEdits", "--allowedTools", ALLOWED_TOOLS,
           "--append-system-prompt", system, "--max-turns", "30"]
    with _claude_lock:
        if _session["id"] and time.time() - _session["t"] < SESSION_TTL:
            cmd += ["--resume", _session["id"]]
        env = {**os.environ, "TZ": tz, "PATH": f"{HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"}
        p = subprocess.run(cmd, cwd=VAULT, capture_output=True, text=True, timeout=300,
                           stdin=subprocess.DEVNULL, env=env)
        try:
            out = json.loads(p.stdout)
        except json.JSONDecodeError:
            raise RuntimeError(f"claude exit={p.returncode}: {p.stderr[-500:] or p.stdout[-500:]}")
        if out.get("session_id"):
            _session.update(id=out["session_id"], t=time.time())
        if out.get("is_error"):
            raise RuntimeError(f"claude error: {str(out.get('result'))[:300]}")
        return clean_for_watch(str(out.get("result", "")).strip())


def clean_for_watch(text: str) -> str:
    text = re.sub(r"[*_`#>|]", "", text)
    text = re.sub(r"\[\[([^\]|]+)(\|[^\]]+)?\]\]", r"\1", text)
    return re.sub(r"\n{2,}", "\n", text).strip()


# ---------- задания ----------
jobs: dict[str, dict] = {}


def run_job(jid: str, audio: bytes | None, text: str | None) -> None:
    job = jobs[jid]
    t0 = time.time()
    try:
        heard = text or transcribe(audio or b"")
        job["heard"] = heard
        if not heard:
            job.update(status="done", text="Не расслышал, повтори.")
        else:
            job["status"] = "thinking"
            job["text"] = ask_claude(heard)
            job["status"] = "done"
        synthesize(job["text"], WORK / jid)
        job["audio"] = True
    except Exception as e:  # noqa: BLE001
        job.update(status="error", text=f"Ошибка: {e}"[:300])
    log({"id": jid, "status": job["status"], "heard": job.get("heard"), "reply": job.get("text"),
         "sec": round(time.time() - t0, 1)})


def gc_jobs() -> None:
    cutoff = time.time() - JOB_TTL
    for jid in [j for j, v in jobs.items() if v["t"] < cutoff]:
        jobs.pop(jid, None)
        for f in WORK.glob(f"{jid}*"):
            f.unlink(missing_ok=True)


# ---------- HTTP ----------
app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
TOKEN = load_token()
WORK.mkdir(exist_ok=True)


def auth(req: Request) -> None:
    h = req.headers.get("authorization", "")
    tok = h[7:] if h.lower().startswith("bearer ") else req.query_params.get("token", "")
    if not tok or not hmac.compare_digest(tok, TOKEN):
        raise HTTPException(401, "unauthorized")


@app.get("/v1/health")
def health():
    return {"ok": True}


@app.post("/v1/ask")
async def ask(req: Request):
    auth(req)
    gc_jobs()
    body = await req.body()
    if len(body) > MAX_AUDIO:
        raise HTTPException(413, "too large")
    audio, text = None, None
    ctype = req.headers.get("content-type", "")
    if "json" in ctype:
        d = json.loads(body or b"{}")
        text = (d.get("text") or "").strip() or None
        if d.get("audio"):
            audio = base64.b64decode(d["audio"])
    else:
        audio = body
    if not audio and not text:
        raise HTTPException(400, "no audio")
    jid = uuid.uuid4().hex[:12]
    jobs[jid] = {"status": "listening", "t": time.time()}
    threading.Thread(target=run_job, args=(jid, audio, text), daemon=True).start()
    return {"id": jid}


@app.get("/v1/result/{jid}")
def result(jid: str, req: Request):
    auth(req)
    job = jobs.get(jid)
    if not job:
        raise HTTPException(404, "unknown id")
    st = job["status"]
    if st == "done" and not job.get("audio"):
        st = "speaking"  # текст готов, идёт синтез
    ready = st in ("done", "error")
    return JSONResponse({"status": st, "heard": job.get("heard", ""),
                         "text": job.get("text", "") if ready else "", "audio": bool(job.get("audio"))})


@app.get("/v1/audio/{jid}")
def audio(jid: str, req: Request, fmt: str = "wav"):
    auth(req)
    if fmt not in ("wav", "ogg") or not re.fullmatch(r"[0-9a-f]{12}", jid):
        raise HTTPException(400, "bad request")
    f = WORK / f"{jid}.{fmt}"
    if not f.exists():
        raise HTTPException(404, "no audio")
    return Response(f.read_bytes(), media_type="application/octet-stream")


if __name__ == "__main__":
    import uvicorn

    port = int(os.environ.get("VOICE_PORT", "8787"))
    cert, key = os.environ.get("VOICE_CERT"), os.environ.get("VOICE_KEY")
    threading.Thread(target=lambda: (whisper(), piper()), daemon=True).start()  # прогрев
    uvicorn.run(app, host=os.environ.get("VOICE_HOST", "127.0.0.1"), port=port,
                ssl_certfile=cert, ssl_keyfile=key, log_level="warning", access_log=False)
