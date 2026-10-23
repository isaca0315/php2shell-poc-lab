# Análisis de Sistemas Operativos: PHP2Shell (CVE-2026-109618 / CVE-2026-109619)

> **Propósito:** investigación académica / laboratorio ofensivo-defensivo **controlado** en `127.0.0.1`. El objetivo es correlacionar **fallo de memoria en espacio usuario (Zend MM)** con **mecánicas del SO**: llamadas al sistema, gestión de memoria virtual, señales, ciclo de vida de procesos (prefork/FPM), aislamiento y logs del kernel/daemon.

## 1. Fundamentos teóricos relevantes

### 1.1 Espacio usuario vs espacio kernel
- **Zend Memory Manager (Zend MM)**: gestión propia dentro de `php`. No pide memoria con `malloc` directo para todo, sino que solicita *chunks* grandes al kernel con `mmap(2)` (normalmente ~2 MiB) y reparte con *bins*, *big allocations* y *huge*. 
- **`memory_limit`**: es un contador del **Zend MM** (`zend_alloc`). Es independiente del RSS, del `VmSize`/`VmRSS`, de `ulimit -v` y de límites cgroup. Es "memoria que PHP cree que está usando".
- **OOM de PHP**: cuando `zend_mm_safe_error()` detecta exceso, llama `zend_bailout()` → `longjmp()`. Eso abandona la pila de llamadas de usuario sin pasar por el *cleanup* planificado en muchos puntos.
- **OOM del kernel**: el SO tiene que asignar páginas físicas/anonimas y, si no hay memoria (ni swap utilizable), activa el *OOM Killer*. Verificable con `dmesg`, `journalctl -k`, `cgroup v2 memory.events`.

### 1.2 Gestión de memoria virtual
- `mmap(MAP_ANONYMOUS|MAP_PRIVATE)`: usado por Zend para chunks. 
- `brk/sbrk` menos común hoy; `mmap` es el mecanismo típico.
- **ASLR**: aleatorización de direcciones (heap/stack/mmap/libs). Relevante para convertir corrupción en ejecución (fuera del alcance de este PoC).
- **Copy-on-Write**: poco relevante aquí, pero importante para entender comportamiento de forks.
- **Páginas**: una asignación `mmap` crea *VM area*; las páginas físicas se asignan *on-demand* (*page fault*). El límite cgroup v2 controla `memory.current`/`memory.peak`.

### 1.3 Procesos, señales y FPM
- **Modelo prefork** (Apache mod_php) vs **separación** (nginx + PHP-FPM).
- **PHP-FPM**: proceso **maestro** gestiona un **pool** con hijos `www-data`. Si un hijo muere por fatal/error interno (código 70) o señal, el maestro crea uno nuevo (patrón de tolerancia a fallos).
- **FastCGI**: protocolo binario sobre socket (UNIX o TCP). Un corte brusco del lado FPM puede generar `FastCGI record` inesperado en nginx → `502`.
- **Señales**: `SIGSEGV` (11) indica acceso inválido a memoria; `SIGABRT` por `assert`; `SIGKILL` (9) por OOM killer.

### 1.4 Syscalls a observar
| Syscall | Contexto | ¿Por qué? |
|---|---|---|
| `mmap`, `munmap`, `mprotect` | Zend MM / allocators | Ver crecimiento del heap/mappings al parsear multipart |
| `open`, `read`, `write` | sesión, archivos temp | `session.save_path=/tmp`, escritura de `sess_*` |
| `accept`, `recvfrom`, `sendto` | FastCGI/HTTP | tráfico hacia el worker |
| `brk` | menos común | evolución del allocator |
| `clone/fork` | FPM maestro/niños | ciclo de vida |
| `exit_group`, `_exit` | salida del worker | códigos 70 / señal |

## 2. Instrumentación disponible

En el host hay: `strace`, `pidstat`, `perf`, `bpftrace`, `jq`, `timeout`. Docker con cgroup v2.

### 2.1 Aislamiento del proceso objetivo
```bash
docker top php2shell-lab-php-1 -eo pid,ppid,user,args
# maestro: 54487 (root), worker: 54661 (www-data)
```

Para tracer el **worker** concreto (cambia tras reinicio):
```bash
PID=$(docker top php2shell-lab-php-1 2>&1 | awk '/php-fpm: pool www/{print $1; exit}')
echo $PID
```

