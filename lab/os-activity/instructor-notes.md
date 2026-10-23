# Notas del instructor — Actividad OS

> Respuestas esperadas y evidencia real del laboratorio. Los PIDs, inodos y
> valores exactos cambian entre ejecuciones; lo importante es el razonamiento
> y la fuente de cada dato.

---

## 0. Preparación

```bash
cd php2shell-poc-lab
docker compose up -d php nginx
# Si 8080 está ocupado:
LAB_PORT=18080 docker compose up -d php nginx
export LAB_URL=http://127.0.0.1:18080/
```

Flujo recomendado:

```bash
./lab/os-activity/run-activity.sh --url "$LAB_URL"
```

Si el helper de `strace` falla por permisos de Docker:

```bash
./lab/os-activity/run-activity.sh --url "$LAB_URL" --no-trace
```

La actividad se puede evaluar igual con `/proc`, cgroup, `pidstat` y logs.

---

## 1. Memoria

### 1.1 Qué debería observar el alumno

Ejemplo real de este entorno (`php:8.5.11-fpm`, `memory_limit=4M`,
`mem_limit=256m`):

| Métrica | Baseline | Después del OOM |
|---|---:|---:|
| `VmSize` | ~191 504 kB | ~191 504 kB |
| `VmRSS` | ~16 004 kB | ~11 340 kB |
| `RssAnon` | ~7 732 kB | ~7 716 kB |
| `RssFile` | ~7 388 kB | ~3 620 kB |
| `Threads` | 1 | 1 |
| `memory.current` | ~12.0 MB | ~11.6 MB |
| `memory.peak` | ~14.0 MB | ~17.8 MB |
| `memory.max` | 256 MB | 256 MB |
| `pids.current` | 2 | 2 |
| `memory.events` | `oom 0`, `oom_kill 0` | igual |

El fatal esperado:

```text
PHP Fatal error:  Allowed memory size of 4194304 bytes exhausted
(tried to allocate 1052672 bytes) in Unknown on line 0
```

La traza esperada:

```text
mmap(NULL, 2097152, PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS, -1, 0) = 0x...
write(2<pipe:...>, "NOTICE: PHP message: PHP Fatal error:  Allowed memory size of 4194304 bytes exhausted ...", 164) = 164
exit_group(70) = ?
```

### 1.2 Respuestas

1. **`memory_limit` vs `VmSize`.** `memory_limit` es un contador del Zend
   Memory Manager: suma asignaciones `emalloc`/`zend_mm` de PHP. `VmSize`
   incluye todo el espacio virtual del proceso: binario, librerías, stacks,
   mappings de `mmap` y chunks de 2 MiB que Zend reserva aunque no los toque.
   Por eso 4 MiB de límite PHP no implican 4 MiB de `VmSize`.

2. **Por qué no hay `SIGKILL`.** El límite que se agota es el de PHP. Zend MM
   detecta el exceso, llama a `zend_bailout()` y el proceso termina con un
   fatal. El cgroup nunca llega a `memory.max`, así que el OOM killer del
   kernel no actúa.

3. **`memory.events`.** `oom 0` y `oom_kill 0` indican que el cgroup no
   alcanzó su límite y que el kernel no mató procesos por memoria. Es la
   evidencia principal de que no hubo OOM del kernel. `memory.peak` muestra
   el pico real del cgroup (~18 MB), muy por debajo de `memory.max` (256 MB).

4. **`memory.current` vs `memory.peak`.** `current` es el uso instantáneo;
   `peak` es el máximo histórico desde que se creó el cgroup (o desde el
   último reset). Por eso el pico sigue visible después de que el worker
   muera.

5. **Page faults.** `minflt` son fallos menores: la página ya estaba en
   memoria (page cache, cero, COW) y solo hay que mapearla. `majflt` requiere
   I/O (disco/swap). En este fallo predominan los `minflt` por el crecimiento
   del heap y el mapeo de páginas anónimas; no debería haber `majflt`
   significativos porque no hay swap ni lectura de disco relevante.

