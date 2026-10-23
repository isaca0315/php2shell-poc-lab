# Actividad OS — memoria, procesos y sistemas de archivos

> **Laboratorio local, `127.0.0.1`, sin RCE.** Esta actividad usa el acto 1
> del lab (CVE-2026-109618/619): el fallo de `session.upload_progress` que
> provoca un OOM dentro del handler y la caída del worker PHP-FPM.
>
> No se ejecuta ni se adapta el exploit de corrupción de memoria. El objetivo
> es **observar y explicar** qué hacen el kernel, el cgroup, PHP-FPM y el
> sistema de archivos durante el fallo.

---

## 0. Objetivos de aprendizaje

Al terminar la actividad deberías poder:

1. Distinguir **memoria de usuario** (Zend MM / `memory_limit`) de
   **memoria del kernel/cgroup** (`memory.current`, `memory.peak`, OOM killer).
2. Leer e interpretar `/proc/<pid>/status`, `/proc/<pid>/stat`, `/proc/<pid>/limits`
   y los contadores de **cgroup v2**.
3. Explicar el ciclo de vida de PHP-FPM: máster, worker, `exit code 70`,
   respawn y el `502` de nginx.
4. Analizar un **tmpfs**, inodos, permisos, rootfs de solo lectura y la
   diferencia entre un fichero de sesión y un fichero persistente.
5. Correlacionar en una línea temporal los tres subsistemas: memoria,
   procesos y archivos.

---

## 1. Alcance y seguridad

| Dentro de alcance | Fuera de alcance |
|---|---|
| `http://127.0.0.1:8080/` (o el puerto que uses) | Cualquier host que no sea loopback |
| Trigger benigno `trigger.py` (1 MiB) | Exploit de RCE / heap grooming |
| `strace`, `/proc`, cgroup v2, `pidstat` | Ataques de fuerza bruta o DoS externo |
| Target de entrenamiento solo para comparar montajes | Cadena de subida → webshell |

Reglas:

- Usa solo el stack del repo.
- No aumentes `--size` ni `--repeat` más allá de lo indicado.
- Si el host pierde capacidad de respuesta, `Ctrl-C` y `docker compose down -v`.
- Los ficheros de sesión son datos de laboratorio; no uses datos reales.

---

## 2. Puesta en marcha

```bash
cd php2shell-poc-lab

# Stack del acto 1 (PHP-FPM + nginx)
docker compose up -d php nginx

# Si el 8080 está ocupado:
LAB_PORT=18080 docker compose up -d php nginx
export LAB_URL=http://127.0.0.1:18080/
```

Comprobación:

```bash
curl -sS "${LAB_URL:-http://127.0.0.1:8080/}"
# ok pid=... peak=... limit=4M

docker compose ps
docker top php2shell-lab-php-1 -eo pid,ppid,user,args
```

Salida esperada de `docker top`:

```text
PID      PPID     USER       COMMAND
<master> <ppid>   root       php-fpm: master process (/usr/local/etc/php-fpm.conf)
<worker> <master> www-data   php-fpm: pool www
```

> **Ojo con los PIDs:** hay dos espacios de nombres. El PID que ves con
> `docker top` es el del **host**; el que ves dentro con `docker exec ... ps`
> (o recorriendo `/proc`) es el del **contenedor**. Los scripts de esta
> actividad muestran ambos.

---

## 3. Entregables

1. `worksheet.md` completado (tablas y preguntas).
2. Directorio de evidencias generado por los scripts:
   `lab/os-activity/out/<timestamp>-activity/`.
3. Un informe breve (1 página) con:
   - línea temporal del fallo;
   - tres conclusiones de memoria, tres de procesos y tres de filesystem;
   - qué métrica demuestra que **no** hubo OOM del kernel.
4. Comandos reproducibles (copia exacta de los que usaste).

---

## 4. Tarea 1 — Gestión de memoria

### 4.1 Línea base

Captura el estado antes de disparar nada:

```bash
./lab/os-activity/collect-snapshot.sh baseline
```

El script crea `lab/os-activity/out/<ts>-baseline/` con:

```text
meta.txt                 # contenedor, imagen, cgroup, límites
docker-top.txt           # máster y worker
worker-<pid>-proc.txt    # /proc del worker (status, stat, limits, ...)
cgroup-memory.current.txt
cgroup-memory.peak.txt
cgroup-memory.max.txt
cgroup-memory.events.txt
cgroup-pids.current.txt
cgroup-pids.max.txt
pidstat-<pid>.txt
container-fs.txt         # /tmp, rootfs, sesiones
php.log / nginx.log
kernel-oom.txt
summary.txt
```

