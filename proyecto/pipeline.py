import argparse
import contextlib
import csv
from difflib import SequenceMatcher
import http.client
import json
import os
from pathlib import Path
import re
import resource
import signal
import subprocess
import sys
import time
import unicodedata

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["DO_NOT_TRACK"] = "1"
os.environ["HF_HUB_DISABLE_XET"] = "1"

import numpy as np
import regex

ROOT = Path(__file__).resolve().parent
SPEC = ROOT / "especificacion"
if not SPEC.is_dir():
    SPEC = ROOT.parent.parent / "insumos" / "especificacion"
GLOSSARY = ", ".join((SPEC / "GLOSARIO.txt").read_text().splitlines())
PROMPT = (SPEC / "PROMPT_LIMPIEZA.md").read_text().split("```text\n", 1)[1].split("```", 1)[0]
PROMPT = PROMPT.replace("{GLOSARIO}", GLOSSARY).replace("(NUEVA, sin probar) ", "")
MODEL = "mlx-community/whisper-large-v3-turbo"
PARAMS = dict(language="es", initial_prompt=GLOSSARY, condition_on_previous_text=False,
              no_speech_threshold=0.6, compression_ratio_threshold=2.4)
SCRIPTS = regex.compile(r"[\p{Hangul}\p{Cyrillic}\p{Han}\p{Hiragana}\p{Katakana}\p{Bopomofo}\p{Arabic}]")
WORDS = re.compile(r"\w+", re.UNICODE)
MAX_PCM = 16000 * 2 * 600
OLLAMA_PORT = 11434
OLLAMA_TIMEOUT = 25


def fold(word):
    return "".join(c for c in unicodedata.normalize("NFD", word.casefold())
                   if not unicodedata.combining(c))


GLOSSARY_WORDS = {fold(match.group()) for match in WORDS.finditer(GLOSSARY)}
EXACT_WORDS = {"tienda", "tiendas", "asus"}
CLOUD_CONTEXT = re.compile(r"\b(?:pida|pídele|dile|pregúntale)\s+(?:a\s+)?$", re.IGNORECASE)

with (SPEC / "CORRECCIONES.tsv").open() as table:
    CORRECTIONS = [(re.compile(row["patron"], re.IGNORECASE), row["reemplazo"])
                   for row in csv.DictReader(table, delimiter="\t")]


def correct(text):
    for pattern, replacement in CORRECTIONS:
        text = pattern.sub(replacement, text)
    return text


def collapse(text):
    removed = 0
    while True:
        spans = list(WORDS.finditer(text))
        tokens = [match.group().casefold() for match in spans]
        found = False
        for size in range(1, len(tokens) // 4 + 1):
            for start in range(len(tokens) - 4 * size + 1):
                unit = tokens[start:start + size]
                end = start + size
                if tokens[end:start + 4 * size] != unit * 3:
                    continue
                while tokens[end:end + size] == unit:
                    end += size
                first_end = start + size
                text = text[:spans[first_end - 1].end()] + text[spans[end - 1].end():]
                removed += end - first_end
                found = True
                break
            if found:
                break
        if not found:
            return text, removed


def trim(samples):
    frame = 320
    frames = len(samples) // frame
    if not frames:
        return samples[:0], len(samples)
    power = np.sqrt(np.mean(samples[:frames * frame].reshape(-1, frame) ** 2, axis=1))
    floor = float(np.percentile(power, 15))
    threshold = max(0.0016, min(0.045, floor * 2.2))
    active = power > threshold
    voiced = np.flatnonzero(np.convolve(active, np.ones(5, dtype=int), "same")[:frames] >= 3)
    if not len(voiced):
        return samples[:0], len(samples)
    start = max(0, (int(voiced[0]) - 12) * frame)
    end = min(len(samples), (int(voiced[-1]) + 17) * frame)
    return samples[start:end], len(samples) - (end - start)


def decode_file(path):
    # Se usa un descriptor local y un formato de salida sin cabecera.
    with open(path, "rb") as source:
        result = subprocess.run(
            ["/opt/homebrew/bin/ffmpeg", "-nostdin", "-v", "error", "-protocol_whitelist", "fd,pipe",
             "-fd", "0", "-i", "fd:", "-vn", "-ar", "16000", "-ac", "1", "-t", "600", "-f", "s16le", "pipe:1"],
            stdin=source, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60, check=True)
    if not result.stdout:
        raise ValueError("Archivo sin audio decodificable")
    return result.stdout


def timeout_handler(signum, frame):
    raise TimeoutError()


def ollama(text):
    connection = http.client.HTTPConnection("127.0.0.1", OLLAMA_PORT, timeout=OLLAMA_TIMEOUT)
    payload = {"model": "gemma4:12b", "stream": False, "think": False, "keep_alive": "10m",
               "options": {"temperature": 0, "num_predict": 3072},
               "messages": [{"role": "system", "content": PROMPT}, {"role": "user", "content": text}]}
    previous = signal.signal(signal.SIGALRM, timeout_handler)
    signal.setitimer(signal.ITIMER_REAL, OLLAMA_TIMEOUT)
    try:
        connection.request("POST", "/api/chat", json.dumps(payload), {"Content-Type": "application/json"})
        with connection.getresponse() as response:
            if response.status != 200:
                raise OSError()
            result = json.loads(response.read(2_000_000))
            if result.get("done_reason") == "length":
                raise ValueError()
            return result["message"]["content"].strip()
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)
        connection.close()


