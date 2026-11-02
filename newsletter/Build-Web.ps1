<#
    Ze šablony newsletter.html vyrobí dvě odvozené podoby:

      newsletter_final.html  - pro publikaci (obrázky vložené jako base64)
      print.html             - zdroj pro PDF (obalený do dokumentu + tiskový styl)

    Šablona nese na místě obrázků značky PLACEHOLDER_RFL / _RUNS / _DASH.
    Oba výstupy jsou generované a do gitu nepatří - viz .gitignore.
#>
[CmdletBinding()]
param(
    [string] $Dir = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)

$tpl = Join-Path $Dir 'newsletter.html'
if (-not (Test-Path $tpl)) { throw "Chybi sablona: $tpl" }

$map = [ordered]@{
    'PLACEHOLDER_RFL'  = Join-Path $Dir 'shot_rfl.png'
    'PLACEHOLDER_RUNS' = Join-Path $Dir 'shot_runs.png'
    'PLACEHOLDER_DASH' = Join-Path $Dir 'shot_dash.png'
}

$html = [System.IO.File]::ReadAllText($tpl, $utf8)

foreach ($key in $map.Keys) {
    if ($html -notlike "*$key*") { throw "Sablona neobsahuje znacku $key." }
    if (-not (Test-Path $map[$key])) { throw "Chybi obrazek pro ${key}: $($map[$key])" }
    $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($map[$key]))
    $html = $html.Replace($key, $b64)
}
if ($html -match 'PLACEHOLDER_') { throw 'V generovanem HTML zustala nenahrazena znacka.' }

$finalPath = Join-Path $Dir 'newsletter_final.html'
[System.IO.File]::WriteAllText($finalPath, $html, $utf8)

# --- tiskova verze: doplnit dokumentovy obal a tiskovy styl -------------------
$head = @'
<!doctype html>
<html lang="cs">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
'@

# Tisk se deje bez ohledu na prefers-color-scheme, proto se svetla paleta
# vynucuje natvrdo; zbytek resi strankovani, aby se pres zlom nerozdelil
# obrazek, tabulka, graf ani karta a nadpis nezustal na pate strany.
$printCss = @'
<style>
@page { size: A4; margin: 16mm 15mm 14mm 15mm; }
:root, :root[data-theme="dark"] {
  --paper:#ffffff; --card:#ffffff; --ink:#1b2220; --muted:#55635e; --rule:#d8dedb;
  --source:#0f766e; --archive:#c2700a; --flag:#9a3412; --wash:#eef2f1;
  --brandmark:#002e5a; color-scheme:light;
}
html, body { background:#ffffff !important; }
.wrap { max-width:none; padding-inline:0; padding-block:0 0; }

section { break-inside:auto; page-break-inside:auto; }
h1,h2,h3 { break-after:avoid; page-break-after:avoid; }
figure, .chart, .step, .tile, .stg, .get, .tscroll, table { break-inside:avoid; page-break-inside:avoid; }
tr, .crow, li { break-inside:avoid; page-break-inside:avoid; }
figure img { max-height:150mm; object-fit:contain; }

.mast { break-after:avoid; page-break-after:avoid; }
.foot { break-before:avoid; page-break-before:avoid; }
</style>
</body>
</html>
'@

# Here-string neobsahuje svuj posledni konec radku, proto se doplnuje.
$printPath = Join-Path $Dir 'print.html'
[System.IO.File]::WriteAllText($printPath, ($head + "`r`n" + $html + $printCss + "`r`n"), $utf8)

foreach ($p in @($finalPath, $printPath)) {
    $kb = [math]::Round((Get-Item $p).Length / 1KB, 1)
    Write-Output ("OK: {0}  ({1} KB)" -f $p, $kb)
}
