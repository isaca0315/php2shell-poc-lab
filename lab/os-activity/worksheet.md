# Cuaderno de campo — PHP2Shell desde dentro

**Nombre:** __________________________
**Fecha:** ___________________________
**Entorno:** `php:8.5.11-fpm` + nginx + cgroup v2
**Directorio de evidencias:** `lab/os-activity/out/<timestamp>-activity/`

> Rellena esto como si se lo explicaras a alguien que no estuvo delante.
> Cada fila necesita una fuente: un comando, una ruta o una línea de log.
> Si no la tienes, la fila no cuenta. Los valores de ejemplo son solo eso:
> ejemplos. No los copies; busca los tuyos.

---

## 0. Ficha de la sesión

| Dato | Valor | Fuente |
|---|---|---|
| Imagen PHP | | `docker inspect -f '{{.Config.Image}}' php2shell-lab-php-1` |
| Versión PHP | | `docker exec php2shell-lab-php-1 php -v` |
| `memory_limit` | | `docker exec ... php -i \| grep memory_limit` |
| URL objetivo | | `curl -sS ...` |
| cgroup del contenedor | | `find /sys/fs/cgroup ...` |
| `memory.max` | | `cat $CG/memory.max` |
| `pids.max` | | `cat $CG/pids.max` |
| Rootfs del contenedor | | `docker inspect ... ReadonlyRootfs` / `findmnt` |
| Montaje de `/tmp` | | `findmnt -T /tmp` |
| Montaje de `/var/www/html` | | `findmnt -T /var/www/html` |

**¿Qué esperaba encontrar antes de empezar?**

__________________________________________________________________________

__________________________________________________________________________

---

## 1. El aire: memoria

### 1.1 Antes, durante y después

| Métrica | Baseline | Pico / durante | Después | Fuente |
|---|---:|---:|---:|---|
| `VmSize` (kB) | | | | `/proc/<pid>/status` |
| `VmRSS` (kB) | | | | `/proc/<pid>/status` |
| `RssAnon` (kB) | | | | `/proc/<pid>/status` |
| `RssFile` (kB) | | | | `/proc/<pid>/status` |
| `Threads` | | | | `/proc/<pid>/status` |
| `memory.current` (bytes) | | | | cgroup v2 |
| `memory.peak` (bytes) | | | | cgroup v2 |
| `memory.max` (bytes) | | | | cgroup v2 |
| `pids.current` | | | | cgroup v2 |
| `minflt/s` (muestra) | | | | `pidstat -r` |
| `majflt/s` (muestra) | | | | `pidstat -r` |

### 1.2 La traza

| Syscall / mensaje | ¿Aparece? | Línea o valor |
|---|---|---|
| `mmap(NULL, 2097152, ...)` | sí / no | |
| `write(... "Fatal error ...")` | sí / no | |
| `exit_group(70)` | sí / no | |
| `openat(... /tmp/sess_...)` | sí / no | |

### 1.3 Mi lectura

1. ¿Qué cuenta `memory_limit` y por qué `VmSize` es mucho mayor?

   ______________________________________________________________________

2. ¿Por qué el proceso no recibe `SIGKILL` del OOM killer?

   ______________________________________________________________________

3. ¿Qué demuestra `memory.events` con `oom 0` / `oom_kill 0`?

   ______________________________________________________________________

4. ¿Qué diferencia hay entre `memory.current` y `memory.peak`?

   ______________________________________________________________________

5. ¿Qué representan `minflt` y `majflt`? ¿Cuál esperabas ver aquí?

   ______________________________________________________________________

6. Si `memory_limit=-1` y el cgroup tiene `memory.max=64m`, ¿quién mata al
   proceso y con qué señal? ¿Qué evidencia buscarías?

   ______________________________________________________________________

**Una frase que resuma esta capa:**

__________________________________________________________________________

---

## 2. Los que sostienen la barra: procesos

### 2.1 Quién vive, quién muere, quién lo reemplaza

| Dato | Antes | Después |
|---|---|---|
| PID del máster (host) | | |
| PID del worker (host) | | |
| PID del máster (contenedor) | | |
| PID del worker (contenedor) | | |
| PPID del worker | | |
| Usuario del máster | | |
| Usuario del worker | | |
| Estado del worker | | |
| Nº de hilos | | |

### 2.2 Los logs

