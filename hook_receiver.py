# /// script
# requires-python = ">=3.11"
# ///
"""Receptor del hook UserPromptSubmit (tipo http) de Claude Code.

Modo lab (sin variables de entorno): guarda cada evento en data/hooks.jsonl y bloquea
si el prompt contiene la palabra BLOQUEAR.

Modo cluster (variables de entorno):
  OTLP_ENDPOINT  http://otel-collector:4318/v1/logs   reenvía el evento al colector (OTLP/JSON)
  OTLP_TOKEN     bearer que exige el colector
  LAKERA_URL     http://lakera-guard:8000/v2/guard    consulta Lakera Guard; flagged => block
  LAKERA_TOKEN   bearer de Lakera, si aplica
  HOOK_TOKEN     bearer que debe traer Claude Code en la cabecera Authorization

Si Lakera no responde en 5 s el prompt pasa (fail-open): el hook tiene 10 s de timeout y un
gate caído no puede dejar sin escribir a todos los desarrolladores.
Uso: uv run hook_receiver.py [puerto]
"""
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

OUT = pathlib.Path(__file__).with_name("data") / "hooks.jsonl"
MAX_BODY = 1_000_000  # un prompt real no pasa de esto; más grande se rechaza con 413
BLOCK_WORD = "BLOQUEAR"  # ponytail: marcador fijo para el lab; Lakera cuando LAKERA_URL exista
ENV = {k: os.environ.get(k, "") for k in ("OTLP_ENDPOINT", "OTLP_TOKEN", "LAKERA_URL", "LAKERA_TOKEN", "HOOK_TOKEN")}


def log(msg: str) -> None:
    print(msg, flush=True)


def post_json(url: str, payload: dict, token: str = "", timeout: float = 5.0) -> dict:
    headers = {"content-type": "application/json"}
    if token:
        headers["authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=json.dumps(payload).encode(), headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read() or b"{}")


def decide(prompt: str) -> dict:
    if ENV["LAKERA_URL"]:
        try:  # contrato v2 de Lakera Guard: {"messages":[...]} -> {"flagged": bool, ...}
            r = post_json(ENV["LAKERA_URL"], {"messages": [{"role": "user", "content": prompt}]}, ENV["LAKERA_TOKEN"])
            return {"decision": "block", "reason": "Prompt bloqueado por Lakera Guard"} if r.get("flagged") else {}
        except (urllib.error.URLError, TimeoutError, ValueError) as e:
            log(f"lakera sin respuesta, fail-open: {e}")
            return {}
    if BLOCK_WORD in prompt:
        return {"decision": "block", "reason": "Bloqueado por el gate DLP de prueba"}
    return {}


def kv(k: str, v) -> dict:
    return {"key": k, "value": {"stringValue": str(v)}}


def to_otlp(ev: dict, verdict: dict) -> dict:
    attrs = {
        "event.name": "prompt_guard.user_prompt",
        "session.id": ev.get("session_id", ""),
        "prompt.id": ev.get("prompt_id", ""),
        "cwd": ev.get("cwd", ""),
        "permission_mode": ev.get("permission_mode", ""),
        "decision": verdict.get("decision", "allow"),
        "prompt": ev.get("prompt", ""),
    }
    record = {"timeUnixNano": str(time.time_ns()), "severityText": "INFO",
              "body": {"stringValue": "prompt_guard.user_prompt"}, "attributes": [kv(k, v) for k, v in attrs.items()]}
    return {"resourceLogs": [{"resource": {"attributes": [kv("service.name", "prompt-guard")]},
                              "scopeLogs": [{"scope": {"name": "prompt-guard"}, "logRecords": [record]}]}]}


def persist(ev: dict, verdict: dict) -> None:
    if ENV["OTLP_ENDPOINT"]:
        try:
            post_json(ENV["OTLP_ENDPOINT"], to_otlp(ev, verdict), ENV["OTLP_TOKEN"])
        except (urllib.error.URLError, TimeoutError) as e:
            log(f"colector sin respuesta, evento perdido: {e}")
        return
    OUT.parent.mkdir(exist_ok=True)
    with OUT.open("a", encoding="utf-8") as f:
        f.write(json.dumps(ev, ensure_ascii=False) + "\n")


class Handler(BaseHTTPRequestHandler):
    timeout = 8  # por conexión: un cliente lento no retiene el hilo más allá del timeout del hook

    def do_POST(self):
        if ENV["HOOK_TOKEN"] and self.headers.get("authorization") != f"Bearer {ENV['HOOK_TOKEN']}":
            self.send_response(401)
            self.end_headers()
            return
        try:
            n = int(self.headers.get("content-length") or 0)
        except ValueError:
            n = -1
        if not 0 <= n <= MAX_BODY:
            self.send_response(413)
            self.end_headers()
            return
        try:
            ev = json.loads(self.rfile.read(n))
        except ValueError:
            ev = {}
        if not isinstance(ev, dict):
            ev = {}
        ev["_received_at"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        ev["_path"] = self.path
        prompt = str(ev.get("prompt", ""))
        verdict = decide(prompt)
        persist(ev, verdict)
        body = json.dumps(verdict).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        log(f"{ev['_received_at']} {ev.get('hook_event_name')} session={str(ev.get('session_id', ''))[:8]} "
            f"{'prompt=' + repr(prompt[:60]) if not ENV['OTLP_ENDPOINT'] else f'len={len(prompt)}'} -> {body.decode()}")

    def log_message(self, *_):  # silencia el log por defecto de http.server
        pass


if __name__ == "__main__":
    if not ENV["LAKERA_URL"]:
        assert decide("hola") == {} and decide("x BLOQUEAR y")["decision"] == "block"
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    modo = "cluster" if ENV["OTLP_ENDPOINT"] else "lab"
    log(f"hook receiver [{modo}] en http://0.0.0.0:{port}/hooks/prompt -> {ENV['OTLP_ENDPOINT'] or OUT}")
    ThreadingHTTPServer(("0.0.0.0" if modo == "cluster" else "127.0.0.1", port), Handler).serve_forever()