6. **Si `memory_limit=-1` y `memory.max=64m`.** El proceso intentaría seguir
   asignando; al llegar al límite del cgroup, el kernel dispararía el OOM
   killer del cgroup y enviaría `SIGKILL` (9) al proceso. Evidencia:
   `memory.events` con `oom`/`oom_kill` incrementados, `dmesg`/`journalctl -k`
   con `oom-kill`, y un worker que desaparece sin `exit_group(70)` (o con
   señal 9). Es un fallo distinto: OOM del kernel, no fatal de PHP.

7. **`RssAnon` + `RssFile` vs `VmRSS`.** No tienen por qué sumar exactamente:
   `VmRSS` incluye otras páginas residentes (stacks, mappings especiales,
   páginas compartidas contabilizadas de forma distinta). Son métricas
   relacionadas pero no una partición exacta.

### 1.3 Errores frecuentes

- Confundir `memory_limit` con `ulimit -v` o con `mem_limit` del contenedor.
- Leer `VmSize` y concluir que PHP “usa 190 MB” cuando el RSS es ~16 MB.
- Buscar OOM killer en `dmesg` sin comprobar `memory.events`; además `dmesg`
  puede estar restringido por permisos.
- Interpretar `memory.peak` como uso actual o como pico de **esta** ejecución:
  es histórico desde que se creó el cgroup. Para un pico limpio, recrea el
  contenedor PHP (`./run-activity.sh --fresh` o
  `docker compose up -d --force-recreate php`); `restart` no resetea el cgroup.

---

## 2. Procesos

### 2.1 Evidencia real

Antes:

```text
PID      PPID     USER       COMMAND
63585    63562    root       php-fpm: master process (/usr/local/etc/php-fpm.conf)
63652    63585    www-data   php-fpm: pool www
```

Después del OOM:

```text
WARNING: [pool www] child 7 exited with code 70 after 81.314186 seconds from start
NOTICE: [pool www] child 115 started
```

```text
[error] ... upstream sent unexpected FastCGI record: 3 while reading response header from upstream
"POST / HTTP/1.1" 502 157
```

Dentro del contenedor, el máster es PID 1 y el worker cambia (por ejemplo,
7 → 115). En el host, sus PIDs son distintos (por ejemplo, 63585 → 65591).

### 2.2 Respuestas

1. **Muere el worker, no el máster.** El máster es el supervisor: crea hijos,
   escucha el socket y repone los que caen. El worker es quien ejecuta la
   petición y sufre el fatal.

2. **`exit code 70`.** Es el estado de salida del proceso, no una señal.
   PHP-FPM usa el código 70 (`EX_SOFTWARE` / `FPM_EXIT_SOFTWARE`) para
   indicar un fallo software del hijo. En la traza se ve `exit_group(70)`.

3. **`SIGKILL`.** Se vería como señal 9, no como exit code 70. Si es el OOM
   killer del cgroup, `memory.events` incrementaría `oom_kill`; si es del
   host, `dmesg`/`journalctl -k` lo registraría. FPM podría registrar
   `killed by signal 9` en lugar de `exited with code 70`.

4. **`502` de nginx.** nginx habla FastCGI con FPM. Cuando el worker muere a
   mitad de la respuesta, nginx recibe un registro FastCGI incompleto o un
   cierre inesperado; no es un `500` generado por la aplicación porque PHP no
   llegó a producir una respuesta HTTP válida. El `500` sería un error de la
   app; el `502` es un fallo del upstream.

5. **Configuración FPM.** `php/www.conf` define `pm=static` y
   `pm.max_children=1`: un solo worker. El máster sigue vivo y crea otro
   hijo cuando el actual termina. `catch_workers_output=yes` permite ver el
   fatal y el respawn en los logs.

6. **`mod_php`.** En Apache + `mod_php` no hay FastCGI ni un máster FPM
   separado: Apache (prefork) atiende la petición en un proceso hijo. Un
   fatal puede afectar a ese hijo y Apache lo repone, pero no se produce el
   `502` de “unexpected FastCGI record” porque no hay upstream FastCGI.
   Cambian los PIDs, el árbol y los logs; el concepto de supervisión y
   respawn sigue siendo válido.

7. **Estado de la petición.** El cuerpo multipart y las estructuras de sesión
   estaban en la memoria del worker. Al morir, se pierde el estado en curso;
   lo que quede escrito en `/tmp` (si el handler llegó a escribir) es lo único
   que sobrevive. El socket FastCGI se corta y nginx devuelve `502`.

