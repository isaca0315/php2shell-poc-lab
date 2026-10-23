# PHP2Shell desde dentro

## Actividad de sistemas operativos: memoria, procesos y archivos

> No venimos a repetir que “el worker se cayó”. Venimos a abrir la caja
> negra: quién pidió memoria, quién se quedó sin aire, quién se enteró y qué
> quedó escrito en el disco.
>
> La regla de este cuaderno es simple: **si no está en la evidencia, es una
> opinión**. Cada afirmación que escribas debería poder señalarse con un
> comando, una línea de log o un fichero de `/proc`.

Este material nace de una idea sencilla: el fallo de
`session.upload_progress` se entiende mucho mejor cuando lo miras desde tres
capas a la vez. PHP dice que se quedó sin memoria; el cgroup dice que el
kernel ni se enteró; el sistema de archivos guarda un `sess_*` que sobrevive
al proceso. Las tres cosas son ciertas y, sin embargo, parecen contradecirse.

Aquí no hay exploit de RCE ni heap grooming. Esta es una actividad de
observación: usamos el trigger benigno del acto 1 y aprendemos a leer lo que
el sistema operativo deja detrás.

---

## 0. Antes de tocar nada

### 0.1 Alcance

| Dentro | Fuera |
|---|---|
| `http://127.0.0.1:8080/` o el puerto local que uses | Cualquier host que no sea loopback |
| Trigger benigno de 1 MiB (`trigger.py`) | Explotación de corrupción de memoria |
| `/proc`, cgroup v2, `strace`, `pidstat`, montajes | Fuerza bruta, DoS externo, persistencia |
| Target de entrenamiento solo para comparar montajes | Cadena de subida → webshell |

Si el host se pone lento: `Ctrl-C`, respira, y `docker compose down -v`.
Este lab está pensado para ejecutarse en local y para poder romperse sin
consecuencias.

### 0.2 Arranque

```bash
cd php2shell-poc-lab

# Stack del acto 1
docker compose up -d php nginx

# Si el 8080 está ocupado (BloodHound, Mythic, etc.)
LAB_PORT=18080 docker compose up -d php nginx
export LAB_URL=http://127.0.0.1:18080/
```

Comprueba que responde antes de seguir:

```bash
curl -sS "${LAB_URL:-http://127.0.0.1:8080/}"
# ok pid=... peak=... limit=4M

docker compose ps
docker top php2shell-lab-php-1 -eo pid,ppid,user,args
```

Lo que deberías ver:

```text
PID      PPID     USER       COMMAND
<master> <ppid>   root       php-fpm: master process (/usr/local/etc/php-fpm.conf)
<worker> <master> www-data   php-fpm: pool www
```

> **Dos espacios de nombres.** El PID de `docker top` es el del host; el que
> ves dentro con `docker exec` es el del contenedor. No son el mismo número.
> Si mezclas uno y otro, acabarás leyendo el `/proc` equivocado.

### 0.3 La forma más rápida de empezar

```bash
./lab/os-activity/run-activity.sh --start --fresh \
  --url "${LAB_URL:-http://127.0.0.1:8080/}"
```

Esto hace baseline → validación de sesión → traza + OOM → snapshot final.
`--fresh` recrea PHP para que `memory.peak` no arrastre picos de pruebas
anteriores. Si no quieres usar `strace`, añade `--no-trace`.

---

## 1. El mapa: tres capas, una caída

Antes de ejecutar nada, coloca el mapa mental. El mismo instante se ve
distinto según dónde mires:

| Capa | Protagonista | Pregunta de oro | Evidencia |
|---|---|---|---|
| Usuario | Zend MM / `memory_limit` | ¿Quién pidió memoria y quién dijo “no”? | fatal de PHP, `mmap`, `VmRSS` |
| Proceso | PHP-FPM | ¿Quién muere, quién lo sustituye? | `exit code 70`, respawn, `502` |
| Kernel / FS | cgroup v2 + `tmpfs` | ¿Se enteró el kernel? ¿Qué queda en disco? | `memory.events`, inodo, montajes |