## 3. Procedimiento de trazado (OS-oriented)

> **Nota:** `strace` en contenedores con `no-new-privileges`, `cap_drop: ALL` suele funcionar, pero algunas configuraciones lo bloquean. Si falla, usar `nsenter` o `docker exec`.

### 3.1 Trazado de syscalls con `strace`
Desde el host, apuntando al PID del worker FPM:
```bash
cd /home/ponciop/cwl/poc-php2shell
PID=$(docker top php2shell-lab-php-1 2>&1 | awk '/php-fpm: pool www/{print $1; exit}')
mkdir -p os-trace
# guardar salida con timestamp
timeout 60 strace -tt -T -yy -s 256 -e trace=mmap,munmap,mprotect,brk,open,read,write,close,accept,recv,send,clone,_exit,exit_group -p $PID 2>&1 | tee os-trace/strace_$(date +%s).log
```

En otra terminal disparar el trigger:
```bash
python3 trigger.py --url http://127.0.0.1:8080/ --mode progress
```

**Lo que buscar:** ráfagas de `mmap`/`munmap` coincidiendo con el parseo multipart, muchos `open/read/write` relacionados con `/tmp/sess_*` y/o la petición, y finalmente `exit_group(70)` o la señal.

### 3.2 Estadísticas de proceso / memoria / CPU con `pidstat`
```bash
PID=$(docker top php2shell-lab-php-1 2>&1 | awk '/php-fpm: pool www/{print $1; exit}')
pidstat -p $PID -r -u -d 1 10 > os-trace/pidstat_$(date +%s).txt
```

Campos a interpretar:
- `%usr/%system`: carga en espacio usuario vs kernel
- `minflt/majflt`: *minor page faults* (páginas ya presentes) vs *major* (disco/swap). Un aumento repentino suele deberer invitado *page fault* por *mmap* y acceso posterior.
- `VSZ`, `%MEM`: VSZ crece con VM, %MEM con RSS
- `kB_rd/kB_wr`: I/O

### 3.3 Métricas de memoria del contenedor / cgroup v2
```bash
CG=$(docker inspect -f '{{.HostConfig.CgroupParent}}' php2shell-lab-php-1 2>/dev/null)
# cgroup v2 suele estar en /sys/fs/cgroup/docker/...
CID=$(docker ps -qf "name=php2shell-lab-php-1")
CG2="/sys/fs/c# PR Title
Implementación de laboratorio PHP2Shell con análisis OS y trazado

# PR Body
Trabajo completo en /home/ponciop/cwl/poc-php2shell con:
- docker-compose aislado (php:8.5.11 vulnerable, nginx loopback, red dedicada, read_only, tmpfs, cap_drop, límites)
- php.ini/fpm/nginx configurados, www/index.php
- trigger.py (no RCE) para simular OOM en session.upload_progress (modes progress/parts/names)
- docker-compose.fixed.yml con php:8.5.12
- collect-evidence.sh para recopilar logs, sesiones, dmesg/journalctl/coredump
- OS-SYS-ANALYSIS.md con fundamentos, trazado strace/pidstat/perf/bpftrace, correlación con logs y sección ofensivo-defensivo
- os-trace/ y os-analysis/ con scripts (trace-worker.sh, trace-once.sh, analyze-os.sh, quick-os-view.sh)
- RESULTADOS-OS.md con evidencia real obtenida: fatal in Unknown on line 0, worker exited with code 70, nginx 502, session files creados, sin OOM kernel

Se documenta paso a paso qué ocurre a nivel proceso/VM/memoria, cómo validar con logs dmesg/syslog/nginx/php-fpm, y se resalta claramente la diferencia entre OOM PHP vs kernel y entre FPM (reemplazo de hijo) y mod_php.

Todo ejecutado en entorno local aislado (127.0.0.1), sin payloads RCE.

## Commit 1 description in Spanish as requested.

Entrega: documentación, pruebas y análisis OS detallados. 

Includes full reproducible lab, tracing tools, evidence collection, comparison vulnerable vs patched, and OS-focused explanation (mmap/Zend MM/longjmp/FPM/signals/cgroups). Sin código malicioso. 

Done.