8. **`pids.current` / `pids.max`.** En el ejemplo, 2 (máster + worker) y 128.
   Un `pm.max_children` alto o un fork bomb agotaría `pids.max`; el cgroup
   impediría crear más procesos y `fork()`/`clone()` fallaría con `EAGAIN`.

---

## 3. Sistemas de archivos

### 3.1 Evidencia real

```text
TARGET SOURCE FSTYPE OPTIONS
/tmp   tmpfs  tmpfs  rw,nosuid,nodev,noexec,relatime,size=65536k,inode64

TARGET        SOURCE                                      FSTYPE OPTIONS
/var/www/html /dev/sda1[/home/kali/php2shell-poc-lab/www] ext4   ro,relatime,errors=remount-ro
```

```text
inodo=2 modo=600 dueño=www-data:www-data tamaño=362 /tmp/sess_...
```

```text
stat -f /tmp:
type=tmpfs block_size=4096 blocks=16384 free_blocks=16383 files=1318463 free_files=1318461
```

Rootfs:

```text
touch: cannot touch '/var/www/html/.os-activity-write-test': Read-only file system
```

Target de entrenamiento (si está levantado):

```text
TARGET                SOURCE FSTYPE OPTIONS
/var/www/html/uploads tmpfs  tmpfs  rw,nosuid,nodev,noexec,relatime,size=16384k,inode64
```

### 3.2 Respuestas

1. **Sesión en `tmpfs`.** `session.save_path=/tmp` y `/tmp` es un `tmpfs`
   escribible. El rootfs es de solo lectura (`read_only: true`), así que PHP
   no puede escribir sesiones en `/var/www/html`; necesita un punto de
   montaje escribible. `tmpfs` es rápido y volátil, adecuado para estado
   temporal.

2. **Modo `600`.** Solo el propietario (`www-data`) puede leer y escribir;
   el grupo y otros no tienen permisos. El worker corre como `www-data`, por
   eso puede escribir el fichero; el máster (root) también podría, pero no lo
   necesita.

3. **Inodo.** Es el identificador del objeto en el sistema de archivos, no el
   nombre. `tmpfs` asigna inodos de forma dinámica y puede empezar en números
   bajos (en este caso, 2). El nombre (`sess_<id>`) es una entrada de
   directorio que apunta al inodo.

4. **Persistencia.** `docker compose down -v` destruye el contenedor y su
   `tmpfs`; el fichero desaparece. No está en el host ni en un volumen
   persistente. Es una decisión deliberada del lab.

5. **`noexec`.** Impide ejecutar binarios o scripts mediante `execve` desde
   `/tmp`. No impide escribir, leer, incluir o interpretar el fichero. Un
   webshell PHP en un directorio `noexec` puede ejecutarse igualmente si
   Apache/mod_php lo lee y lo compila como PHP (el `execve` es del servidor
   web, no del fichero). `noexec` sí bloquea un binario ELF o un script con
   shebang que se intente ejecutar directamente.

6. **Comparación con `uploads`.** En este lab, `uploads` también es `tmpfs`
   con `noexec`. El webshell de entrenamiento funciona porque Apache lee el
   `.phtml` y `mod_php` lo interpreta; no se hace `execve` del fichero. La
   diferencia importante es que `uploads` es **escribible** y el rootfs no.
   Si se montara `exec`, un binario subido podría ejecutarse directamente,
   pero el vector PHP seguiría existiendo.

7. **Reutilización de inodo.** En `tmpfs`, al borrar y recrear un fichero es
   frecuente que se reutilice el mismo inodo (por ejemplo, 2). Eso no
   significa que sea el mismo fichero: el nombre y el contenido son nuevos.
   Para ficheros borrados que siguen abiertos, el inodo y los bloques no se
   liberan hasta cerrar el descriptor; `lsof +L1` puede mostrarlo si hay
   permisos.

8. **`read_only` vs `tmpfs`.** `read_only` afecta al rootfs del contenedor:
   no se puede modificar ninguna ruta del sistema de archivos de la imagen.
   `tmpfs` es un montaje aparte, en memoria, escribible (salvo opciones), que
   se monta sobre una ruta concreta. Se complementan: rootfs inmutable +
   zonas temporales acotadas.

