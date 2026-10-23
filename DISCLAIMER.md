# Disclaimer / Aviso Legal

## Propósito educativo
Este repositorio es únicamente con fines **educativos, académicos e investigativos**. Está diseñado para su uso en entornos **controlados, aislados y locales** con el único objetivo de aprender sobre vulnerabilidades, análisis de logs, forense, detección y respuesta.

## Uso autorizado
- **ÚNICAMENTE** en `127.0.0.1` / `localhost`.
- **ÚNICAMENTE** en máquinas virtuales o entornos aislados de los que seas propietario o tengas **autorización explícita por escrito** para probar.
- **NO** lo expongas a Internet, redes corporativas o cualquier red no aislada.
- **NO** lo uses contra sistemas de terceros sin permiso expreso.

## Responsabilidad
El autor **NO** se hace responsable del mal uso, daños, interrupciones, pérdidas de datos o cualquier consecuencia derivada del uso de este material. El usuario asume **TODA** la responsabilidad por el uso que haga de este laboratorio.

## Sin garantías
Este software se proporciona **"tal cual"**, sin garantías de ningún tipo, expresas o implícitas. No se garantiza su idoneidad para ningún fin concreto.

## Alcance del laboratorio
- **Acto 1 (CVE-2026-109618 / CVE-2026-109619):** Demostración del mecanismo de fallo (OOM en `session.upload_progress`, caída/reemplazo del worker PHP-FPM, escritura de sesión sin `session_start()`). **No es un exploit completo funcional.**
- **Acto 2:** Aplicación vulnerable **por diseño** incluida únicamente para fines formativos. **No explota** la corrupción de memoria de los CVE citados.

## Legal
El uso indebido de técnicas descritas en este repositorio puede ser **ilegal** en tu jurisdicción. Al utilizar este material, aceptas cumplir todas las leyes, reglamentos y políticas aplicables.
