# fix_encoding_utf8.ps1
# Convierte .html/.css con mojibake (CP1252) a UTF-8 (sin BOM)

$ErrorActionPreference = "Stop"

$enc1252   = [System.Text.Encoding]::GetEncoding(1252)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)  # UTF-8 sin BOM

# Archivos objetivo
$targets = @()
if (Test-Path templates) { $targets += Get-ChildItem -Recurse -Path templates -File -Include *.html }
if (Test-Path static)    { $targets += Get-ChildItem -Recurse -Path static    -File -Include *.css  }

foreach ($f in $targets) {
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
  $text  = $enc1252.GetString($bytes)

  # Mojibake típico: caracteres U+00C3 ('Ã') o U+00C2 ('Â')
  $hasMojibake = ($text.IndexOf([char]0x00C3) -ge 0) -or ($text.IndexOf([char]0x00C2) -ge 0)

  if ($hasMojibake) {
    [System.IO.File]::WriteAllText($f.FullName, $text, $utf8NoBom)
    Write-Host "Convertido -> UTF-8:" $f.FullName
  } else {
    Write-Host "Sin cambios:" $f.FullName
  }
}

Write-Host "Listo. Reinicia la app y fuerza refresh (Ctrl+F5)." -ForegroundColor Green