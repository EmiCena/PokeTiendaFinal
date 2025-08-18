# fix_encoding_safe.ps1
# Transcodifica archivos .html y .css de CP1252 a UTF-8 (sin BOM)
# Evita letras problemáticas usando códigos Unicode.

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Text

$enc1252   = [System.Text.Encoding]::GetEncoding(1252)
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)  # UTF-8 sin BOM

# Archivos objetivo
$targets = @()
if (Test-Path templates) { $targets += Get-ChildItem -Recurse -Path templates -Include *.html }
if (Test-Path static)    { $targets += Get-ChildItem -Recurse -Path static    -Include *.css  }

foreach ($f in $targets) {
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)

  # Interpretar como CP1252
  $text = $enc1252.GetString($bytes)

  # Heurística de mojibake: presencia de U+00C3 ('Ã') o U+00C2 ('Â')
  $hasMojibake = ($text.IndexOf([char]0x00C3) -ge 0) -or ($text.IndexOf([char]0x00C2) -ge 0)

  if ($hasMojibake) {
    [System.IO.File]::WriteAllText($f.FullName, $text, $utf8NoBom)
    Write-Host "Convertido -> UTF-8:" $f.FullName
  } else {
    Write-Host "Sin cambios:" $f.FullName
  }
}

Write-Host "Listo. Reinicia la app y forza refresh del navegador (Ctrl+F5)." -ForegroundColor Green