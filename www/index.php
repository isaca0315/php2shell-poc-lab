<?php
// Script trivial a propósito: demuestra que el fallo ocurre ANTES de que
// el código de la aplicación se compile/ejecute.
header('Content-Type: text/plain');
echo "ok pid=" . getmypid()
   . " peak=" . memory_get_peak_usage(true)
   . " limit=" . ini_get('memory_limit') . "\n";
