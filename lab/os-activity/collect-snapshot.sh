#!/usr/bin/env bash
# Recolector de evidencias OS del lab PHP2Shell.
#
# Captura, sin modificar el estado del laboratorio:
#   - procesos FPM (máster/hijos) y sus PIDs dentro/fuera del contenedor
#   - /proc/<pid>/{status,stat,limits,cgroup,wchan,...}
#   - cgroup v2: memory.current/peak/max/events y pids.current/max
#   - docker stats y pidstat (si está instalado)
#   - montajes, tmpfs, inodos, permisos y ficheros de sesión
#   - logs de PHP-FPM/nginx y evidencia de OOM del kernel
#
# Uso:
#   ./collect-snapshot.sh baseline
#   ./collect-snapshot.sh after /ruta/de/salida
#
# Variables:
#   PHP_CONTAINER=php2shell-lab-php-1
#   TARGET_CONTAINER=php2shell-lab-target-1
#   COMPOSE_FILE=docker-compose.yml
#   OUT_ROOT=lab/os-activity/out
set -uo pipefail

ACT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$ACT_DIR/../.." && pwd)
cd "$ROOT" || exit 1

LABEL=${1:-snapshot}
PHP_CONTAINER=${PHP_CONTAINER:-php2shell-lab-php-1}
TARGET_CONTAINER=${TARGET_CONTAINER:-php2shell-lab-target-1}
COMPOSE_FILE=${COMPOSE_FILE:-docker-compose.yml}
OUT_ROOT=${OUT_ROOT:-$ROOT/lab/os-activity/out}
SNAPSHOT_SINCE=${SNAPSHOT_SINCE:-15m}
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT=${2:-$OUT_ROOT/${TS}-${LABEL}}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

log() { printf '[i] %s\n' "$*"; }

if ! docker inspect "$PHP_CONTAINER" >/dev/null 2>&1; then
  echo "[!] El contenedor '$PHP_CONTAINER' no existe o no está levantado." >&2
  echo "    Levanta el stack con: docker compose -f $COMPOSE_FILE up -d php nginx" >&2
  exit 1
fi

cgroup_path() {
  local cid=$1 p
  for p in \
    "/sys/fs/cgroup/system.slice/docker-${cid}.scope" \
    "/sys/fs/cgroup/docker/${cid}" \
    "/sys/fs/cgroup/${cid}"; do
    if [ -d "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  find /sys/fs/cgroup -maxdepth 6 -type d -name "*${cid}*" 2>/dev/null | head -n 1
}

inside_worker_pids() {
  docker exec "$PHP_CONTAINER" sh -c '
    for d in /proc/[0-9]*; do
      comm=$(cat "$d/comm" 2>/dev/null) || continue
      [ "$comm" = "php-fpm" ] || continue
      c=$(tr "\0" " " < "$d/cmdline" 2>/dev/null) || continue
      case "$c" in
        *"php-fpm: pool "*) echo "${d#/proc/}" ;;
      esac
    done
  ' 2>/dev/null || true
}

CID=$(docker inspect -f '{{.Id}}' "$PHP_CONTAINER" 2>/dev/null || true)
IMAGE=$(docker inspect -f '{{.Config.Image}}' "$PHP_CONTAINER" 2>/dev/null || true)
CGROUP=$(cgroup_path "$CID")
WORKERS=$(docker top "$PHP_CONTAINER" -eo pid,ppid,user,args 2>/dev/null \
  | awk 'NR > 1 && /php-fpm: pool / {print $1}')
MASTER=$(docker top "$PHP_CONTAINER" -eo pid,ppid,user,args 2>/dev/null \
  | awk 'NR > 1 && /php-fpm: master process/ {print $1; exit}')
INSIDE_WORKERS=$(inside_worker_pids)

# --------------------------------------------------------------------------- #
# 1. Metadatos del host y del contenedor
# --------------------------------------------------------------------------- #
{
  echo "label=$LABEL"
  echo "timestamp_utc=$TS"
  date -Is
  uname -a
  echo "host=$(hostname)"
  echo "container=$PHP_CONTAINER"
  echo "container_id=$CID"
  echo "image=$IMAGE"
  echo "cgroup=$CGROUP"
  echo "host_master_pid=$MASTER"
  echo "host_worker_pids=$WORKERS"
  echo "inside_worker_pids=$INSIDE_WORKERS"
  echo
  echo "## docker inspect (límites relevantes)"
  docker inspect -f \
    'Memory={{.HostConfig.Memory}} MemorySwap={{.HostConfig.MemorySwap}} PidsLimit={{.HostConfig.PidsLimit}} ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}}' \
    "$PHP_CONTAINER" 2>&1 || true
  echo
  echo "## compose ps"
  docker compose -f "$COMPOSE_FILE" ps 2>&1 || true
} >"$OUT/meta.txt"

