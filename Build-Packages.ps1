<#
.SYNOPSIS
    Sestavi dva samostatne nasazovaci balicky do dist\.

.DESCRIPTION
    Kazdy balicek obsahuje vse, co je po rozbaleni potreba - zadny dalsi klon
    ani stahovani. Po rozbaleni staci spustit jediny prikaz, viz SPUSTENI.txt
    uvnitr.

      kAM2-Database.zip  databazova cast: skripty, jadro produktu, konfigurace
                         planu Edge, ucty, operator, joby. Nepotrebuje dotnet
                         ani aplikaci konzole - hash hesla operatora pocita
                         PowerShell primo (overeno proti vystupu aplikace).

      kAM2-Console.zip   Admin Console: instalator na IIS v obou rezimech
                         autentizace, spoustec bez IIS, overovaci skript
                         a kompletni aplikace vcetne wwwroot.

    Balicky se overuji: po sestaveni se rozbali do docasne slozky a zkontroluje
    se, ze v nich je vse, na co se skripty odkazuji.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = $PSScriptRoot,
    [string] $OutDir   = (Join-Path $PSScriptRoot 'dist')
)

$ErrorActionPreference = 'Stop'
function Ok($t)   { Write-Host "   OK   $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   !!   $t" -ForegroundColor Yellow }

