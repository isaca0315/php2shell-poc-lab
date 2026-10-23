# Actividad OS — PHP2Shell desde dentro

Actividad corta para observar un **OOM de PHP** desde tres capas: memoria,
procesos y sistemas de archivos. El disparador es benigno y no incluye RCE ni
heap grooming.

Todo se hace con **comandos de Linux**.

## 1. Qué vas a observar

| Capa | Pregunta | Evidencia |
|---|---|---|
| Memoria | ¿Por qué PHP se queda sin 4 MiB si el cgroup tiene 256 MiB? | `memory.current`, `memory.peak`, `memory.max`, `memory.events`, `VmRSS` |
| Procesos | ¿Quién muere y quién lo reemplaza? | `exit_group(70)`, `child ... exited`, `child ... started` |
| Archivos | ¿Qué queda escrito después de la caída? | `/tmp` como `tmpfs`, `sess_*`, inodo, modo, rootfs `ro` |

En corto: `memory_limit` es un contador de PHP (Zend MM), no la RAM del
contenedor. Al superarlo, PHP aborta la petición; el hijo de FPM sale con
código 70 y el maestro lo reemplaza. El kernel no participa: `memory.events`
sigue en `oom 0`. nginx ve el corte y devuelve **502**, y la sesión ya escrita
queda en `/tmp`.

## 2. Levantar el laboratorio

Desde la raíz del repositorio. Si ya había contenedores, empieza limpio:

```bash
docker compose down -v
LAB_PORT=18080 docker compose up -d php nginx
docker compose ps
curl -sS http://127.0.0.1:18080/; echo
```

Debe responder `ok pid=...`. Si no responde, revisa:

```bash
docker compose logs --since=2m php
docker compose logs --since=2m nginx
```

## 3. Línea base (captura 1, parte antes)

Averigua el cgroup del contenedor PHP y el PID del worker en el host:

```bash
CID=$(docker inspect -f '{{.Id}}' php2shell-lab-php-1)
CG=$(find /sys/fs/cgroup -type d -name "docker-$CID.scope" | head -n 1)
WORKER=$(docker top php2shell-lab-php-1 -eo pid,ppid,user,args | awk '/php-fpm: pool / {print $1; exit}')
printf 'CG=%s\nWORKER=%s\n' "$CG" "$WORKER"
```

Lee la memoria del cgroup y del worker:

```bash
cat "$CG/memory.current"
cat "$CG/memory.peak"
cat "$CG/memory.max"
cat "$CG/memory.events"
grep -E 'VmPeak|VmRSS|RssAnon|Threads' "/proc/$WORKER/status"
docker exec php2shell-lab-php-1 php -r 'echo "memory_limit=", ini_get("memory_limit"), PHP_EOL;'
```

Guarda una captura de esta salida. Fíjate en que `memory.max` es 256 MiB,
`memory_limit` es 4M y `memory.events` todavía tiene `oom 0` y `oom_kill 0`.

## 4. Crear una sesión (captura 4, parte inicial)

En la misma terminal, genera un identificador y haz una subida pequeña. Eso
crea el archivo de sesión sin provocar el OOM:

```bash
SID=$(openssl rand -hex 16)
printf 'x' > /tmp/upload-small.txt
curl -sS -o /tmp/sesion.html -w 'HTTP %{http_code}\n' \
  -H "Cookie: PHPSESSID=$SID" \
  -F "PHPSESSID=$SID" \
  -F "PHP_SESSION_UPLOAD_PROGRESS=k" \
  -F "u0=@/tmp/upload-small.txt;filename=f0.txt;type=text/plain" \
  http://127.0.0.1:18080/
docker exec php2shell-lab-php-1 \
  stat -c 'inodo=%i modo=%a dueño=%U:%G tamaño=%s %n' "/tmp/sess_$SID"
```

Debe responder `HTTP 200` y mostrar un archivo `sess_...` con modo `600` y
dueño `www-data:www-data`. Ese archivo lo escribe el handler de
`session.upload_progress` durante el parseo del cuerpo, antes de ejecutar
`index.php`: no hace falta `session_start()` en la aplicación.

## 5. Trazar el worker (captura 2)

Necesitas `strace` en el host. Si no está instalado:

```bash
command -v strace || sudo apt install -y strace
```

Abre una **segunda terminal** en la raíz del repositorio. Vuelve a calcular el
PID del worker y deja `strace` adjunto a él:

```bash
WORKER=$(docker top php2shell-lab-php-1 -eo pid,ppid,user,args | awk '/php-fpm: pool / {print $1; exit}')
sudo strace -f -tt -T -yy -s 256 \
  -e trace=mmap,munmap,brk,mprotect,read,write,openat,close,exit_group \
  -p "$WORKER" -o /tmp/php2shell-oom.strace
```