def preserve_word_changes(source, cleaned):
    original = list(WORDS.finditer(source))
    proposed = list(WORDS.finditer(cleaned))
    source_words = [fold(item.group()) for item in original]
    target_words = [fold(item.group()) for item in proposed]
    edits = SequenceMatcher(None, source_words, target_words, autojunk=False).get_opcodes()
    for operation, first, last, start, end in reversed(edits):
        if operation != "replace":
            continue
        protected = any(
            source_words[i] in EXACT_WORDS or
            (source_words[i] == "cloud" and not CLOUD_CONTEXT.search(source[:original[i].start()]))
            for i in range(first, last))
        if not protected and all(word in GLOSSARY_WORDS for word in target_words[start:end]):
            continue
        replacement = source[original[first].start():original[last - 1].end()]
        cleaned = cleaned[:proposed[start].start()] + replacement + cleaned[proposed[end - 1].end():]
    return cleaned


def cleanup(raw):
    base = correct(raw)
    try:
        cleaned = ollama(base)
    except (OSError, ValueError, KeyError, AttributeError, TypeError, http.client.HTTPException):
        return raw, "ollama", 0
    if SCRIPTS.search(cleaned) and SCRIPTS.search(base):
        # Las transcripciones históricas pueden contener palabras ajenas al alfabeto latino.
        cleaned = re.sub(r"\S+", lambda word: "" if SCRIPTS.search(word.group()) else word.group(), cleaned)
    if not cleaned or SCRIPTS.search(cleaned):
        return base, "proteccion", 0
    safe = preserve_word_changes(base, cleaned)
    before = [fold(match.group()) for match in WORDS.finditer(base)]
    after = [fold(match.group()) for match in WORDS.finditer(safe)]
    if any(after.count(word) < before.count(word) for word in EXACT_WORDS):
        return base, "proteccion", 0
    guarded, repeats = collapse(safe)
    return guarded, "", repeats


def pipeline(pcm, mode, event=lambda state: None):
    start = time.monotonic()
    samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768
    samples, trimmed = trim(samples)
    raw, scripts, repeats = "", 0, 0
    if len(samples):
        import mlx_whisper

        result = mlx_whisper.transcribe(samples, path_or_hf_repo=MODEL, **PARAMS)
        parts = []
        for segment in result["segments"]:
            if SCRIPTS.search(segment["text"]):
                scripts += 1
            else:
                parts.append(segment["text"].strip())
        raw, repeats = collapse(" ".join(parts).strip())
    whisper_seconds = time.monotonic() - start
    text, notice, clean_repeats = raw, "", 0
    if raw and mode == "limpio":
        event("limpieza")
        text, notice, clean_repeats = cleanup(raw)
    return {"text": text, "notice": notice, "recorte_muestras": trimmed,
            "segmentos_escritura": scripts, "palabras_bucle": repeats + clean_repeats,
            "s_whisper": round(whisper_seconds, 3),
            "s_limpieza": round(time.monotonic() - start - whisper_seconds, 3),
            "rss_pico_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def worker():
    source = sys.stdin.buffer
    for line in iter(source.readline, b""):
        try:
            request = json.loads(line)
            length, mode = request["bytes"], request["mode"]
            if not 0 <= length <= MAX_PCM or length % 2 or mode not in ("crudo", "limpio"):
                return
            pcm = source.read(length)
            if len(pcm) != length:
                return
            # El canal stdout se reserva para el protocolo.
            protocol = sys.stdout
            with contextlib.redirect_stdout(sys.stderr):
                result = pipeline(pcm, mode, lambda state: print(
                    json.dumps({"state": state}), file=protocol, flush=True))
            emit(result)
        except Exception as exc:
            # Solo el tipo de excepción: el mensaje podría contener texto dictado.
            emit({"error": True, "tipo": type(exc).__name__})
        finally:
            pcm = result = None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archivo", type=Path)
    parser.add_argument("--modo", choices=("limpio", "crudo"), default="limpio")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.worker:
        worker()
        return 0
    if not args.archivo:
        parser.error("indica --archivo")
    start = time.monotonic()
    try:
        with contextlib.redirect_stdout(sys.stderr):
            pcm = decode_file(args.archivo)
            convert_seconds = time.monotonic() - start
            result = pipeline(pcm, args.modo)
    except Exception:
        print("Error al leer o transcribir el audio.", file=sys.stderr)
        return 1
    print(result.pop("text"))
    result["s_conversion"] = round(convert_seconds, 3)
    print(json.dumps(result), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
