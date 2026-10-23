# Actividad OS — PHP2Shell desde dentro

Una actividad corta para observar un **OOM de PHP** desde tres capas:
memoria, procesos y sistemas de archivos. El disparador es benigno y no
incluye RCE ni heap grooming.

## 1. Qué vas a observar

| Capa | Pregunta | Evidencia |
|---|---|---|
| Memoria | ¿Por qué PHP se queda sin 4 MiB si el cgroup tiene 256 MiB? | `memory.current`, `memory.peak`, `memory.max`, `memory.events`, `VmRSS` |
| Procesos | ¿Quién muere y quién lo reemplaza? | `exit_group(70)`, `child ... exited`, `child ... started` |
| Archivos | ¿Qué queda escrito después de la caída? | `/tmp` como `tmpfs`, `sess_*`, inodo, modo, rootfs `ro` |

La respuesta corta: muere el **worker** de PHP-FPM, no el kernel; el maestro
lo reemplaza y nginx devuelve **502**. La sesión queda en `/tmp`.

## 2. Ejecutar

Desde la raíz del repositorio:

```bash
LAB_PORT=18080 ./lab/os-activity/run-activity.sh \
  --start --fresh \
  --url http://127.0.0.1:18080/
```

El script hace todo el flujo: snapshot inicial, validación de sesión, traza
del worker, trigger de 1 MiB, snapshot final y resumen.

Si no quieres usar `strace`:

```bash
LAB_PORT=18080 ./lab/os-activity/run-activity.sh \
  --start --fresh --no-trace \
  --url http://127.0.0.1:18080/
```

Las evidencias quedan en `lab/os-activity/out/latest/`. Ese directorio es
material de trabajo: **no se entrega**.

## 3. Revisar

```bash
# Resumen de la corrida
cat lab/os-activity/out/latest/summary.md

# Memoria del cgroup y del worker
cat lab/os-activity/out/latest/after/summary.txt

# Logs de FPM y nginx
docker compose logs --since=5m php
docker compose logs --since=5m nginx
```

Busca estos cuatro datos:

1. `memory.events` con `oom 0` y `oom_kill 0`.
2. `Allowed memory size of 4194304 bytes exhausted`.
3. `child ... exited with code 70` y `child ... started`.
4. `502` y `unexpected FastCGI record` en nginx.

## 4. Entregable

Un **PDF hecho por ti**. No hay plantilla ni script de conversión: escribe el
informe en el editor que prefieras (Word, LibreOffice, Markdown, Google Docs,
etc.), pega las capturas y expórtalo a PDF.

Estructura sugerida:

1. Portada con tu nombre, fecha y objetivo.
2. Entorno y límites del contenedor.
3. Memoria: antes, después y `memory.events`.
4. Traza: `mmap`, fatal y `exit_group(70)`.
5. Procesos: worker que muere, worker nuevo y `502`.
6. Archivos: `tmpfs`, rootfs de solo lectura y `sess_*`.
7. Conclusiones y comandos usados.

Incluye estas cuatro capturas, cada una con una frase que explique qué
demuestra:

| Captura | Qué debe mostrar |
|---|---|
| 1 | Memoria antes/después y `memory.events` en cero |
| 2 | `mmap`, fatal de PHP y `exit_group(70)` |
| 3 | Muerte del worker, nuevo worker y `502` |
| 4 | `tmpfs`, rootfs de solo lectura y `sess_*` |

No entregues `out/`, scripts ni capturas sueltas. Solo el PDF.

## 5. Limpiar

```bash
docker compose down -v
```

## 6. Preguntas para cerrar

1. ¿Por qué `memory.current` puede ser mayor que `memory_limit`?
2. ¿Qué diferencia hay entre `exit_group(70)` y un `SIGKILL`?
3. ¿Por qué nginx responde 502 y no 500?
4. ¿Qué demuestra que el OOM fue de PHP y no del kernel?
5. ¿Por qué la sesión sobrevive a la muerte del worker?