docker top "$PHP_CONTAINER" -eo pid,ppid,user,args >"$OUT/docker-top.txt" 2>&1 || true
ps -eo pid,ppid,user,rss,vsz,stat,comm,args --forest >"$OUT/ps-host.txt" 2>&1 || true

# --------------------------------------------------------------------------- #
# 2. /proc de cada worker y pidstat
# --------------------------------------------------------------------------- #
for p in $WORKERS; do
  {
    echo "## /proc/$p/status"
    cat "/proc/$p/status" 2>&1 || true
    echo
    echo "## /proc/$p/stat (campos 1-25)"
    awk '{for (i=1; i<=25 && i<=NF; i++) printf "%s%s", $i, (i<25 && i<NF ? " " : "\n")}' \
      "/proc/$p/stat" 2>&1 || true
    echo
    echo "## /proc/$p/limits"
    cat "/proc/$p/limits" 2>&1 || true
    echo
    echo "## /proc/$p/cgroup"
    cat "/proc/$p/cgroup" 2>&1 || true
    echo
    echo "## /proc/$p/wchan"
    cat "/proc/$p/wchan" 2>&1 || true
    echo
    echo "## /proc/$p/cmdline"
    tr '\0' '\n' <"/proc/$p/cmdline" 2>&1 || true
    echo
    echo "## /proc/$p/mountinfo"
    cat "/proc/$p/mountinfo" 2>&1 || true
    echo
    echo "## /proc/$p/smaps_rollup (puede fallar por ptrace/Yama)"
    cat "/proc/$p/smaps_rollup" 2>&1 || true
    echo
    echo "## /proc/$p/fd (puede fallar por ptrace/Yama)"
    ls -l "/proc/$p/fd" 2>&1 || true
    echo
    echo "## /proc/$p/task"
    ls -l "/proc/$p/task" 2>&1 || true
  } >"$OUT/worker-${p}-proc.txt" 2>&1

  if command -v pidstat >/dev/null 2>&1; then
    pidstat -p "$p" -r -u -d 1 1 >"$OUT/pidstat-${p}.txt" 2>&1 || true
  else
    echo "pidstat no instalado" >"$OUT/pidstat-${p}.txt"
  fi
done

# --------------------------------------------------------------------------- #
# 3. cgroup v2 y memoria del host
# --------------------------------------------------------------------------- #
if [ -n "${CGROUP:-}" ] && [ -d "$CGROUP" ]; then
  for f in memory.current memory.max memory.peak memory.events memory.stat \
           pids.current pids.max cpu.stat; do
    [ -r "$CGROUP/$f" ] && cp "$CGROUP/$f" "$OUT/cgroup-${f}.txt" 2>/dev/null || true
  done
else
  echo "No se encontró el cgroup del contenedor." >"$OUT/cgroup-missing.txt"
fi

{
  free -h 2>&1 || true
  echo
  grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|AnonPages|Mapped|Dirty|Writeback):' \
    /proc/meminfo 2>&1 || true
  echo
  echo "## vmstat"
  vmstat 1 3 2>&1 || true
} >"$OUT/host-memory.txt"

{
  df -hT 2>&1 || true
  echo
  findmnt -T / 2>&1 || true
  echo
  findmnt -t tmpfs,cgroup2 2>&1 || true
} >"$OUT/host-fs.txt"

if docker inspect "$PHP_CONTAINER" >/dev/null 2>&1; then
  docker stats --no-stream --format \
    'table {{.Name}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.PIDs}}' \
    "$PHP_CONTAINER" >"$OUT/docker-stats.txt" 2>&1 || true
fi

