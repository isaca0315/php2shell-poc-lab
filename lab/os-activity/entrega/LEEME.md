# Entrega de la actividad OS

El único archivo que se entrega es:

```text
lab/os-activity/entrega/informe-php2shell.pdf
```

El PDF contiene el proceso completo, las capturas de la evidencia y el análisis de memoria, procesos y sistemas de archivos. No hace falta entregar `worksheet.md`, Markdown, capturas sueltas ni el directorio `out/`.

## Qué hay en esta carpeta

| Archivo | Para qué sirve |
|---|---|
| `informe-php2shell.pdf` | Entregable final |
| `informe.md` | Fuente editable del informe |
| `estilo.css` | Estilos de impresión |
| `generar-pdf.sh` | Regenera el PDF desde `informe.md` |
| `capturas/` | Imágenes usadas dentro del PDF |

## Regenerar el PDF

```bash
cd lab/os-activity/entrega
./generar-pdf.sh
```

Requiere `pandoc` y `weasyprint`. En Kali se pueden instalar con:

```bash
sudo apt install pandoc
python3 -m pip install weasyprint
```

## Cambiar las capturas

Las capturas están numeradas y el informe las referencia con esos nombres. Si repites el laboratorio y quieres usar tus propias imágenes, reemplaza los archivos dentro de `capturas/` manteniendo el mismo nombre y vuelve a ejecutar `./generar-pdf.sh`.

| Captura | Qué debe mostrar |
|---|---|
| `01-stack-procesos.png` | `docker compose ps`, `docker top` y límites del contenedor |
| `02-memoria.png` | Baseline, snapshot final y `memory.events` |
| `03-traza-oom.png` | `mmap`, fatal de PHP y `exit_group(70)` |
| `04-worker-502.png` | Salida del worker, nuevo worker y 502 de nginx |
| `05-montajes-sesion.png` | `tmpfs`, rootfs de solo lectura y `sess_*` |
| `06-timeline-memoria.png` | Gráfica de `memory.current` y `memory.peak` |

## Nota sobre los datos

Los PIDs, los tiempos, los inodos y los valores exactos de memoria cambian en cada corrida. Si repites el laboratorio, actualiza también las tablas de `informe.md` antes de generar el PDF. La explicación de las tres capas se mantiene; los números no.