La historia completa no está en una sola capa. La gracia es cruzar las tres.

---

## 2. Primera parada: el aire

### 2.1 Qué quiero que veas

No que PHP “use 4 MiB”, sino que **el límite de PHP y la memoria real del
proceso son dos cosas distintas**. `memory_limit` es un contador del Zend
Memory Manager; `VmRSS` es lo que el proceso tiene residente; el cgroup es lo
que el kernel contabiliza para el contenedor.

### 2.2 Baseline, sin disparar nada

```bash
./lab/os-activity/collect-snapshot.sh baseline
SNAP=$(ls -dt lab/os-activity/out/*-baseline | head -1)
cat "$SNAP/summary.txt"
```

El snapshot deja, entre otros:

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

Y los campos que más nos importan del worker:

```bash
PID=$(docker top php2shell-lab-php-1 -eo pid,ppid,user,args \
  | awk 'NR>1 && /php-fpm: pool / {print $1; exit}')
echo "worker host PID=$PID"
grep -E 'VmPeak|VmSize|VmRSS|RssAnon|RssFile|Threads' "/proc/$PID/status"
```

### 2.3 Disparar el OOM y mirar la traza

Opción A, todo en uno:

```bash
./lab/os-activity/run-activity.sh --url "${LAB_URL:-http://127.0.0.1:8080/}"
```

Opción B, manual y en dos terminales:

```bash
# Terminal 1: traza durante 10 s
./lab/os-activity/trace-worker.sh 10

# Terminal 2: dispara el OOM
python3 trigger.py --url "${LAB_URL:-http://127.0.0.1:8080/}" \
  --mode progress --size 1048576
```

La traza manual queda en `lab/os-activity/out/<ts>-trace/`; si usaste
`run-activity.sh`, en `lab/os-activity/out/latest/trace/`. Para encontrar la
última traza manual:

```bash
TRACE_DIR=$(ls -dt lab/os-activity/out/*-trace 2>/dev/null | head -1)
grep -E 'mmap\(NULL, 2097152|Fatal error|exit_group|/tmp/sess_' \
  "${TRACE_DIR:-lab/os-activity/out/latest/trace}"/strace-*.log | tail -n 20
```

Huella observada en este entorno (los números cambian):

```text
mmap(NULL, 2097152, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0) = 0x...
write(2<pipe:...>, "NOTICE: PHP message: PHP Fatal error:  Allowed memory size of 4194304 bytes exhausted ...", 164) = 164
exit_group(70) = ?
```

### 2.4 La tabla que no engaña

| Métrica | Dónde vive | Qué te está contando |
|---|---|---|
| `memory_limit` | `php -i` | Contador de **Zend MM**, no memoria real del proceso |
| `VmSize` | `/proc/<pid>/status` | Espacio virtual reservado; puede ser enorme sin estar usado |
| `VmRSS` | `/proc/<pid>/status` | Páginas físicas residentes |
| `RssAnon` / `RssFile` | `/proc/<pid>/status` | RSS anónimo / mapeado de ficheros |
| `minflt` / `majflt` | `/proc/<pid>/stat`, `pidstat -r` | Page faults menores / mayores |
| `memory.current` | cgroup v2 | Memoria cargada al cgroup **ahora** |
| `memory.peak` | cgroup v2 | Pico histórico del cgroup |
| `memory.max` | cgroup v2 | Límite del cgroup (`mem_limit` de Compose) |
| `memory.events` | cgroup v2 | `oom`, `oom_kill`, `high`, `max` |

### 2.5 Trampas de campo

- **`memory.peak` no es de esta ejecución.** Es histórico desde que se creó
  el cgroup. Para un pico limpio, recrea el contenedor:
  `./lab/os-activity/run-activity.sh --fresh` o
  `docker compose up -d --force-recreate php`. `docker compose restart php`
  no sirve: reinicia el proceso dentro del mismo cgroup.