# --------------------------------------------------------------------------- #
# 4. Sistemas de archivos dentro del contenedor PHP
# --------------------------------------------------------------------------- #
{
  echo "## findmnt /tmp"
  docker exec "$PHP_CONTAINER" findmnt -T /tmp 2>&1 || true
  echo
  echo "## findmnt /var/www/html"
  docker exec "$PHP_CONTAINER" findmnt -T /var/www/html 2>&1 || true
  echo
  echo "## df -hT /tmp /var/www/html"
  docker exec "$PHP_CONTAINER" df -hT /tmp /var/www/html 2>&1 || true
  echo
  echo "## df -i /tmp /var/www/html (inodos)"
  docker exec "$PHP_CONTAINER" df -i /tmp /var/www/html 2>&1 || true
  echo
  echo "## stat /tmp"
  docker exec "$PHP_CONTAINER" stat -c \
    'inode=%i mode=%a owner=%U:%G size=%s name=%n' /tmp 2>&1 || true
  echo
  echo "## stat -f /tmp (tmpfs)"
  docker exec "$PHP_CONTAINER" stat -f -c \
    'type=%T block_size=%s blocks=%b free_blocks=%f files=%c free_files=%d' \
    /tmp 2>&1 || true
  echo
  echo "## ficheros de sesión (inodo, modo, dueño, tamaño)"
  docker exec "$PHP_CONTAINER" sh -c '
    for f in /tmp/sess_*; do
      [ -e "$f" ] || continue
      stat -c "%i %a %U:%G %s %n" "$f"
    done
  ' 2>&1 || true
  echo
  echo "## listado /tmp (primeras 20 entradas)"
  docker exec "$PHP_CONTAINER" ls -lai /tmp 2>&1 | head -n 20 || true
  echo
  echo "## contenido de sesión (primeros 300 bytes, bytes no imprimibles como punto)"
  docker exec "$PHP_CONTAINER" sh -c '
    for f in /tmp/sess_*; do
      [ -e "$f" ] || continue
      echo "--- $f"
      head -c 300 "$f" 2>/dev/null | tr -c "[:print:]\n" "."
      echo
    done
  ' 2>&1 || true
  echo
  echo "## prueba de escritura en el rootfs /var/www/html"
  docker exec "$PHP_CONTAINER" sh -c '
    if touch /var/www/html/.os-activity-write-test 2>/tmp/os-activity-write.err; then
      echo "WRITE_OK (inesperado)"
      rm -f /var/www/html/.os-activity-write-test
    else
      echo "WRITE_FAILED (esperado)"
      cat /tmp/os-activity-write.err 2>/dev/null
    fi
  ' 2>&1 || true
  echo
  echo "## descriptores del PID 1 (máster FPM)"
  docker exec "$PHP_CONTAINER" sh -c 'ls /proc/1/fd 2>/dev/null | wc -l' 2>&1 || true
  echo
  echo "## montajes del contenedor (filtrado)"
  docker exec "$PHP_CONTAINER" sh -c \
    'cat /proc/self/mountinfo' 2>&1 \
    | grep -E ' /tmp | /var/www/html | /var/www/html/uploads ' || true
} >"$OUT/container-fs.txt" 2>&1

if docker inspect "$TARGET_CONTAINER" >/dev/null 2>&1; then
  {
    echo "## target: findmnt /var/www/html/uploads"
    docker exec "$TARGET_CONTAINER" findmnt -T /var/www/html/uploads 2>&1 || true
    echo
    echo "## target: stat -f uploads"
    docker exec "$TARGET_CONTAINER" stat -f -c \
      'type=%T block_size=%s blocks=%b free_blocks=%f files=%c free_files=%d' \
      /var/www/html/uploads 2>&1 || true
    echo
    echo "## target: uploads"
    docker exec "$TARGET_CONTAINER" ls -lai /var/www/html/uploads 2>&1 || true
  } >"$OUT/target-fs.txt" 2>&1
fi

# --------------------------------------------------------------------------- #
# 5. Logs y evidencia de OOM del kernel
# --------------------------------------------------------------------------- #
docker compose -f "$COMPOSE_FILE" logs --since="$SNAPSHOT_SINCE" php >"$OUT/php.log" 2>&1 || true
docker compose -f "$COMPOSE_FILE" logs --since="$SNAPSHOT_SINCE" nginx >"$OUT/nginx.log" 2>&1 || true

{
  echo "## dmesg (requiere permisos)"
  dmesg 2>&1 | grep -iE 'out of memory|oom-kill|killed process' | tail -n 50 || true
  echo
  echo "## journalctl -k (requiere permisos)"
  journalctl -k --since '-15min' 2>&1 \
    | grep -iE 'out of memory|oom-kill|killed process' | tail -n 50 || true
} >"$OUT/kernel-oom.txt" 2>&1

