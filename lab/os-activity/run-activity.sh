#!/usr/bin/env bash
# Actividad OS end-to-end: baseline -> sesión -> traza + OOM -> snapshot final.
#
# Hace esto, en este orden:
#   1. snapshot "baseline" (procesos, memoria, cgroup, filesystem)
#   2. valida el handler de sesión (crea un archivo sess_* en /tmp)
#   3. traza el worker con strace y dispara el OOM controlado
#   4. snapshot "after" y resumen
#
# Uso:
#   ./run-activity.sh
#   ./run-activity.sh --start
#   ./run-activity.sh --url http://127.0.0.1:18080/ --duration 10
#   ./run-activity.sh --no-trace          # sin strace; solo trigger + snapshots
#   ./run-activity.sh --fresh             # recrea php (resetea memory.peak)
#
# Variables:
#   LAB_URL, COMPOSE_FILE, PHP_CONTAINER, OUT_ROOT
set -uo pipefail

ACT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$ACT_DIR/../.." && pwd)
cd "$ROOT" || exit 1

URL=${LAB_URL:-http://127.0.0.1:8080/}
COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.yml}
PHP_CONTAINER=${PHP_CONTAINER:-php2shell-lab-php-1}
OUT_ROOT=${OUT_ROOT:-$ROOT/lab/os-activity/out}
DURATION=${DURATION:-8}
START=0
NO_TRACE=0
FRESH=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    --start) START=1; shift ;;
    --no-trace) NO_TRACE=1; shift ;;
    --fresh) FRESH=1; shift ;;
    --url) URL="$2"; shift 2 ;;
    --compose-file) COMPOSE_FILE="$2"; shift 2 ;;
    --container) PHP_CONTAINER="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    *) echo "[!] Opción desconocida: $1" >&2; exit 2 ;;
  esac
done

export PHP_CONTAINER COMPOSE_FILE

if ! command -v docker >/dev/null 2>&1; then
  echo "[!] Docker no está disponible." >&2
  exit 1
fi

if [ "$START" -eq 1 ]; then
  echo "[i] Levantando PHP-FPM + nginx..."
  docker compose -f "$COMPOSE_FILE" up -d php nginx || exit 1
fi

if [ "$FRESH" -eq 1 ]; then
  echo "[i] Recreando PHP para resetear memory.peak del cgroup..."
  docker compose -f "$COMPOSE_FILE" up -d --force-recreate php || exit 1
  # nginx resuelve `php:9000` al arrancar; reiniciarlo evita conservar una IP vieja.
  docker compose -f "$COMPOSE_FILE" restart nginx || true
fi

if ! docker inspect "$PHP_CONTAINER" >/dev/null 2>&1; then
  echo "[!] El contenedor '$PHP_CONTAINER' no está levantado." >&2
  echo "    Usa ./run-activity.sh --start o levanta el stack manualmente." >&2
  exit 1
fi

wait_url() {
  local i
  for i in $(seq 1 45); do
    if curl -fsS -o /dev/null --max-time 2 "$URL"; then
      echo "[i] Objetivo disponible tras ${i}s: $URL"
      return 0
    fi
    sleep 1
  done
  echo "[!] $URL no responde. ¿Puerto ocupado o stack parado?" >&2
  docker compose -f "$COMPOSE_FILE" ps >&2 || true
  return 1
}

wait_url || exit 1

TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$OUT_ROOT/${TS}-activity"
mkdir -p "$OUT"
ln -sfn "$OUT" "$OUT_ROOT/latest" 2>/dev/null || true