Si aparece `Operation not permitted`, ejecuta una vez:

```bash
sudo sysctl -w kernel.yama.ptrace_scope=0
```

Vuelve a la **primera terminal** (la de `SID`) y dispara el OOM con un campo de
progreso de 1 MiB:

```bash
head -c 1048576 /dev/zero | tr '\0' 'A' > /tmp/phpsess-progress.txt
curl -sS -o /tmp/oom.html -w 'HTTP %{http_code}\n' \
  -H "Cookie: PHPSESSID=$SID" \
  -F "PHPSESSID=$SID" \
  -F "PHP_SESSION_UPLOAD_PROGRESS=k" \
  -F "PHP_SESSION_UPLOAD_PROGRESS=</tmp/phpsess-progress.txt" \
  -F "u0=@/tmp/upload-small.txt;filename=f0.txt;type=text/plain" \
  http://127.0.0.1:18080/
```

Debe responder `HTTP 502`. En la segunda terminal, corta `strace` con
`Ctrl+C` y revisa la traza:

```bash
grep -nE 'mmap|exit_group' /tmp/php2shell-oom.strace | tail -n 30
```

Busca el `mmap` de la asignación y el `exit_group(70)` del worker. El mensaje
`Allowed memory size ... exhausted` aparece en los logs, no en la traza.

## 6. Después del OOM (captura 3)

En la primera terminal, revisa memoria, procesos y logs:

```bash
cat "$CG/memory.current"
cat "$CG/memory.peak"
cat "$CG/memory.events"
docker top php2shell-lab-php-1 -eo pid,ppid,user,args
docker compose logs --since=3m php | tail -n 30
docker compose logs --since=3m nginx | tail -n 30
```

Debes ver:

- `memory.events` con `oom 0` y `oom_kill 0`.
- `Allowed memory size of 4194304 bytes exhausted`.
- `child ... exited with code 70` y `child ... started`.
- Un worker con PID nuevo.
- En nginx, `502` y `unexpected FastCGI record`.

## 7. Archivos y sesión (captura 4)

Comprueba los montajes y el archivo de sesión:

```bash
docker exec php2shell-lab-php-1 findmnt -T /
docker exec php2shell-lab-php-1 findmnt -T /tmp
docker exec php2shell-lab-php-1 \
  stat -c 'inodo=%i modo=%a dueño=%U:%G tamaño=%s %n' "/tmp/sess_$SID"
docker exec php2shell-lab-php-1 sh -c 'touch /var/www/html/prueba'
```

El primer `findmnt` muestra el rootfs `ro`, el segundo muestra `/tmp` como
`tmpfs` con escritura, y el `touch` falla con `Read-only file system`. La
sesión sigue en `/tmp` aunque el worker haya muerto.

## 8. Entregable

Entrega un **PDF** con el proceso y las capturas.

Estructura:

1. Portada con tu nombre, fecha y objetivo.
2. **Identificadores**: `CID`, ruta del cgroup (`CG`), PID del worker antes/después y `PHPSESSID` usado.
3. **Memoria**: `memory.current`, `memory.peak`, `memory.max`, `memory.events` y `VmRSS` (antes/después).
4. **Traza**: fragmento de `strace` con `mmap` y `exit_group(70)` (con timestamps).
5. **Procesos/HTTP**: `docker top` con cambio de PID, `HTTP 502` y logs con `exited with code 70` / `started`.
6. **Archivos**: `findmnt` (`/` ro, `/tmp` tmpfs), `stat` de `sess_*` (inodo, modo, dueño, tamaño) y fallo de `touch /var/www/html/prueba`.
7. Conclusiones breves con los valores obtenidos.

**Requisito:** deben aparecer los **valores exactos** de *esta* ejecución. El `sess_*` debe corresponder al `PHPSESSID`, el PID trazado debe ser el que muere y los logs deben coincidir con esa misma corrida. No entregues scripts ni archivos sueltos, solo el PDF.

## 9. Limpiar

```bash
docker compose down -v
rm -f /tmp/phpsess-progress.txt /tmp/upload-small.txt /tmp/php2shell-oom.strace
```

## 10. Preguntas para cerrar

1. ¿Por qué `memory.current` puede ser mayor que `memory_limit`?
2. ¿Qué diferencia hay entre `exit_group(70)` y un `SIGKILL`?
3. ¿Por qué nginx responde 502 y no 500?
4. ¿Qué demuestra que el OOM fue de PHP y no del kernel?
5. ¿Por qué la sesión sobrevive a la muerte del worker?