Lee el resumen:

```bash
cat lab/os-activity/out/latest/summary.txt
```

Y extrae los campos clave del worker:

```bash
PID=$(docker top php2shell-lab-php-1 -eo pid,ppid,user,args \
  | awk 'NR>1 && /php-fpm: pool / {print $1; exit}')
echo "worker host PID=$PID"
grep -E 'VmPeak|VmSize|VmRSS|RssAnon|RssFile|Threads' /proc/$PID/status
```

### 4.2 Disparar el OOM y observar

Opción A — todo automático (recomendada):

```bash
./lab/os-activity/run-activity.sh --url "${LAB_URL:-http://127.0.0.1:8080/}"
```

Hace baseline → validación de sesión → traza + OOM → snapshot final.
La traza se genera con un contenedor auxiliar que comparte el PID namespace
del contenedor PHP y tiene `CAP_SYS_PTRACE`; no necesitas instalar `strace`
en la VM.

Opción B — manual, en dos terminales:

```bash
# Terminal 1: traza durante 10 s
./lab/os-activity/trace-worker.sh 10

# Terminal 2: dispara el OOM
python3 trigger.py --url "${LAB_URL:-http://127.0.0.1:8080/}" \
  --mode progress --size 1048576
```

La traza manual queda en `lab/os-activity/out/<ts>-trace/`; si usas `run-activity.sh`, en `lab/os-activity/out/latest/trace/`. Busca:

```bash
# Traza manual más reciente (o latest/trace si usaste run-activity.sh)
TRACE_DIR=$(ls -dt lab/os-activity/out/*-trace 2>/dev/null | head -1)
grep -E 'mmap\(NULL, 2097152|Fatal error|exit_group|/tmp/sess_' \
  "${TRACE_DIR:-lab/os-activity/out/latest/trace}"/strace-*.log | tail -n 20
```

Ejemplo real observado:

```text
mmap(NULL, 2097152, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0) = 0x...
write(2<pipe:...>, "NOTICE: PHP message: PHP Fatal error:  Allowed memory size of 4194304 bytes exhausted ...", 164) = 164
exit_group(70) = ?
```

### 4.3 Qué mirar y cómo interpretarlo

| Métrica | Dónde | Qué representa |
|---|---|---|
| `memory_limit` | `php -i` | Contador de **Zend MM**, no memoria real del proceso |
| `VmSize` | `/proc/<pid>/status` | Espacio virtual reservado (puede ser mucho mayor que el límite PHP) |
| `VmRSS` | `/proc/<pid>/status` | Páginas físicas residentes |
| `RssAnon` / `RssFile` | `/proc/<pid>/status` | RSS anónimo / mapeado de ficheros |
| `minflt` / `majflt` | `/proc/<pid>/stat`, `pidstat -r` | Page faults menores / mayores |
| `memory.current` | cgroup v2 | Memoria cargada al cgroup ahora |
| `memory.peak` | cgroup v2 | Pico histórico del cgroup (monótono) |
| `memory.max` | cgroup v2 | Límite del cgroup (`mem_limit` de Compose) |
| `memory.events` | cgroup v2 | `oom`, `oom_kill`, `high`, `max` |

Preguntas:

1. Si `memory_limit=4M`, ¿por qué `VmSize` puede superar los 190 MB?
2. ¿Qué cuenta exactamente `memory_limit` y qué **no** cuenta?
3. ¿Por qué el proceso muere con un fatal de PHP y no con un `SIGKILL` del
   OOM killer?
4. ¿Qué evidencia demuestra que el cgroup **no** llegó a su límite?
5. En la traza, identifica el `mmap` de 2 MiB. ¿Qué componente lo pide?
6. ¿Qué diferencia hay entre `memory.current` y `memory.peak`? ¿Por qué el
   pico sigue visible después de que muera el worker?
7. ¿Qué pasaría si `memory_limit=-1` y el cgroup tuviera un límite bajo?
   ¿Quién mataría al proceso y con qué señal?
8. ¿Por qué `RssAnon` y `RssFile` no suman exactamente `VmRSS`?

### 4.4 PHP OOM vs. OOM del kernel

Comprueba las dos capas:

```bash
# Capa PHP: fatal en el log del contenedor
docker compose logs --since=5m php | grep -E 'Fatal error|exhausted|exited with code'

# Capa kernel: cgroup
CG=$(find /sys/fs/cgroup -maxdepth 6 -type d -name "*$(docker inspect -f '{{.Id}}' php2shell-lab-php-1)*" | head -1)
cat "$CG/memory.current" "$CG/memory.peak" "$CG/memory.max"
cat "$CG/memory.events"

# Capa kernel: dmesg/journal (puede requerir permisos)
dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail
journalctl -k --since '-10min' 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process' | tail
```