# Logs de esta ejecución, no de pruebas anteriores.
export SNAPSHOT_SINCE=${SNAPSHOT_SINCE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
echo "[i] Logs desde: $SNAPSHOT_SINCE"

echo
echo "== [1/6] Snapshot baseline =="
"$ACT_DIR/collect-snapshot.sh" baseline "$OUT/baseline" || exit 1

echo
echo "== [2/6] Validación del handler y creación de sesión =="
python3 lab/rt.py validate \
  --url "$URL" \
  --docker-inspect \
  --compose-file "$COMPOSE_FILE" 2>&1 | tee "$OUT/validate.log"

# Localiza el cgroup v2 para el muestreo de memoria.
CID=$(docker inspect -f '{{.Id}}' "$PHP_CONTAINER" 2>/dev/null || true)
CGROUP=""
for p in \
  "/sys/fs/cgroup/system.slice/docker-${CID}.scope" \
  "/sys/fs/cgroup/docker/${CID}" \
  "/sys/fs/cgroup/${CID}"; do
  if [ -d "$p" ]; then CGROUP="$p"; break; fi
done
if [ -z "$CGROUP" ]; then
  CGROUP=$(find /sys/fs/cgroup -maxdepth 6 -type d -name "*${CID}*" 2>/dev/null | head -n 1)
fi

TIMELINE="$OUT/memory-timeline.tsv"
printf 'timestamp_utc\tmemory.current\tmemory.peak\tpids.current\tworker_host_pid\tworker_vmrss_kb\n' >"$TIMELINE"

sampler() {
  local w rss
  while [ ! -f "$OUT/.stop-sampler" ]; do
    w=$(docker top "$PHP_CONTAINER" -eo pid,ppid,user,args 2>/dev/null \
      | awk 'NR > 1 && /php-fpm: pool / {print $1; exit}')
    rss=""
    if [ -n "${w:-}" ] && [ -r "/proc/$w/status" ]; then
      rss=$(awk '/^VmRSS:/{print $2}' "/proc/$w/status" 2>/dev/null)
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
      "$(cat "$CGROUP/memory.current" 2>/dev/null)" \
      "$(cat "$CGROUP/memory.peak" 2>/dev/null)" \
      "$(cat "$CGROUP/pids.current" 2>/dev/null)" \
      "${w:-}" \
      "${rss:-}" >>"$TIMELINE"
    sleep 0.2
  done
}

echo
echo "== [3/6] Traza + OOM controlado =="
if [ -z "$CGROUP" ]; then
  echo "[!] No se encontró el cgroup; el timeline no tendrá memoria." >&2
  SAMPLER_PID=""
else
  sampler &
  SAMPLER_PID=$!
fi

if [ "$NO_TRACE" -eq 1 ]; then
  echo "[i] --no-trace: disparando trigger sin strace..."
  (
    sleep 1
    python3 "$ROOT/trigger.py" \
      --url "$URL" --mode progress --size 1048576 --timeout 30
  ) >"$OUT/trigger.log" 2>&1
else
  "$ACT_DIR/trace-worker.sh" "$DURATION" \
    --with-trigger \
    --url "$URL" \
    --out "$OUT/trace" | tee "$OUT/trace-console.log"
fi

touch "$OUT/.stop-sampler"
if [ -n "${SAMPLER_PID:-}" ]; then
  wait "$SAMPLER_PID" 2>/dev/null || true
fi
rm -f "$OUT/.stop-sampler"
sleep 1

echo
echo "== [4/6] Snapshot final =="
"$ACT_DIR/collect-snapshot.sh" after "$OUT/after" || true

echo
echo "== [5/6] Resumen =="
{
  echo "# Actividad OS — resumen automático"
  echo
  echo "- Fecha UTC: $TS"
  echo "- Objetivo: $URL"
  echo "- Contenedor: $PHP_CONTAINER"
  echo "- Evidencias: \`$OUT\`"
  echo
  echo "## Memoria (cgroup v2, snapshot final)"
  grep -E 'memory\.(current|peak|max)|pids\.(current|max)' \
    "$OUT/after/summary.txt" 2>/dev/null || true
  echo
  echo "## Procesos"
  grep -E 'Maestro FPM|Workers FPM|PID [0-9]+:|exited with code|child [0-9]+ started' \
    "$OUT/after/summary.txt" 2>/dev/null || true
  echo
  echo "## Sistemas de archivos"
  grep -E '^[[:space:]]*- /tmp|^[[:space:]]*- /var/www/html|^[[:space:]]*- Escritura|inode=|ninguno' \
    "$OUT/after/summary.txt" 2>/dev/null || true
  echo
  echo "## Traza de syscalls"
  if [ -f "$OUT/trace/summary.txt" ]; then
    sed -n '1,80p' "$OUT/trace/summary.txt"
  else
    echo "Sin traza (--no-trace o fallo de strace)."
  fi
  echo
  echo "## Timeline de memoria"
  echo "Ver \`$TIMELINE\` (muestras cada 200 ms)."
  echo
  echo "## Siguiente paso"
  echo "Usa estas evidencias para armar tu informe y exportarlo a PDF."
} >"$OUT/summary.md"

sed -n '1,160p' "$OUT/summary.md"

echo
echo "== [6/6] Fin =="
echo "[i] Directorio de evidencias: $OUT"
echo "[i] Baseline : $OUT/baseline/summary.txt"
echo "[i] Después  : $OUT/after/summary.txt"
echo "[i] Traza    : $OUT/trace/summary.txt"
echo "[i] Timeline : $TIMELINE"
echo "[i] Resumen  : $OUT/summary.md"
echo
echo "Para limpiar: docker compose -f $COMPOSE_FILE down -v"