- **`VmSize` no es memoria usada.** 190 MB de espacio virtual y 16 MB de RSS
  pueden convivir perfectamente.
- **`memory_limit=-1` no significa “sin límite”.** Significa “sin límite de
  PHP”; el cgroup y el kernel siguen teniendo la última palabra.
- **`dmesg` puede estar restringido.** Si no puedes leerlo, no concludes que
  no hubo OOM: mira `memory.events`.

Preguntas para llevar al cuaderno:

1. Si `memory_limit=4M`, ¿por qué `VmSize` supera los 190 MB?
2. ¿Qué cuenta exactamente `memory_limit` y qué **no** cuenta?
3. ¿Por qué el proceso muere con un fatal de PHP y no con un `SIGKILL`?
4. ¿Qué evidencia demuestra que el cgroup **no** llegó a su límite?
5. En la traza, identifica el `mmap` de 2 MiB. ¿Qué componente lo pide?
6. ¿Por qué el pico sigue visible después de que muera el worker?
7. ¿Qué pasaría si `memory_limit=-1` y el cgroup tuviera un límite bajo?
   ¿Quién mataría al proceso y con qué señal?
8. ¿Por qué `RssAnon` y `RssFile` no suman exactamente `VmRSS`?

---

## 3. Segunda parada: los que sostienen la barra

### 3.1 El árbol

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

Fíjate en tres cosas:

- el **máster** corre como `root` y es el PID 1 del contenedor;
- el **worker** corre como `www-data` y su `PPid` es el máster;
- `php/www.conf` usa `pm=static` y `pm.max_children=1`: un solo worker.

### 3.2 El momento en que cambia el reparto

Antes:

```bash
docker top php2shell-lab-php-1 -eo pid,ppid,user,args | tee /tmp/antes.txt
```

Dispara el OOM si no lo has hecho:

```bash
python3 trigger.py --url "${LAB_URL:-http://127.0.0.1:8080/}" --mode progress
```

Después:

```bash
docker top php2shell-lab-php-1 -eo pid,ppid,user,args | tee /tmp/despues.txt
docker compose logs --since=5m php | tail -n 30
docker compose logs --since=5m nginx | tail -n 20
```

Huella observada:

```text
WARNING: [pool www] child 7 exited with code 70 after ...
NOTICE: [pool www] child 115 started
```

```text
[error] ... upstream sent unexpected FastCGI record: 3 ...
"POST / HTTP/1.1" 502 ...
```

### 3.3 La lectura

- `exit code 70` es un **estado de salida**, no una señal. En la traza lo ves
  como `exit_group(70)`.
- El máster no muere: es el supervisor. El worker es el que ejecuta la
  petición y el que sufre el fatal.
- nginx no devuelve `500` porque PHP no llegó a producir una respuesta HTTP
  válida. Devuelve `502` porque su upstream FastCGI se rompió a mitad.
- La petición en curso vive en la memoria del worker. Al morir, se pierde;
  lo que quede en `/tmp` es otra historia.

Preguntas:

1. ¿Qué proceso muere: el máster o el worker? ¿Por qué?
2. ¿Qué significa `exit code 70`? ¿Es una señal? ¿Qué syscall lo produce?
3. ¿Cómo se vería un `SIGKILL` en los logs y en `memory.events`?
4. ¿Por qué nginx responde `502` y no un `500` de PHP?
5. ¿Qué configuración de FPM permite un solo worker y el respawn?
6. ¿Qué cambia con `mod_php`? ¿Sigue existiendo el `502` de FastCGI?
7. ¿Qué pasa con `pids.current` / `pids.max` si subes `pm.max_children`?

---

## 4. Tercera parada: lo que queda escrito

### 4.1 Montajes

Dentro del contenedor PHP:

```bash
docker exec php2shell-lab-php-1 sh -c '
  findmnt -T /tmp
  findmnt -T /var/www/html
  df -hT /tmp /var/www/html
  df -i /tmp /var/www/html
  stat -f -c "type=%T block=%s blocks=%b free=%f files=%c ffree=%d" /tmp
'
```

