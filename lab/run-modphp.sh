#!/usr/bin/env bash
# Acto 1b: mismo trigger contra PHP 8.5.11 + mod_php (Apache).
#
# El README del lab documenta que el RCE de CVE-2026-109619 se demuestra en
# mod_php. Este script reproduce el comportamiento observable del SAPI real
# (fatal durante request startup, respuesta 500, posible SIGSEGV) SIN incluir
# heap grooming ni exploit de RCE.
#
# Uso:
#   ./lab/run-modphp.sh
#   ./lab/run-modphp.sh --url http://127.0.0.1:8083/ --cleanup
set -euo pipefail
cd "$(dirname "$0")/.."

URL="http://127.0.0.1:8083/"
COMPOSE="docker-compose.modphp.yml"
CLEANUP=0
MODE="progress"

while [ $# -gt 0 ]; do
  case "$1" in
    --url)     URL="$2"; shift 2 ;;
    --mode)    MODE="$2"; shift 2 ;;
    --cleanup) CLEANUP=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *)         echo "Opcion desconocida: $1" >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null || { echo "[!] docker no disponible" >&2; exit 1; }
TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p lab/reports

echo "== mod_php: levantando PHP 8.5.11 + Apache =="
docker compose -f "$COMPOSE" up -d

for i in $(seq 1 45); do
  if curl -fsS -o /dev/null --max-time 2 "$URL"; then
    echo "[i] listo tras ${i}s"
    break
  fi
  if [ "$i" -eq 45 ]; then
    echo "[!] no responde en $URL" >&2
    docker compose -f "$COMPOSE" ps >&2 || true
    exit 1
  fi
  sleep 1
done

echo "== Disparando trigger (mode=$MODE) =="
set +e
python3 trigger.py --url "$URL" --mode "$MODE" | tee "lab/reports/modphp-run-${TS}.log"
set -e

echo "== Capturando logs =="
docker compose -f "$COMPOSE" logs --since=5m > "lab/reports/modphp-${TS}.log" 2>&1 || true

echo "== Evidencia observable =="
grep -E 'Fatal error|Allowed memory|SIGSEGV|Segmentation|AH00052|exited|signal' \
  "lab/reports/modphp-${TS}.log" | tail -n 20 || true

echo
echo "[i] Logs: lab/reports/modphp-${TS}.log"
echo "[i] Nota: el RCE de 619 requiere heap grooming sobre mod_php; este script"
echo "    solo demuestra el fallo de memoria y el comportamiento del SAPI real."

if [ "$CLEANUP" -eq 1 ]; then
  docker compose -f "$COMPOSE" down -v
else
  echo "[i] Stack conservado. Usa --cleanup para detenerlo."
fi