| Log | Línea observada |
|---|---|
| PHP-FPM: fatal | |
| PHP-FPM: salida del worker | |
| PHP-FPM: nuevo worker | |
| nginx: error FastCGI | |
| nginx: código HTTP | |

### 2.3 Mi lectura

1. ¿Qué proceso muere y cuál sobrevive? ¿Por qué?

   ______________________________________________________________________

2. ¿Qué significa `exit code 70`? ¿Es una señal? ¿Qué syscall lo produce?

   ______________________________________________________________________

3. ¿Cómo se vería un `SIGKILL` en los logs y en `memory.events`?

   ______________________________________________________________________

4. ¿Por qué nginx responde `502` en lugar de un `500` de PHP?

   ______________________________________________________________________

5. ¿Qué configuración de FPM permite que haya un solo worker y que el máster
   lo reemplace?

   ______________________________________________________________________

6. ¿Qué cambia en `mod_php` (Apache) respecto a FPM? ¿Sigue habiendo un
   `502` de FastCGI?

   ______________________________________________________________________

**Una frase que resuma esta capa:**

__________________________________________________________________________

---

## 3. Lo que queda escrito: sistemas de archivos

### 3.1 Montajes

| Ruta | FSType | Opciones relevantes | Tamaño | ¿Escritura? |
|---|---|---|---:|---|
| `/tmp` | | | | sí / no |
| `/var/www/html` | | | | sí / no |
| `/var/www/html/uploads` (si aplica) | | | | sí / no |

### 3.2 El fichero de sesión

| Dato | Valor |
|---|---|
| Ruta | |
| Inodo | |
| Modo | |
| Dueño:Grupo | |
| Tamaño | |
| ¿Sobrevive a `docker compose down`? | |

### 3.3 La prueba del inodo

| Intento | Inodo | ¿Qué cambió? |
|---|---:|---|
| Primer `touch` | | |
| Tras `rm` y segundo `touch` | | |

### 3.4 Mi lectura

1. ¿Por qué la sesión se escribe en `tmpfs` y no en el rootfs?

   ______________________________________________________________________

2. ¿Qué significa el modo `600`? ¿Quién puede leerlo/escribirlo?

   ______________________________________________________________________

3. ¿Qué es un inodo? ¿Por qué el inodo puede ser un número bajo en `tmpfs`?

   ______________________________________________________________________

4. ¿Qué implica `noexec` en `/tmp` para un atacante que puede escribir un
   fichero? ¿Y si el montaje fuera `exec`?

   ______________________________________________________________________

5. En la prueba de inodo, ¿se reutilizó? ¿Qué implica para la caché y para
   ficheros borrados que siguen abiertos?

   ______________________________________________________________________

6. ¿Qué diferencia hay entre `read_only: true` y un `tmpfs`?

   ______________________________________________________________________

**Una frase que resuma esta capa:**

__________________________________________________________________________

---

## 4. El cruce: una caída, tres relojes

| t | Evento | Capa | Evidencia (ruta/línea) |
|---|---|---|---|
| t0 | POST multipart | | |
| t1 | `mmap` de 2 MiB | | |
| t2 | Fatal `memory_limit` | | |
| t3 | `exit_group(70)` | | |
| t4 | Respawn del worker | | |
| t5 | `502` de nginx | | |
| t6 | `sess_*` en `/tmp` | | |

**La explicación en 60 segundos (5–8 líneas):**

__________________________________________________________________________

__________________________________________________________________________

__________________________________________________________________________

__________________________________________________________________________

__________________________________________________________________________

---

## 5. Dudas, trampas y cosas que no cuadraron

| Lo que vi | Lo que creía | Lo que era en realidad | Fuente |
|---|---|---|---|
| | | | |
| | | | |
| | | | |

**¿Qué fue lo más difícil de interpretar?**

__________________________________________________________________________

__________________________________________________________________________

**¿Qué haría falta para estar seguro de mi conclusión?**

__________________________________________________________________________

__________________________________________________________________________

---

## 6. Checklist de entrega

- [ ] Ficha de sesión completa.
- [ ] Tablas de memoria, procesos y filesystem con valores reales.
- [ ] Cada afirmación tiene una fuente (comando, ruta o log).
- [ ] Traza o logs citados.
- [ ] Narrativa de correlación en 5–8 líneas.
- [ ] Informe de una página.
- [ ] Comandos reproducibles incluidos.
- [ ] Evidencias en `lab/os-activity/out/<timestamp>-activity/`.
