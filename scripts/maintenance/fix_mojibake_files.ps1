# fix_mojibake_files.ps1
# Corrige mojibake en .html/.css: transforma "CatÃ¡logo" -> "Catálogo"
# Lee como texto (UTF-8 por defecto en .NET), detecta mojibake y aplica "encode CP1252 -> decode UTF-8".
$ErrorActionPreference = "Stop"

$cp1252   = [System.Text.Encoding]::GetEncoding(1252)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false) # UF-8 sin BOM

$targets = @()
if (Test-Path templates) { $targets += Get-ChildItem -Path templates -Recurse -File -Include *.html }
if (Test-Path static)    { $targets += Get-ChildItem -Path static    -Recurse -File -Include *.css  }

foreach ($f in $targets) {
  $text = [System.IO.File]::ReadAllText($f.FullName)  # .NET usa UTF-8 por defecto
  # Si el texto ya contiene mojibake típico ("Ã", "Â"), lo reparamos
  $hasMojibake = ($text.IndexOf([char]0x00C3) -ge 0) -or ($text.IndexOf([char]0x00C2) -ge 0)
  if ($hasMojibake) {
    $bytes1252 = $cp1252.GetBytes($text)                # interpretamos el texto mojibake como CP1252
    $fixed     = [System.Text.Encoding]::UTF8.GetString($bytes1252)  # y lo decodificamos a UTF-8 correcto
    [System.IO.File]::WriteAllText($f.FullName, $fixed, $utf8NoBom)
    Write-Host "Arreglado (UTF-8):" $f.FullName
  } else {
    Write-Host "OK (sin cambios):" $f.FullName
  }
}

Write-Host "Listo. Reinicia la app y fuerza refresh (Ctrl+F5)." -ForegroundColor Green