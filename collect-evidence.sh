#!/usr/bin/env bash
# Recolector de evidencias del laboratorio (no modifica nada).
set -u
cd "$(dirname "$0")"

echo "== 1) Versión de PHP (¿afectada?) =="
docker compose exec -T php php -v || true
docker compose exec -T php php -i 2>/dev/null | grep -E '^(memory_limit|post_max_size|session\.upload_progress)' || true

echo
echo "== 2) Logs PHP-FPM / PHP (Fatal error, SIGSEGV, respawn) =="
docker compose logs --since=10m php 2>&1 | tail -n 80

echo
echo "== 3) Logs nginx (502 / upstream cerrado) =="
docker compose logs --since=10m nginx 2>&1 | tail -n 40

echo
echo "== 4) Archivos de sesión dejados por el handler =="
docker compose exec -T php sh -c 'ls -l /tmp/sess_* 2>/dev/null | tail; for f in /tmp/sess_*; do [ -f "$f" ] && echo "--- $f" && head -c 400 "$f" && echo; done' || true

echo
echo "== 5) OOM del KERNEL (solo si se agotó RAM del host; no es el caso normal) =="
echo "-- dmesg --"
dmesg 2>/dev/null | grep -iE 'out of memory|killed process|oom-kill' | tail -n 20 || true
echo "-- journalctl -k --"
journalctl -k --since '-10min' 2>/dev/null | grep -iE 'out of memory|killed process|oom-kill' | tail -n 20 || true

echo
echo "== 6) Core dumps del worker (si están habilitados) =="
coredumpctl list 2>/dev/null | tail -n 10 || true