En este lab lo esperado es:

- fatal de PHP con `4 MiB` y `tried to allocate ~1 MiB`;
- `memory.peak` muy por debajo de `memory.max` (por ejemplo, ~18 MB frente a
  256 MB);
- `memory.events` con `oom 0` y `oom_kill 0`;
- **sin** líneas de OOM killer en `dmesg` (o sin permisos para leerlas).

> `memory.peak` es **histórico** desde que se creó el cgroup: si ya hiciste
> otras pruebas, el pico puede venir de antes. Para medir solo esta ejecución,
> recrea el contenedor PHP antes de la actividad:
>
> ```bash
> ./lab/os-activity/run-activity.sh --fresh
> # o: docker compose up -d --force-recreate php
> ```
>
> El `memory.current` del timeline sí es instantáneo y muestra la subida
> durante el trigger. `docker compose restart php` **no** sirve para resetear
> el pico: reinicia el proceso dentro del mismo cgroup.

---

## 5. Tarea 2 — Procesos

### 5.1 Árbol de procesos

```bash
docker top php2shell-lab-php-1 -eo pid,ppid,user,args
ps -eo pid,ppid,user,stat,args --forest | grep -E 'php-fpm|nginx' | grep -v grep
```

Dentro del contenedor:

```bash
docker exec php2shell-lab-php-1 sh -c '
  for d in /proc/[0-9]*; do
    c=$(tr "\0" " " < "$d/cmdline" 2>/dev/null) || continue
    case "$c" in *"php-fpm: "*) echo "${d#/proc/} $c" ;; esac
  done
'
```

Observa:

- el **máster** corre como `root` y es el PID 1 del contenedor;
- el **worker** corre como `www-data` y su `PPid` es el máster;
- `pm=static` y `pm.max_children=1` en `php/www.conf`: un solo worker.

### 5.2 Ciclo de vida durante el OOM

Antes del trigger:

```bash
docker top php2shell-lab-php-1 -eo pid,ppid,user,args | tee /tmp/antes.txt
```

Dispara el OOM (si no lo hiciste ya):

```bash
python3 trigger.py --url "${LAB_URL:-http://127.0.0.1:8080/}" --mode progress
```

Después:

```bash
docker top php2shell-lab-php-1 -eo pid,ppid,user,args | tee /tmp/despues.txt
docker compose logs --since=5m php | tail -n 30
docker compose logs --since=5m nginx | tail -n 20
```

Salida esperada (PIDs de ejemplo):

```text
WARNING: [pool www] child 7 exited with code 70 after ...
NOTICE: [pool www] child 115 started
```

```text
[error] ... upstream sent unexpected FastCGI record: 3 ...
"POST / HTTP/1.1" 502 ...
```

Preguntas:

1. ¿Qué proceso muere: el máster o el worker? ¿Por qué?
2. ¿Qué significa `exit code 70`? ¿Es una señal? ¿Qué syscall lo produce?
3. ¿Qué diferencia habría si el proceso hubiera recibido `SIGKILL` (9)?
4. ¿Por qué nginx devuelve `502` y no un `500` generado por PHP?
5. ¿Qué pasa con la petición HTTP que estaba en curso? ¿Dónde estaba su
   estado (memoria del worker, socket FastCGI, sesión en disco)?
6. ¿Por qué el máster puede crear un worker nuevo? ¿Qué configuración de FPM
   lo permite?
7. Consulta `pids.current` y `pids.max` del cgroup. ¿Qué pasaría con un
   `pm.max_children` alto o un fork bomb?
8. Si comparas con `mod_php` (`./lab/run-modphp.sh`), ¿quién atiende la
   petición y quién la reemplaza? ¿Sigue existiendo el `502` de FastCGI?

### 5.3 Evidencia de proceso

```bash
PID=$(docker top php2shell-lab-php-1 -eo pid,ppid,user,args \
  | awk 'NR>1 && /php-fpm: pool / {print $1; exit}')
cat /proc/$PID/status | grep -E 'Name|State|Pid|PPid|Uid|Gid|Threads|voluntary'
cat /proc/$PID/limits
cat /proc/$PID/cgroup
```

Guarda el `PPid`, el UID efectivo (`33` = `www-data`), el estado (`S` =
sleeping) y el número de hilos (1). Relaciónalos con el modelo FPM.

---

## 6. Tarea 3 — Sistemas de archivos

### 6.1 Montajes y tmpfs

