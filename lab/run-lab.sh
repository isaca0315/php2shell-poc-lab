#!/usr/bin/env bash
# Engagement completo y repetible del lab de red team.
#
#   Acto 1 (CVE): recon + validate + impact sobre nginx/PHP-FPM (8080)
#   Acto 2 (RCE): subida -> webshell -> /flag.txt en el target (8082)
#   Cierre:       captura logs, evalua objetivos y desbloquea la flag
#
# Uso:
#   ./lab/run-lab.sh
#   ./lab/run-lab.sh --cleanup
#   ./lab/run-lab.sh --sustain 20 --concurrency 4
#   ./lab/run-lab.sh --skip-rce          # solo acto 1 (flag bloqueada)
set -euo pipefail
cd "$(dirname "$0")/.."

URL="http://127.0.0.1:8080/"
TARGET_URL="http://127.0.0.1:8082/"
COMPOSE="docker-compose.yml"
CLEANUP=0
NO_START=0
SKIP_RCE=0
EXTRA=()

while [ $# -gt 0 ]; do
  case "$1" in
    --url)          URL="$2"; shift 2 ;;
    --target-url)   TARGET_URL="$2"; shift 2 ;;
    --compose-file) COMPOSE="$2"; shift 2 ;;
    --cleanup)      CLEANUP=1; shift ;;
    --no-start)     NO_START=1; shift ;;
    --skip-rce)     SKIP_RCE=1; shift ;;
    --size|--repeat|--concurrency|--delay|--jitter|--sustain|--max-requests)
                    EXTRA+=("$1" "$2"); shift 2 ;;
    -h|--help)      sed -n '2,14p' "$0"; exit 0 ;;
    *)              echo "Opcion desconocida: $1" >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null || { echo "[!] docker no disponible" >&2; exit 1; }

TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p lab/reports

wait_url() {
  local url="$1" label="$2"
  for i in $(seq 1 45); do
    if curl -fsS -o /dev/null --max-time 2 "$url"; then
      echo "[i] $label listo tras ${i}s"
      return 0
    fi
    sleep 1
  done
  echo "[!] $label no responde en $url" >&2
  docker compose -f "$COMPOSE" ps >&2 || true
  return 1
}

echo "== [0/7] Preparacion =="
if [ "$NO_START" -eq 0 ]; then
  docker compose -f "$COMPOSE" up -d
else
  echo "[i] --no-start: se asume el stack ya levantado"
fi

echo "== [1/7] Acto 1: CVE-2026-109618/619 (recon + validate + impact) =="
wait_url "$URL" "CVE target"
set +e
python3 lab/rt.py all \
  --url "$URL" \
  --docker-inspect \
  --compose-file "$COMPOSE" \
  "${EXTRA[@]}" | tee "lab/reports/run-${TS}.log"
set -e

echo "== [2/7] Capturando logs del stack CVE =="
docker compose -f "$COMPOSE" logs --since=15m php   > "lab/reports/${TS}-fpm.log"   2>&1 || true
docker compose -f "$COMPOSE" logs --since=15m nginx > "lab/reports/${TS}-nginx.log" 2>&1 || true

RCE_JSON=""
if [ "$SKIP_RCE" -eq 1 ]; then
  echo "== [3/7] Acto 2: RCE omitido (--skip-rce) =="
else
  echo "== [3/7] Acto 2: RCE en app vulnerable por diseno =="
  wait_url "$TARGET_URL" "RCE target"
  MARKER="lab/reports/.rce-marker-${TS}"
  touch "$MARKER"
  set +e
  python3 lab/rce.py --url "$TARGET_URL" | tee "lab/reports/run-${TS}-rce.log"
  set -e
  RCE_JSON=$(find lab/reports -maxdepth 1 -name 'rce-*.json' -newer "$MARKER" | sort | tail -n 1 || true)
  rm -f "$MARKER"
fi

echo "== [4/7] Evidencias agregadas =="
./collect-evidence.sh > "lab/reports/${TS}-evidence.txt" 2>&1 || true

echo "== [5/7] Evaluacion de objetivos y flag =="
CAP_ARGS=(--fpm-log "lab/reports/${TS}-fpm.log" --nginx-log "lab/reports/${TS}-nginx.log")
if [ -n "$RCE_JSON" ]; then
  CAP_ARGS+=(--rce-report "$RCE_JSON")
fi
set +e
python3 lab/rt.py capture "${CAP_ARGS[@]}" | tee "lab/reports/run-${TS}-capture.log"
CAP_RC=${PIPESTATUS[0]}
set -e

echo "== [6/7] Resumen =="
echo "[i] CVE log    : lab/reports/run-${TS}.log"
echo "[i] FPM        : lab/reports/${TS}-fpm.log"
echo "[i] nginx      : lab/reports/${TS}-nginx.log"
echo "[i] RCE log    : lab/reports/run-${TS}-rce.log"
echo "[i] Evidencias : lab/reports/${TS}-evidence.txt"
echo "[i] Scoreboard : lab/reports/scoreboard.md"
echo
echo "-- Fatals / muertes de worker --"
grep -E 'Fatal error|exited with code|SIGSEGV|child .* started' \
  "lab/reports/${TS}-fpm.log" | tail -n 10 || true
echo "-- 502 / FastCGI --"
grep -E ' 502 |unexpected FastCGI|upstream prematurely' \
  "lab/reports/${TS}-nginx.log" | tail -n 10 || true
if [ -f lab/reports/FLAG.txt ]; then
  echo "-- Flag --"
  cat lab/reports/FLAG.txt
fi

echo "== [7/7] Cleanup =="
if [ "$CLEANUP" -eq 1 ]; then
  docker compose -f "$COMPOSE" exec -T php sh -c 'rm -f /tmp/sess_*' 2>/dev/null || true
  docker compose -f "$COMPOSE" down -v
else
  echo "[i] Stack conservado. Usa --cleanup para borrar contenedores y sesiones."
fi

exit "$CAP_RC"
