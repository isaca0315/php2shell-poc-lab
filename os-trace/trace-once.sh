#!/usr/bin/env bash
# Captura única: strace + pidstat + snapshot de /proc + cgroup
set -u
cd "$(dirname "$0")/.."

OUTDIR="os-trace"
mkdir -p "$OUTDIR"
TS=$(date +%Y%m%d_%H%M%S)

PID=$(docker top php2shell-lab-php-1 2>&1 | awk '/php-fpm: pool www/{print $1; exit}')
if [ -z "${PID:-}" ]; then echo "[!] sin worker"; exit 1; fi
echo "[i] PID=$PID"

# snapshot proc
cat /proc/$PID/status 2>/dev/null > "$OUTDIR/proc_status_${TS}.txt"
cat /proc/$PID/maps  2>/dev/null > "$OUTDIR/proc_maps_${TS}.txt"
cat /proc/$PID/smaps_rollup 2>/dev/null > "$OUTDIR/proc_smapsr_${TS}.txt" || true

# cgroup v2
CID=$(docker ps -qf "name=php2shell-lab-php-1")
if [ -n "$CID" ]; then
  CG="/sys/fs/cgroup/system.slice/docker-${CID}.scope" 2>/dev/null || \
  CG="/sys/fs/cgroup/docker/$CID" 2>/dev/null || \
  CG=$(find /sys/fs/cgroup -name "*${CID}*" 2>/dev/null | head -1)
  [ -n "${CG:-}" ] && {
    for f in memory.current memory.max memory.peak memory.events; do
      [ -r "$CG/$f" ] && cp "$CG/$f" "$OUTDIR/cg_${f}_${TS}.txt" 2>/dev/null
    done
  }
fi

echo "[i] Snapshot en $OUTDIR/*_${TS}.txt"