Huella observada:

| Ruta | Tipo | Opciones | Tamaño |
|---|---|---|---|
| `/tmp` | `tmpfs` | `rw,nosuid,nodev,noexec,relatime,size=65536k` | 64 MiB |
| `/var/www/html` | `ext4` (bind mount) | `ro,relatime` | rootfs de solo lectura |

El rootfs es de solo lectura (`read_only: true` en Compose). Compruébalo:

```bash
docker exec php2shell-lab-php-1 sh -c \
  'touch /var/www/html/.prueba 2>&1 || true'
# touch: cannot touch ...: Read-only file system
```

Pero `/tmp` sí es escribible:

```bash
docker exec php2shell-lab-php-1 sh -c \
  'touch /tmp/.prueba && ls -l /tmp/.prueba && rm /tmp/.prueba'
```

### 4.2 La sesión

```bash
python3 lab/rt.py validate \
  --url "${LAB_URL:-http://127.0.0.1:8080/}" \
  --docker-inspect --compose-file docker-compose.yml
```

```bash
docker exec php2shell-lab-php-1 sh -c '
  for f in /tmp/sess_*; do
    [ -e "$f" ] || continue
    stat -c "inodo=%i modo=%a dueño=%U:%G tamaño=%s %n" "$f"
  done
'
```

Huella observada:

```text
inodo=2 modo=600 dueño=www-data:www-data tamaño=362 /tmp/sess_...
```

### 4.3 La prueba del inodo

```bash
docker exec php2shell-lab-php-1 sh -c '
  f=/tmp/os-inode-demo
  touch "$f"; stat -c "primero=%i" "$f"
  rm "$f"
  touch "$f"; stat -c "segundo=%i" "$f"
  rm "$f"
'
```

No te quedes con el número: pregúntate qué significa que se repita. Un inodo
no es un nombre, y un nombre no es un fichero.

### 4.4 La trampa de `noexec`

`noexec` impide ejecutar binarios o scripts con `execve` desde ese montaje.
No impide escribir, leer, incluir o interpretar un fichero. Un webshell PHP
en un directorio `noexec` puede funcionar si Apache/mod_php lo lee y lo
compila como PHP; el `execve` es del servidor web, no del fichero.

Si el target de entrenamiento está levantado, compara `/tmp` con
`/var/www/html/uploads`: cambia el tamaño y el contenido, pero no la opción
`noexec`. La diferencia que importa es que `uploads` es **escribible** y el
rootfs no.

Preguntas:

1. ¿Por qué la sesión se escribe en `tmpfs` y no en el rootfs?
2. ¿Qué significa el modo `600`? ¿Quién puede leerlo y escribirlo?
3. ¿Qué es un inodo? ¿Por qué puede ser un número bajo en `tmpfs`?
4. ¿Qué ocurre con la sesión tras `docker compose down -v`?
5. ¿Qué diferencia hay entre borrar un fichero y truncarlo?
6. ¿Qué implica `noexec` para un atacante que puede escribir un fichero?
7. ¿Qué diferencia hay entre `read_only: true` y un `tmpfs`?

---

## 5. El cruce: una caída, tres relojes

Completa esta línea temporal con evidencia real:

| t | Evento | Capa | Evidencia |
|---|---|---|---|
| t0 | POST multipart con `session.upload_progress` | red / proceso | log nginx, `strace read(...)` |
| t1 | Zend MM pide un chunk de 2 MiB | memoria de usuario | `mmap(NULL, 2097152, ...)` |
| t2 | Fatal por `memory_limit` | memoria de usuario | `Fatal error ... 4194304 bytes exhausted` |
| t3 | Worker termina | proceso | `exit_group(70)` |
| t4 | FPM registra la salida y crea otro worker | proceso | `child ... exited with code 70` / `child ... started` |
| t5 | nginx ve el corte FastCGI | red / proceso | `unexpected FastCGI record` / `502` |
| t6 | Fichero `sess_*` en `/tmp` | filesystem | inodo, modo 600, `www-data` |

