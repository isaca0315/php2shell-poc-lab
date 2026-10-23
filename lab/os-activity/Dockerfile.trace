# Imagen mínima para trazar el worker FPM desde el host sin instalar strace
# en la VM. Se ejecuta con:
#
#   docker run --rm --pid=container:<php> --cap-add=SYS_PTRACE \
#     -v <out>:/out php2shell-os-trace ... strace -p <pid>
#
# El script lab/os-activity/trace-worker.sh construye esta imagen si falta.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends strace \
 && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["strace"]