$stage = Join-Path $env:TEMP ('kam_pkg_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

function Add-Item2 {
    param([string] $Rel, [string] $DestRoot, [string] $As)
    $src = Join-Path $RepoRoot $Rel
    if (-not (Test-Path $src)) { throw "Chybi ve zdroji: $Rel" }
    $dst = Join-Path $DestRoot ($(if ($As) { $As } else { $Rel }))
    $dir = Split-Path $dst -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item $src $dst -Recurse -Force
}

# ======================================================= balicek 1: databaze
Write-Host "`n== Balicek kAM2-Database" -ForegroundColor Cyan
$db = Join-Path $stage 'database'
New-Item -ItemType Directory -Path $db -Force | Out-Null

Add-Item2 'Deploy-Database.ps1'  $db
Add-Item2 'Uninstall-kAM2.ps1'    $db
Add-Item2 'Run-Deploy.ps1'      $db
# cely sql\ - jsou to jen textove skripty a Run-Deploy saha i na dalsi faze
Add-Item2 'sql' $db
# jadro produktu a jeho includy
foreach ($p in @(
        'kAM2\01-database\deploy_clean_v2_full.sql',
        'kAM2\01-database\verify_clean_deploy.sql',
        'kAM2\01-database\selftest_acceptance.sql',
        'kAM2\01-database\variant_test_pack.sql',
        'kAM2\01-database\source-objects',
        'kAM2\01-database\operational-add-ons')) {
    Add-Item2 $p $db
}
Ok ("souboru: " + (Get-ChildItem $db -Recurse -File).Count)

@'
kArchiveManager 2.0 - NASAZENI DATABAZOVE CASTI
================================================

PREDPOKLADY
  * SQL Server 2019 a vys, pristup jako sysadmin
  * sqlcmd (Microsoft Command Line Utilities for SQL Server)
  * dotnet NENI potreba

SPUSTENI (PowerShell jako spravce)

  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
  .\Deploy-Database.ps1 -Server <sql-server> -SourceDb <databaze-wms>

  Nasazeni nanecisto pres existujici (SMAZE obe databaze produktu):
  .\Deploy-Database.ps1 -Server <sql-server> -SourceDb <databaze-wms> -Clean

  Kdyz je zdrojova databaze na compatibility level nizsim nez 130, skript
  skonci a rekne proc. Zvyseni je zasah do WMS databaze, proto se dela jen
  s vyslovnym -RaiseCompatLevel.

CO TO UDELA
  Zalozi obe databaze produktu, nahraje jadro, spusti samotesty, nakonfiguruje
  tri plany WMS Edge (prijmy, vydeje, systemovy log) s retenci 450 dni, zalozi
  archivni tabulky, profily behu, behovy ucet jobu, ucet konzole, operatora
  konzole a pet jobu SQL Agenta. Na konci overi konfiguraci a vypise hesla.

  Zdrojove databaze WMS se NEDOTKNE - jen z ni cte.
  PREP a RUN vznikaji VYPNUTE. Nic se nemaze, dokud to nekdo sam nespusti.

HESLA
  Vypisuji se na konci jedinkrat a nikam se neukladaji. Opiste si je.

POTOM
  Nasadit konzoli balickem kAM2-Console.zip.
'@ | Set-Content (Join-Path $db 'SPUSTENI.txt') -Encoding UTF8

$dbZip = Join-Path $OutDir 'kAM2-Database.zip'
if (Test-Path $dbZip) { Remove-Item $dbZip -Force }
Compress-Archive -Path (Join-Path $db '*') -DestinationPath $dbZip -CompressionLevel Optimal
Ok ("{0} ({1:N1} MB)" -f (Split-Path $dbZip -Leaf), ((Get-Item $dbZip).Length / 1MB))

# ======================================================== balicek 2: konzole
Write-Host "`n== Balicek kAM2-Console" -ForegroundColor Cyan
$co = Join-Path $stage 'console'
New-Item -ItemType Directory -Path $co -Force | Out-Null

foreach ($p in @('console\Deploy-Console.ps1',
                 'console\Start-Console-Standalone.ps1',
                 'console\Test-ConsoleConnection.ps1')) {
    Add-Item2 $p $co -As (Split-Path $p -Leaf)
}
# aplikace jde do .\app, kde si ji skripty najdou samy
Add-Item2 'Uninstall-kAM2.ps1' $co
Add-Item2 'kAM2\02-admin-console\app' $co -As 'app'
if (Test-Path (Join-Path $co 'app\logs')) { Remove-Item (Join-Path $co 'app\logs') -Recurse -Force }
# DEPLOYMENT_SUMMARY.txt generuje publikacni skript, beh aplikace ho nepouziva
# a nese osobni cestu vcetne uzivatelskeho jmena - do balicku pro zakaznika nepatri.
$ds = Join-Path $co 'app\DEPLOYMENT_SUMMARY.txt'
if (Test-Path $ds) { Remove-Item $ds -Force; Ok 'DEPLOYMENT_SUMMARY.txt odstranen (osobni cesta)' }

# Nativni ovladac SqlClientu musi byt v korenu aplikace - NuGet ho uklada do
# runtimes\win-x64\native\, odkud si ho framework-dependent nasazeni nenajde.
$sni = Join-Path $co 'app\Microsoft.Data.SqlClient.SNI.dll'
if (-not (Test-Path $sni)) {
    $src = Join-Path $co 'app\runtimes\win-x64\native\Microsoft.Data.SqlClient.SNI.dll'
    if (Test-Path $src) { Copy-Item $src $sni -Force; Ok 'nativni ovladac doplnen do korene app\' }
    else { Warn 'Microsoft.Data.SqlClient.SNI.dll nenalezen' }
}
else { Ok 'nativni ovladac je v korenu app\' }
Ok ("souboru: " + (Get-ChildItem $co -Recurse -File).Count)

@'
kArchiveManager 2.0 - NASAZENI ADMIN CONSOLE
=============================================

PREDPOKLADY
  * .NET 10 HOSTING BUNDLE (ne jen runtime) - aplikace cili na net10.0,
    runtime 8 ani 9 nestaci:  https://dotnet.microsoft.com/download/dotnet/10.0
    Po instalaci:  iisreset
  * Roli IIS si skript doinstaluje sam prepinacem -InstallIis
  * Databazova cast uz musi byt nasazena (kAM2-Database.zip)

SPUSTENI (PowerShell jako spravce)

  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

  A) Konzole bezi na TEMZE stroji jako SQL Server - DOPORUCENO
     Pripoji se identitou aplikacniho fondu IIS, takze se nikde nespravuje
     zadne heslo:

     .\Deploy-Console.ps1 -AuthMode Windows -SqlServer localhost `
         -SourceDb <databaze-wms> -InstallIis

  B) Konzole bezi JINDE, nebo stroje nejsou v domene
     Pouzije SQL login karch_console s heslem z Deploy-Database.ps1:

     .\Deploy-Console.ps1 -AuthMode SqlLogin -SqlServer <sql-server> `
         -SqlPassword '<heslo karch_console>' -InstallIis

OVERENI
  .\Test-ConsoleConnection.ps1 -SqlServer <sql-server> -SqlPassword '<heslo>'

  Projde fond IIS, AspNetCoreModuleV2, port 1433, skutecne prihlaseni, pet roli
  karch_* i DMV pravo, a nakonec /health, /api/readiness a /api/dashboard.

BEZ IIS (jen na vyzkouseni, ne pro provoz)
  .\Start-Console-Standalone.ps1 -SqlServer <sql-server> -SqlPassword '<heslo>'

  Bezi v popredi okna - zavrenim okna konci, po restartu nenaskoci. Na provoz
  pouzijte IIS.

PRIHLASENI
  Cteni (Dashboard, Analysis, Runs, Document lookup) je anonymni.
  Editaci odemkne uzivatel a heslo operatora z Deploy-Database.ps1.
'@ | Set-Content (Join-Path $co 'SPUSTENI.txt') -Encoding UTF8

$coZip = Join-Path $OutDir 'kAM2-Console.zip'
if (Test-Path $coZip) { Remove-Item $coZip -Force }
Compress-Archive -Path (Join-Path $co '*') -DestinationPath $coZip -CompressionLevel Optimal
Ok ("{0} ({1:N1} MB)" -f (Split-Path $coZip -Leaf), ((Get-Item $coZip).Length / 1MB))

# ================================================================== overeni
Write-Host "`n== Overeni obsahu" -ForegroundColor Cyan
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Test-Zip {
    param([string] $Zip, [string[]] $Musi)
    $a = [IO.Compression.ZipFile]::OpenRead($Zip)
    try { $jmena = $a.Entries.FullName } finally { $a.Dispose() }
    $chybi = @()
    foreach ($m in $Musi) { if (-not ($jmena -contains $m)) { $chybi += $m } }
    if ($chybi) { throw ("V $(Split-Path $Zip -Leaf) chybi:`n  " + ($chybi -join "`n  ")) }
    Ok ("$(Split-Path $Zip -Leaf): vsech $($Musi.Count) klicovych polozek na miste, celkem $($jmena.Count) souboru")
    # heslo se do balicku nesmi dostat
    $a = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($e in $a.Entries | Where-Object { $_.Name -match '\.(ps1|json|txt|sql)$' }) {
            $sr = New-Object IO.StreamReader($e.Open())
            $txt = $sr.ReadToEnd(); $sr.Close()
            if ($txt -match 'Password\s*=\s*[''"][A-Za-z0-9+/=_.#-]{12,}[''"]') {
                throw "V $($e.FullName) vypada neco jako zapsane heslo."
            }
        }
    } finally { $a.Dispose() }
    Ok "$(Split-Path $Zip -Leaf): zadne zapsane heslo"
}

Test-Zip -Zip $dbZip -Musi @(
    'Deploy-Database.ps1', 'Run-Deploy.ps1', 'Uninstall-kAM2.ps1', 'SPUSTENI.txt',
    'sql/01_precheck.sql', 'sql/02_databases.sql', 'sql/56_agent_jobs.sql',
    'sql/60_configure_kmwe_edge.sql', 'sql/61_console_principal_sql_login.sql',
    'kAM2/01-database/deploy_clean_v2_full.sql',
    'kAM2/01-database/verify_clean_deploy.sql',
    'kAM2/01-database/selftest_acceptance.sql',
    'kAM2/01-database/variant_test_pack.sql',
    'kAM2/01-database/operational-add-ons/053_runtime_least_privilege_principal.sql',
    'kAM2/01-database/operational-add-ons/064_console_default_operator.sql')

Test-Zip -Zip $coZip -Musi @(
    'Deploy-Console.ps1', 'Start-Console-Standalone.ps1', 'Test-ConsoleConnection.ps1', 'Uninstall-kAM2.ps1',
    'SPUSTENI.txt',
    'app/KArchiveManager.AdminConsole.Api.dll',
    'app/appsettings.json',
    'app/web.config',
    'app/wwwroot/index.html',
    'app/Microsoft.Data.SqlClient.SNI.dll')

Remove-Item $stage -Recurse -Force
Write-Host "`nHotovo: $OutDir" -ForegroundColor Green
Get-ChildItem $OutDir -Filter *.zip | ForEach-Object { "   {0,-22} {1,8:N1} MB" -f $_.Name, ($_.Length / 1MB) }