Dentro del contenedor PHP:

```bash
docker exec php2shell-lab-php-1 sh -c '
  findmnt -T /tmp
  findmnt -T /var/www/html
  df -hT /tmp /var/www/html
  stat -f -c "type=%T block=%s blocks=%b free=%f files=%c ffree=%d" /tmp
'
```

Valores observados en este lab:

| Ruta | Tipo | Opciones | Tamaño |
|---|---|---|---|
| `/tmp` | `tmpfs` | `rw,nosuid,nodev,noexec,relatime,size=65536k` | 64 MiB |
| `/var/www/html` | `ext4` (bind mount) | `ro,relatime` | rootfs de solo lectura |

El rootfs es de solo lectura (`read_only: true` en Compose). Comprueba que el
worker **no** puede escribir en el webroot:

```bash
docker exec php2shell-lab-php-1 sh -c \
  'touch /var/www/html/.prueba 2>&1 || true'
# touch: cannot touch '/var/www/html/.prueba': Read-only file system
```

pero sí puede escribir en `/tmp`:

```bash
docker exec php2shell-lab-php-1 sh -c \
  'touch /tmp/.prueba && ls -l /tmp/.prueba && rm /tmp/.prueba'
```

### 6.2 Ficheros de sesión

Crea una sesión con la validación benigna:

```bash
python3 lab/rt.py validate \
  --url "${LAB_URL:-http://127.0.0.1:8080/}" \
  --docker-inspect --compose-file docker-compose.yml
```

Inspecciona:

```bash
docker exec php2shell-lab-php-1 sh -c '
  for f in /tmp/sess_*; do
    [ -e "$f" ] || continue
    stat -c "inodo=%i modo=%a dueño=%U:%G tamaño=%s %n" "$f"
  done
'
```

Ejemplo observado:

```text
inodo=2 modo=600 dueño=www-data:www-data tamaño=362 /tmp/sess_...
```

Preguntas:

1. ¿Por qué el fichero está en `tmpfs` y no en el rootfs?
2. ¿Qué significa el modo `600` y por qué el propietario es `www-data`?
3. ¿Qué es el inodo? ¿Por qué puede ser un número tan bajo en `tmpfs`?
4. ¿Qué ocurre con ese fichero si haces `docker compose down -v`?
5. ¿Qué diferencia hay entre borrar el fichero y truncarlo? ¿Y entre el
   inodo y el nombre?
6. ¿Por qué `noexec` en `/tmp` es relevante para un atacante que consigue
   escribir un fichero? (Pista: no es lo mismo *escribir* que *ejecutar*.)
7. Si el target de entrenamiento está levantado, compara `/tmp` con
   `/var/www/html/uploads`: ¿qué cambia (tamaño, contenido, rootfs) y qué no
   (`noexec`)? ¿Por qué el webshell PHP funciona allí aunque el montaje tenga `noexec`? (Pista:
   Apache/mod_php lee e interpreta el fichero; no hace `execve` de él.)
8. Haz la prueba de reutilización de inodo:

   ```bash
   docker exec php2shell-lab-php-1 sh -c '
     f=/tmp/os-inode-demo
     touch "$f"; stat -c "primero=%i" "$f"
     rm "$f"
     touch "$f"; stat -c "segundo=%i" "$f"
     rm "$f"
   '
   ```

   ¿Se reutiliza el inodo? ¿Qué implicaciones tiene para la caché y para
   detectar ficheros borrados que siguen abiertos?

### 6.3 Capa de bloques, páginas y persistencia

- `tmpfs` vive en memoria: no hay dispositivo de bloque ni journal.
- `stat -f` muestra bloques e inodos disponibles; `df -i` muestra inodos.
- Un fichero borrado pero abierto sigue consumiendo espacio (page cache /
  descriptor); se puede ver con `lsof +L1` si tienes permisos.
- El rootfs `ro` protege el código de la aplicación, pero **no** impide que
  el worker escriba en `tmpfs`; por eso el fallo de sesión es posible.

Preguntas:

1. ¿Dónde está la página de un fichero de `tmpfs`? ¿Pasa por page cache?
2. ¿Por qué `docker compose down -v` elimina la sesión y no deja rastro en el
   host?
3. ¿Qué diferencia hay entre `read_only: true` y `tmpfs`?
4. ¿Qué riesgo tendría un directorio `uploads` escribible y con `exec`?

---

## 7. Tarea 4 — Correlación

Completa la línea temporal con evidencia real:

