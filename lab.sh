#!/usr/bin/env bash
# Lab local de monitoreo de prompts de Claude Code.
#   ./lab.sh up     levanta el OTel Collector (podman) y el receptor de hooks (uv)
#   ./lab.sh logs   muestra los prompts capturados por ambos canales
#   ./lab.sh down   apaga todo
# Requiere: brew. Instala podman y uv si faltan. Datos en ./data/.
set -euo pipefail
cd "$(dirname "$0")"
IMG=docker.io/otel/opentelemetry-collector-contrib:0.145.0
PORT_HOOK=8080

up() {
  command -v podman >/dev/null || brew install podman
  command -v uv >/dev/null || brew install uv
  podman machine inspect >/dev/null 2>&1 || podman machine init
  podman machine info --format '{{.Host.MachineState}}' | grep -q Running || podman machine start
  mkdir -p data && chmod 777 data
  podman rm -f otel-lab >/dev/null 2>&1 || true
  podman run -d --name otel-lab --user 0 -p 4317:4317 -p 4318:4318 \
    -v "$PWD/otel-config.yaml:/etc/otelcol-contrib/config.yaml:ro" -v "$PWD/data:/data" \
    "$IMG" --config /etc/otelcol-contrib/config.yaml >/dev/null
  if [ -f data/receiver.pid ] && kill -0 "$(cat data/receiver.pid)" 2>/dev/null; then :; else
    nohup uv run hook_receiver.py "$PORT_HOOK" >> data/receiver.log 2>&1 &
    echo $! > data/receiver.pid
  fi
  sleep 2
  podman ps --filter name=otel-lab --format 'collector: {{.Status}}  {{.Ports}}'
  echo "receiver:  pid $(cat data/receiver.pid) -> http://127.0.0.1:$PORT_HOOK/hooks/prompt"
}

logs() {
  echo "== hooks.jsonl (UserPromptSubmit) =="
  [ -f data/hooks.jsonl ] && python3 -c '
import json,sys
for l in open("data/hooks.jsonl"):
    e=json.loads(l); print(e.get("_received_at"), e.get("session_id","")[:8], repr(e.get("prompt","")[:80]))' || echo "(vacío)"
  echo "== otel-logs.jsonl (evento user_prompt) =="
  [ -f data/otel-logs.jsonl ] && python3 -c '
import json
for l in open("data/otel-logs.jsonl"):
    for rl in json.loads(l).get("resourceLogs",[]):
        for sl in rl.get("scopeLogs",[]):
            for r in sl.get("logRecords",[]):
                a={x["key"]:list(x["value"].values())[0] for x in r.get("attributes",[])}
                if a.get("event.name")=="user_prompt":
                    print(a.get("event.timestamp"), a.get("user.email"), a.get("session.id","")[:8], repr(a.get("prompt","<redactado>")[:80]))' || echo "(vacío)"
}

down() {
  podman rm -f otel-lab >/dev/null 2>&1 || true
  [ -f data/receiver.pid ] && kill "$(cat data/receiver.pid)" 2>/dev/null && rm -f data/receiver.pid
  echo "lab apagado"
}

case "${1:-}" in up) up;; logs) logs;; down) down;; *) sed -n 2,6p "$0";; esac
