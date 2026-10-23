#!/usr/bin/env bash
# Traza las syscalls del worker PHP-FPM con strace.
#
# No hace falta instalar strace en la VM: el script construye una imagen
# Debian mínima (lab/os-activity/Dockerfile.trace) y la ejecuta compartiendo el
# PID namespace del contenedor PHP, con CAP_SYS_PTRACE.
#
# Uso:
#   ./trace-worker.sh 60
#   ./trace-worker.sh 10 --with-trigger --url http://127.0.0.1:8080/
#   ./trace-worker.sh 10 --out lab/os-activity/out/mi-traza
#
# En la primera forma, dispara tú el trigger en otra terminal:
#   python3 trigger.py --url http://127.0.0.1:8080/ --mode progress
#
# Variables:
#   PHP_CONTAINER=php2shell-lab-php-1
#   TRACE_IMAGE=php2shell-os-trace
#   TRACE_EVENTS=mmap,munmap,mprotect,brk,openat,open,read,write,close,...
set -uo pipefail

ACT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$ACT_DIR/../.." && pwd)
cd "$ROOT" || exit 1

DURATION=60
OUTDIR=""
WITH_TRIGGER=0
URL=${LAB_URL:-http://127.0.0.1:8080/}
PHP_CONTAINER=${PHP_CONTAINER:-php2shell-lab-php-1}
TRACE_IMAGE=${TRACE_IMAGE:-php2shell-os-trace}
TRIGGER_SIZE=${TRIGGER_SIZE:-1048576}
TRIGGER_MODE=${TRIGGER_MODE:-progress}
EVENTS=${TRACE_EVENTS:-mmap,munmap,mprotect,brk,openat,open,read,write,close,clone,clone3,execve,wait4,exit_group,accept4,recvfrom,sendto}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      sed -n '2,19p' "$0"
      exit 0
      ;;
    --with-trigger) WITH_TRIGGER=1; shift ;;
    --url) URL="$2"; shift 2 ;;
    --out) OUTDIR="$2"; shift 2 ;;
    --image) TRACE_IMAGE="$2"; shift 2 ;;
    --events) EVENTS="$2"; shift 2 ;;
    [0-9]*)
      case "$1" in
        *[!0-9]*) echo "[!] Duración no válida: $1" >&2; exit 2 ;;
        *) DURATION="$1"; shift ;;
      esac
      ;;
    *) echo "[!] Opción desconocida: $1" >&2; exit 2 ;;
  esac
done

if ! docker inspect "$PHP_CONTAINER" >/dev/null 2>&1; then
  echo "[!] El contenedor '$PHP_CONTAINER' no está levantado." >&2
  exit 1
fi

inside_worker_pid() {
  docker exec "$PHP_CONTAINER" sh -c '
    for d in /proc/[0-9]*; do
      comm=$(cat "$d/comm" 2>/dev/null) || continue
      [ "$comm" = "php-fpm" ] || continue
      c=$(tr "\0" " " < "$d/cmdline" 2>/dev/null) || continue
      case "$c" in
        *"php-fpm: pool "*) echo "${d#/proc/}"; exit 0 ;;
      esac
    done
    exit 1
  ' 2>/dev/null
}

HOST_PID=$(docker top "$PHP_CONTAINER" -eo pid,ppid,user,args 2>/dev/null \
  | awk 'NR > 1 && /php-fpm: pool / {print $1; exit}')
INSIDE_PID=$(inside_worker_pid || true)

if [ -z "${INSIDE_PID:-}" ]; then
  echo "[!] No encuentro un worker 'php-fpm: pool ...' dentro de $PHP_CONTAINER." >&2
  docker top "$PHP_CONTAINER" -eo pid,ppid,user,args >&2 || true
  exit 1
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
OUTDIR=${OUTDIR:-$ROOT/lab/os-activity/out/${TS}-trace}
mkdir -p "$OUTDIR"
OUTDIR=$(cd "$OUTDIR" && pwd)
LOGNAME="strace-${TS}-pid${INSIDE_PID}.log"
LOG="$OUTDIR/$LOGNAME"

if ! docker image inspect "$TRACE_IMAGE" >/dev/null 2>&1; then
  echo "[i] Construyendo imagen de trazado '$TRACE_IMAGE' (solo la primera vez)..."
  if ! docker build -t "$TRACE_IMAGE" -f "$ACT_DIR/Dockerfile.trace" "$ACT_DIR"; then
    echo "[!] No se pudo construir la imagen de trazado." >&2
    echo "    Alternativa sin strace: ./collect-snapshot.sh y pidstat." >&2
    exit 1
  fi
