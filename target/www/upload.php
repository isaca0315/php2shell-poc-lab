<?php
// LAB ONLY - aplicacion de entrenamiento deliberadamente vulnerable.
// No usar este codigo fuera de un entorno aislado.
$msg = '';
$ok = false;

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_FILES['avatar'])) {
    $f = $_FILES['avatar'];
    $name = basename((string) $f['name']);

    // VULN INTENCIONADA: blacklist incompleta. Solo bloquea ".php" exacto;
    // deja pasar .phtml, .php5, .phar, etc.
    if (preg_match('/\.php$/i', $name)) {
        $msg = 'Extension .php bloqueada.';
    } elseif ($f['error'] !== UPLOAD_ERR_OK) {
        $msg = 'Error de subida: ' . (int) $f['error'];
    } else {
        $dir = __DIR__ . '/uploads';
        @mkdir($dir, 0777, true);
        $dest = $dir . '/' . $name;
        if (move_uploaded_file($f['tmp_name'], $dest)) {
            $ok = true;
            $msg = 'Avatar subido: uploads/' . htmlspecialchars($name, ENT_QUOTES);
        } else {
            $msg = 'No se pudo guardar el archivo.';
        }
    }
}

$files = array_values(array_diff(scandir(__DIR__ . '/uploads') ?: [], ['.', '..']));
?>
<!doctype html>
<html lang="es">
<head>
  <meta charset="utf-8">
  <title>PHP2Shell Training Portal</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 720px; margin: 3rem auto; padding: 0 1rem; }
    .lab { background: #fff3cd; border: 1px solid #ffecb5; padding: .75rem 1rem; border-radius: 6px; }
    .ok { color: #0a6b2e; }
    code { background: #f3f3f3; padding: .1rem .3rem; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>PHP2Shell Training Portal</h1>
  <p class="lab"><strong>LAB ONLY:</strong> esta app es vulnerable por diseno.
  No la expongas fuera de <code>127.0.0.1</code>.</p>

  <?php if ($msg): ?>
    <p class="<?= $ok ? 'ok' : '' ?>"><?= $msg ?></p>
  <?php endif; ?>

  <h2>Subir avatar</h2>
  <form method="post" enctype="multipart/form-data">
    <input type="file" name="avatar" required>
    <button type="submit">Subir</button>
  </form>

  <h2>Archivos subidos</h2>
  <ul>
    <?php foreach ($files as $f): ?>
      <li><a href="uploads/<?= htmlspecialchars($f, ENT_QUOTES) ?>"><?= htmlspecialchars($f, ENT_QUOTES) ?></a></li>
    <?php endforeach; ?>
  </ul>
</body>
</html>
