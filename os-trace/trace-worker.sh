#!/usr/bin/env bash
# Trazado del worker PHP-FPM con strace (syscalls relevantes a SO)
# Uso: ./os-trace/trace-worker.sh & luego disparar trigger.py
set -u
cd "$(dirname "$0")/.."

OUTDIR="os-trace"
mkdir -p "$OUTDIR"
TS=$(date +%Y%m%d_%H%M%S)

PID=$(docker top php2shell-lab-php-1 2>&1 | awk '/php-fpm: pool www/{print $1; exit}')
if [ -z "${PID:-}" ] || ! kill -0 "$PID" 2>/dev/null; then
  echo "[!] No encuentro worker www-data. ¿Está levantado php2shell-lab-php-1?" >&2
  docker ps --filter name=php2shell-lab-php-1
  exit 1
fi

echo "[i] Trazando worker PID=$PID -> $OUTDIR/strace_${TS}.log"
echo "[i] Dispara en otra terminal: python3 trigger.py --url http://127.0.0.1:8080/ --mode progress"
timeout 90 strace -tt -T -yy -s 256 \
  -e trace=mmap,munmap,mprotect,brk,openat,open,read,write,close,accept4,accept,recvfrom,sendto,clone,clone3,_exit,exit_group \
  -p "$PID" 2>&1 | tee "$OUTDIR/strace_${TS}.log"
echo "[i] Guardado en $OUTDIR/strace_${TS}.log"
