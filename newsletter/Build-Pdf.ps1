<#
    Vyrobí PDF přílohu z tiskové verze newsletteru (print.html).

    Tiskne se bohatší webová verze, ne tělo e-mailu: má skutečné fonty a
    působí jako dokument. print.html = newsletter_final.html + tiskový styl
    (A4, vynucená světlá paleta, pravidla proti dělení prvků přes zlom).

    Renderuje headless Edge; jiný prohlížeč ani tiskárna nejsou potřeba.
#>
[CmdletBinding()]
param(
    [string] $Dir     = $PSScriptRoot,
    [string] $Source  = 'print.html',
    [string] $OutFile = 'kArchiveManager-2.0-newsletter.pdf'
)

$ErrorActionPreference = 'Stop'

# Pozor: nazev promenne obsahuje zavorky, musi byt v ${...}, jinak PowerShell
# precte jen $env:ProgramFiles a "(x86)" vezme jako text.
$edge = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $env:ProgramFiles        'Microsoft\Edge\Application\msedge.exe')
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $edge) { throw 'msedge.exe nenalezen - PDF renderuje headless Edge.' }

$src = Join-Path $Dir $Source
if (-not (Test-Path $src)) { throw "Chybi zdroj pro tisk: $src" }
$dst = Join-Path $Dir $OutFile
if (Test-Path $dst) { Remove-Item $dst -Force }

$uri = ([uri](Resolve-Path $src).Path).AbsoluteUri

# Start-Process schvalne: Edge si pise neskodna varovani na stderr a volani
# pres "&" s presmerovanim by je v PowerShellu 5.1 povysilo na chybu.
$args = @(
    '--headless=new', '--disable-gpu', '--no-sandbox',
    '--no-pdf-header-footer', '--virtual-time-budget=15000',
    "--print-to-pdf=$dst", $uri
)
Start-Process -FilePath $edge -ArgumentList $args -Wait -NoNewWindow | Out-Null

if (-not (Test-Path $dst)) { throw 'Edge PDF nevytvoril.' }

# Zakladni kontrola vystupu: je to PDF a ma vic nez jednu stranku?
$bytes = [System.IO.File]::ReadAllBytes($dst)
$head  = [System.Text.Encoding]::ASCII.GetString($bytes, 0, 8)
if ($head -notlike '%PDF-*') { throw "Vystup neni PDF (zacina '$head')." }
$text  = [System.Text.Encoding]::ASCII.GetString($bytes)
$pages = ([regex]::Matches($text, '/Type\s*/Page[^s]')).Count
if ($pages -lt 2) { throw "PDF ma jen $pages stranku - render pravdepodobne selhal." }

$kb = [math]::Round((Get-Item $dst).Length / 1KB, 1)
Write-Output "OK: $dst  ($kb KB, $pages stran)"
