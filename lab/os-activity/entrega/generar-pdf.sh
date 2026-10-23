#!/usr/bin/env bash
# Genera el PDF de entrega a partir de informe.md y las capturas.
#
# Requisitos:
#   - pandoc
#   - weasyprint (CLI o modulo de Python)
#
# Uso:
#   ./generar-pdf.sh
#   ./generar-pdf.sh informe.md salida.pdf
set -euo pipefail

DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"

INPUT=${1:-informe.md}
OUTPUT=${2:-informe-php2shell.pdf}

if ! command -v pandoc >/dev/null 2>&1; then
  echo "[!] Falta pandoc." >&2
  exit 1
fi

if [ ! -f "$INPUT" ]; then
  echo "[!] No existe el archivo de entrada: $INPUT" >&2
  exit 1
fi

HTML=".informe-render.html"
trap 'rm -f "$HTML"' EXIT

pandoc "$INPUT" \
  --from markdown+raw_html \
  --standalone \
  --syntax-highlighting=none \
  --metadata title="PHP2Shell desde dentro" \
  --css estilo.css \
  -o "$HTML"

if command -v weasyprint >/dev/null 2>&1; then
  weasyprint "$HTML" "$OUTPUT"
elif python3 -c 'import weasyprint' >/dev/null 2>&1; then
  python3 -m weasyprint "$HTML" "$OUTPUT"
else
  echo "[!] Falta weasyprint. Instala con: python3 -m pip install weasyprint" >&2
  exit 1
fi

echo "[i] PDF generado: $DIR/$OUTPUT"