| t | Evento | Subsistema | Evidencia |
|---|---|---|---|
| t0 | POST multipart con `session.upload_progress` | red / proceso | log nginx, `strace read(...)` |
| t1 | Zend MM pide un chunk de 2 MiB | memoria de usuario | `mmap(NULL, 2097152, ...)` |
| t2 | Fatal por `memory_limit` | memoria de usuario | `Fatal error ... 4194304 bytes exhausted` |
| t3 | Worker termina | proceso | `exit_group(70)` |
| t4 | FPM registra la salida y crea otro worker | proceso | `child ... exited with code 70` / `child ... started` |
| t5 | nginx ve el corte FastCGI | red / proceso | `unexpected FastCGI record` / `502` |
| t6 | Fichero `sess_*` en `/tmp` | filesystem | inodo, modo 600, `www-data` |

Pregunta final (5–8 líneas): explica cómo un límite **de usuario** (4 MiB)
termina produciendo un **502** y un **worker nuevo**, sin que el kernel haya
matado nada.

---

## 8. Scripts y artefactos

| Script | Para qué |
|---|---|
| `collect-snapshot.sh` | Snapshot de `/proc`, cgroup, FS, logs y sesiones |
| `trace-worker.sh` | `strace` del worker usando un contenedor auxiliar con `SYS_PTRACE` |
| `run-activity.sh` | Flujo completo: baseline → sesión → traza + OOM → after → resumen |

```bash
./lab/os-activity/run-activity.sh --start
./lab/os-activity/run-activity.sh --url http://127.0.0.1:18080/ --duration 10
./lab/os-activity/run-activity.sh --fresh            # recrea php; peak limpio
./lab/os-activity/run-activity.sh --no-trace         # sin helper de strace
```

Árbol de salida:

```text
lab/os-activity/out/
├── latest -> 2026...-activity/
└── 2026...-activity/
    ├── baseline/
    ├── after/
    ├── trace/
    │   ├── strace-*.log
    │   ├── trace-meta.txt
    │   └── summary.txt
    ├── memory-timeline.tsv
    ├── validate.log
    ├── trigger.log
    ├── trace-console.log
    └── summary.md
```

> `lab/os-activity/out/` está ignorado por git: contiene evidencia local.
> Los scripts no escriben fuera del repo y no tocan el tráfico de red más
> allá de `127.0.0.1`.

### Si `strace`/el helper falla

- Comprueba que Docker permite `--pid=container:...` y `--cap-add=SYS_PTRACE`.
- Usa `--no-trace`: el resto de la actividad (memoria, procesos, FS) se puede
  completar con `/proc`, cgroup, `pidstat` y logs.
- En un host con `strace` instalado y permisos de ptrace, también puedes
  trazar el PID del host directamente:

  ```bash
  PID=$(docker top php2shell-lab-php-1 -eo pid,ppid,user,args \
    | awk 'NR>1 && /php-fpm: pool / {print $1; exit}')
  strace -f -tt -T -yy -s 256 -p "$PID"
  ```

---

## 9. Evaluación

| Criterio | Peso | Qué se valora |
|---|---:|---|
| Evidencia | 40 % | Snapshots, traza, logs y comandos reproducibles |
| Análisis | 30 % | Interpretación correcta de memoria, procesos y FS |
| Correlación | 20 % | Línea temporal coherente entre los tres subsistemas |
| Comunicación | 10 % | Informe claro, sin afirmaciones sin evidencia |

Mínimo para aprobar: identificar correctamente que el fallo es **PHP OOM**
(no kernel OOM), explicar el `exit code 70` y localizar la sesión en `tmpfs`.

---

## 10. Limpieza

```bash
docker compose down -v
rm -rf lab/os-activity/out
```

El `tmpfs` desaparece con el contenedor; no queda sesión en el host. Si
levantaste el target de entrenamiento, bájalo también:

```bash
docker compose -f docker-compose.modphp.yml down -v   # solo si lo usaste
```

---

## 11. Referencias

- `proc(5)`: `/proc/<pid>/status`, `stat`, `limits`, `cgroup`.
- `cgroups(7)` y documentación de cgroup v2 (`memory.current`, `memory.peak`,
  `memory.events`, `pids.current`).
- `mmap(2)`, `brk(2)`, `madvise(2)`: gestión de memoria virtual.
- `tmpfs(5)`: ficheros en memoria, tamaño e inodos.
- `strace(1)`: traza de syscalls.
- PHP-FPM: `pm`, `pm.max_children`, `catch_workers_output`, exit codes.
- PHP: `session.upload_progress`, `memory_limit`, `memory_get_peak_usage`.
- Docker: `--memory`, `--pids-limit`, `read_only`, `tmpfs`, `cap_add`.