### 3.3 Errores frecuentes

- Decir que `noexec` impide un webshell PHP. No lo impide si el servidor
  interpreta el fichero; solo impide `execve` directo.
- Confundir inodo con nombre o con contenido.
- Asumir que `tmpfs` es persistente porque `df` muestra espacio.
- Olvidar que el rootfs es `ro` y que por eso la sesión debe ir a `/tmp`.

---

## 4. Correlación esperada

| t | Evento | Subsistema | Evidencia |
|---|---|---|---|
| t0 | POST multipart con progreso | red / proceso | `strace read(5<TCPv6...>)`, log nginx |
| t1 | Zend MM pide chunk de 2 MiB | memoria usuario | `mmap(NULL, 2097152, ...)` |
| t2 | Fatal por `memory_limit` | memoria usuario | `Fatal error ... 4194304 bytes exhausted` |
| t3 | Worker termina | proceso | `exit_group(70)` |
| t4 | FPM repone el worker | proceso | `child ... exited with code 70` / `child ... started` |
| t5 | nginx detecta el corte | red / proceso | `unexpected FastCGI record` / `502` |
| t6 | Sesión en `/tmp` | filesystem | inodo, modo 600, `www-data` |

Narrativa modelo (no copiar literalmente; adaptar a la evidencia):

> El handler de `session.upload_progress` procesa el multipart antes de que se
> ejecute el script. Al copiar el valor de progreso, Zend MM supera el
> `memory_limit` de 4 MiB y llama a `zend_bailout`; el proceso termina con
> `exit_group(70)`. El cgroup nunca llega a `memory.max`, por lo que no hay
> OOM killer. El máster de FPM detecta la salida del hijo y crea otro; la
> petición en curso se pierde y nginx, que hablaba FastCGI con el worker
> muerto, devuelve `502`. La única evidencia que sobrevive es el fichero de
> sesión en el `tmpfs` de `/tmp`, con inodo propio, modo 600 y dueño
> `www-data`.

---

## 5. Rúbrica rápida

| Nivel | Evidencia | Análisis | Correlación |
|---|---|---|---|
| Excelente | Snapshots completos, traza y logs citados | Distingue Zend MM/cgroup, exit code/señal, tmpfs/rootfs | Línea temporal coherente y narrativa causal |
| Bien | Falta alguna métrica | Alguna confusión menor | Identifica los tres subsistemas |
| Suficiente | Evidencia mínima | Explica el fatal y el respawn | Nombra los eventos sin causalidad completa |
| Insuficiente | Sin evidencia o valores inventados | Confunde OOM PHP con OOM kernel | Lista eventos sin relación |

---

## 6. Solución de problemas

| Síntoma | Causa | Acción |
|---|---|---|
| `docker top ... awk` devuelve `www-data` | Se usó `$1` con la salida por defecto (`UID PID ...`) | Usar `-eo pid,ppid,user,args` o `$2` |
| `smaps_rollup`/`fd`: `Permission denied` | Falta `CAP_SYS_PTRACE` o ptrace/Yama | Es esperado; usar el helper o el snapshot; explicar el control de acceso |
| `strace: attach: No such process` | PID interno cambió tras el OOM | Volver a localizar el worker; el helper lo hace solo |
| `run-activity.sh` no conecta | Puerto ocupado o stack parado | `LAB_PORT=18080 ...`, `--url`, `--start` |
| `502` antes del trigger | Worker ya caído | `docker compose restart php` |
| `memory.events` no existe | cgroup v1 o ruta distinta | Usar `memory.usage_in_bytes`/`memory.max_usage_in_bytes` o adaptar |
| El timeline está vacío | No se encontró el cgroup | Revisar `CID`/ruta; usar `find /sys/fs/cgroup` |

---

## 7. Variante opcional: comparar con `mod_php`

```bash
./lab/run-modphp.sh
```

Puntos a comparar:

- ¿Quién es el proceso padre: FPM máster o Apache?
- ¿Hay un `502` de FastCGI o un error distinto?
- ¿El proceso que muere es un hijo de Apache?
- ¿Dónde quedan los logs de PHP?

No se necesita para aprobar la actividad; sirve para discutir SAPI y modelos
de concurrencia.