La pregunta final no es “¿qué pasó?”, sino **¿cómo encajan las tres capas
sin que ninguna mienta?** Un límite de usuario de 4 MiB termina en un `502`,
un worker nuevo y un fichero en `tmpfs`. El kernel no mató nada. Eso es lo
que hay que explicar.

---

## 6. Cómo dejar evidencia

| Script | Qué hace |
|---|---|
| `collect-snapshot.sh` | Snapshot de `/proc`, cgroup, montajes, sesiones y logs |
| `trace-worker.sh` | `strace` del worker con un contenedor auxiliar y `SYS_PTRACE` |
| `run-activity.sh` | Flujo completo y resumen automático |

```bash
# Flujo completo
./lab/os-activity/run-activity.sh --start

# Puerto alternativo y pico limpio
LAB_PORT=18080 ./lab/os-activity/run-activity.sh \
  --start --fresh --url http://127.0.0.1:18080/

# Sin strace
./lab/os-activity/run-activity.sh --no-trace

# Snapshots sueltos
./lab/os-activity/collect-snapshot.sh baseline
./lab/os-activity/collect-snapshot.sh after
```

Árbol de una ejecución completa:

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

`lab/os-activity/out/` está ignorado por git: es evidencia local, no código.
Los scripts no escriben fuera del repo y solo hablan con `127.0.0.1`.

### Si el helper de traza falla

- Comprueba que Docker permite `--pid=container:...` y `--cap-add=SYS_PTRACE`.
- Usa `--no-trace`: memoria, procesos y filesystem se pueden completar con
  `/proc`, cgroup, `pidstat` y logs.
- En un host con `strace` y permisos de ptrace, también puedes trazar el PID
  del host directamente:

  ```bash
  PID=$(docker top php2shell-lab-php-1 -eo pid,ppid,user,args \
    | awk 'NR>1 && /php-fpm: pool / {print $1; exit}')
  strace -f -tt -T -yy -s 256 -p "$PID"
  ```

---

## 7. Entregable

1. `worksheet.md` completado, con valores y fuentes.
2. Directorio de evidencias `lab/os-activity/out/<timestamp>-activity/`.
3. Informe de una página:
   - línea temporal del fallo;
   - tres conclusiones de memoria, tres de procesos y tres de filesystem;
   - la métrica exacta que demuestra que **no** hubo OOM del kernel.
4. Copia de los comandos que usaste, tal como los ejecutaste.

### Rúbrica

| Criterio | Peso | Qué se valora |
|---|---:|---|
| Evidencia | 40 % | Snapshots, traza, logs y comandos reproducibles |
| Análisis | 30 % | Interpretación correcta de memoria, procesos y FS |
| Correlación | 20 % | Línea temporal coherente entre las tres capas |
| Comunicación | 10 % | Informe claro, sin afirmaciones sin evidencia |

Mínimo para aprobar: identificar que el fallo es **PHP OOM** (no kernel OOM),
explicar el `exit code 70` y localizar la sesión en `tmpfs`.

---

## 8. Limpieza

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

## 9. Para seguir tirando del hilo

- `proc(5)`: `/proc/<pid>/status`, `stat`, `limits`, `cgroup`.
- cgroup v2: `memory.current`, `memory.peak`, `memory.events`, `pids.current`.
- `mmap(2)`, `brk(2)`: memoria virtual y heap.
- `tmpfs(5)`: ficheros en memoria, tamaño e inodos.
- `strace(1)`: traza de syscalls.
- PHP-FPM: `pm`, `pm.max_children`, `catch_workers_output`, exit codes.
- PHP: `session.upload_progress`, `memory_limit`, `memory_get_peak_usage`.
- Docker: `--memory`, `--pids-limit`, `read_only`, `tmpfs`, `cap_add`.

Si algo de este cuaderno no cuadra con tu ejecución, no lo tapes: anótalo.
Las diferencias entre entornos son parte de la lección.