fi

echo "[i] Contenedor : $PHP_CONTAINER"
echo "[i] Worker     : host PID ${HOST_PID:-n/a} / dentro PID $INSIDE_PID"
echo "[i] Duración   : ${DURATION}s"
echo "[i] Eventos    : $EVENTS"
echo "[i] Salida     : $LOG"

TRIGGER_PID=""
if [ "$WITH_TRIGGER" -eq 1 ]; then
  (
    sleep 1
    python3 "$ROOT/trigger.py" \
      --url "$URL" \
      --mode "$TRIGGER_MODE" \
      --size "$TRIGGER_SIZE" \
      --timeout 30
  ) >"$OUTDIR/trigger.log" 2>&1 &
  TRIGGER_PID=$!
  echo "[i] Trigger lanzado en segundo plano contra $URL (log: trigger.log)"
else
  echo "[i] Dispara el trigger en otra terminal mientras dura la traza:"
  echo "    python3 trigger.py --url $URL --mode $TRIGGER_MODE"
fi

# El helper comparte el PID namespace del contenedor PHP. Por eso -p usa el
# PID interno ($INSIDE_PID), no el PID del host.
docker run --rm \
  --pid="container:$PHP_CONTAINER" \
  --cap-add=SYS_PTRACE \
  --security-opt no-new-privileges=true \
  -v "$OUTDIR:/out" \
  --entrypoint timeout \
  "$TRACE_IMAGE" \
  "$DURATION" \
  strace -f -tt -T -yy -s 256 \
    -e "trace=$EVENTS" \
    -p "$INSIDE_PID" \
    -o "/out/$LOGNAME" 2>&1 | tee "$OUTDIR/strace-console.log"

if [ -n "${TRIGGER_PID:-}" ]; then
  wait "$TRIGGER_PID" 2>/dev/null || true
fi

AFTER_INSIDE=$(inside_worker_pid || true)
AFTER_HOST=$(docker top "$PHP_CONTAINER" -eo pid,ppid,user,args 2>/dev/null \
  | awk 'NR > 1 && /php-fpm: pool / {print $1; exit}')

[ -f "$LOG" ] || : >"$LOG"

{
  echo "timestamp_utc=$TS"
  echo "container=$PHP_CONTAINER"
  echo "host_pid_before=${HOST_PID:-}"
  echo "inside_pid_before=$INSIDE_PID"
  echo "host_pid_after=${AFTER_HOST:-}"
  echo "inside_pid_after=${AFTER_INSIDE:-}"
  echo "duration_s=$DURATION"
  echo "events=$EVENTS"
  echo "trace_file=$LOG"
} >"$OUTDIR/trace-meta.txt"

count() { grep -F -c -- "$1" "$LOG" 2>/dev/null || true; }

{
  echo "# Resumen de traza strace"
  echo
  echo "- Worker antes: host PID ${HOST_PID:-n/a}, interno $INSIDE_PID"
  echo "- Worker después: host PID ${AFTER_HOST:-n/a}, interno ${AFTER_INSIDE:-n/a}"
  echo "- Duración: ${DURATION}s"
  echo
  echo "## Conteos"
  echo "- mmap:        $(count 'mmap(')"
  echo "- munmap:      $(count 'munmap(')"
  echo "- openat:      $(count 'openat(')"
  echo "- write:       $(count 'write(')"
  echo "- clone/clone3:$(count 'clone(') / $(count 'clone3(')"
  echo "- exit_group:  $(count 'exit_group(')"
  echo "- /tmp/sess_:  $(count '/tmp/sess_')"
  echo "- 'Fatal error': $(count 'Fatal error')"
  echo
  echo "## Líneas clave"
  grep -E 'mmap\(NULL, 2097152|/tmp/sess_|Fatal error|exit_group|SIGSEGV|SIGKILL' "$LOG" 2>/dev/null \
    | tail -n 30 || true
} >"$OUTDIR/summary.txt"

echo
echo "[i] Traza guardada en: $LOG"
echo "[i] Resumen: $OUTDIR/summary.txt"
if [ -n "${AFTER_INSIDE:-}" ] && [ "$AFTER_INSIDE" != "$INSIDE_PID" ]; then
  echo "[i] El worker cambió durante la traza (antes $INSIDE_PID, ahora $AFTER_INSIDE)."
elif [ -z "${AFTER_INSIDE:-}" ]; then
  echo "[!] No hay worker después de la traza; revisa los logs de PHP-FPM."
fi