# --------------------------------------------------------------------------- #
# 6. Resumen legible
# --------------------------------------------------------------------------- #
cg() {
  [ -n "${CGROUP:-}" ] && [ -r "$CGROUP/$1" ] && cat "$CGROUP/$1" 2>/dev/null || true
}

proc_fields() {
  local p=$1
  awk -F: '
    /^Name:|^State:|^Pid:|^PPid:|^Uid:|^Gid:|^VmPeak:|^VmSize:|^VmRSS:|^RssAnon:|^RssFile:|^Threads:/ {
      v=$2
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      gsub(/\t/, " ", v)
      printf "%s=%s ", $1, v
    }
  ' "/proc/$p/status" 2>/dev/null || true
}

{
  echo "# Snapshot OS: $LABEL"
  echo
  echo "- Fecha UTC: $TS"
  echo "- Contenedor: $PHP_CONTAINER ($IMAGE)"
  echo "- cgroup: ${CGROUP:-no encontrado}"
  echo "- Máster FPM (host): ${MASTER:-n/a}"
  echo "- Workers FPM (host): ${WORKERS:-n/a}"
  echo "- Workers FPM (dentro del contenedor): ${INSIDE_WORKERS:-n/a}"
  echo
  echo "## Memoria (cgroup v2)"
  echo "- memory.current: $(cg memory.current) bytes"
  echo "- memory.peak:    $(cg memory.peak) bytes"
  echo "- memory.max:     $(cg memory.max) bytes"
  echo "- pids.current:   $(cg pids.current)"
  echo "- pids.max:       $(cg pids.max)"
  if [ -n "${CGROUP:-}" ] && [ -r "$CGROUP/memory.events" ]; then
    echo "- memory.events:"
    sed 's/^/    /' "$CGROUP/memory.events"
  fi
  echo
  echo "## Procesos (host /proc)"
  if [ -n "${WORKERS:-}" ]; then
    for p in $WORKERS; do
      echo "- PID $p: $(proc_fields "$p")"
    done
  else
    echo "- Sin worker FPM visible."
  fi
  echo
  echo "## Sistemas de archivos"
  echo "- /tmp: $(grep -m1 '^/tmp ' "$OUT/container-fs.txt" 2>/dev/null || echo 'ver container-fs.txt')"
  echo "- /var/www/html: $(grep -m1 '^/var/www/html ' "$OUT/container-fs.txt" 2>/dev/null || echo 'ver container-fs.txt')"
  echo "- Escritura en rootfs: $(grep -m1 -E 'WRITE_OK|WRITE_FAILED' "$OUT/container-fs.txt" 2>/dev/null || echo 'ver container-fs.txt')"
  echo "- Ficheros de sesión:"
  docker exec "$PHP_CONTAINER" sh -c '
    found=0
    for f in /tmp/sess_*; do
      [ -e "$f" ] || continue
      stat -c "    inode=%i modo=%a dueño=%U:%G tamaño=%s %n" "$f"
      found=1
    done
    [ "$found" -eq 1 ] || echo "    (ninguno)"
  ' 2>/dev/null || true
  echo
  echo "## Logs relevantes"
  echo "- PHP-FPM:"
  grep -E 'Fatal error|exited with code|child .* started|SIGSEGV|OOM' \
    "$OUT/php.log" 2>/dev/null | tail -n 6 | sed 's/^/    /' || true
  echo "- nginx:"
  grep -E ' 502 |unexpected FastCGI|upstream prematurely|client request body' \
    "$OUT/nginx.log" 2>/dev/null | tail -n 6 | sed 's/^/    /' || true
  echo
  echo "## Kernel OOM"
  if grep -qiE 'out of memory|oom-kill|killed process' "$OUT/kernel-oom.txt" 2>/dev/null; then
    echo "- Hay líneas de OOM del kernel; revisar kernel-oom.txt."
  else
    echo "- Sin evidencia de OOM del kernel (o sin permisos para leer dmesg/journalctl)."
  fi
} >"$OUT/summary.txt" 2>&1

log "snapshot guardado en: $OUT"
log "resumen: $OUT/summary.txt"
printf '\n'
sed -n '1,80p' "$OUT/summary.txt"
