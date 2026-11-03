<#
.SYNOPSIS
    Sestavi dva PLNE OFFLINE nasazovaci balicky.

.DESCRIPTION
    Urceno pro nasazeni u zakaznika, kde nelze iterovat ani nic stahovat.
    Oproti beznym balickum (Build-Packages.ps1) pridava do konzoloveho balicku
    instalator .NET Hosting Bundle, takze stroj nepotrebuje internet vubec.

      kAM2-Offline-Database.zip   ~0,5 MB
      kAM2-Offline-Console.zip    ~116 MB (z toho 112 MB Hosting Bundle)

    Konzolovy balicek se kvuli te velikosti NEVEJDE do gitu (tvrdy limit
    GitHubu je 100 MB na soubor), proto se neverzuje a predava se na mediu.
    Verzovany je tenhle skript, takze balicek lze kdykoli sestavit znovu.

    Podpis instalatoru se pred zabalenim overuje; nepodepsany nebo poskozeny
    instalator se do balicku nedostane.

.EXAMPLE
    pwsh -File .\Build-OfflinePackages.ps1
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $OutDir,
    [string] $HostingBundle = 'C:\kAMDeploy\installers\dotnet-hosting-10.0.12-win.exe'
)

$ErrorActionPreference = 'Stop'
if (-not $RepoRoot) {
    $RepoRoot = if ($PSScriptRoot) { $PSScriptRoot }
                elseif ($PSCommandPath) { Split-Path $PSCommandPath -Parent }
                else { Split-Path $MyInvocation.MyCommand.Path -Parent }
}
if (-not $OutDir) { $OutDir = Join-Path $RepoRoot 'dist-offline' }

function Ok($t)   { Write-Host "   OK   $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   !!   $t" -ForegroundColor Yellow }

# Compress-Archive ve Windows PowerShellu 5.1 zapisuje v zipu zpetna lomitka,
# cimz vznikne balicek porusujici specifikaci ZIP.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    throw 'Spustte pod PowerShellem 7:  pwsh -File .\Build-OfflinePackages.ps1'
}

$stage = Join-Path $env:TEMP ('kam_off_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

function Pridej {
    param([string] $Rel, [string] $DestRoot, [string] $As)
    $src = Join-Path $RepoRoot $Rel
    if (-not (Test-Path $src)) { throw "Chybi ve zdroji: $Rel" }
    $dst = Join-Path $DestRoot ($(if ($As) { $As } else { $Rel }))
    $dir = Split-Path $dst -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item $src $dst -Recurse -Force
}

# ===================================================== balicek 1: databaze
Write-Host "`n== kAM2-Offline-Database" -ForegroundColor Cyan
$db = Join-Path $stage 'database'
New-Item -ItemType Directory -Path $db -Force | Out-Null
Pridej 'Deploy-Database.ps1'  $db
Pridej 'Uninstall-kAM2.ps1'   $db
Pridej 'Run-Deploy.ps1'       $db
Pridej 'sql'                  $db
foreach ($p in @('kAM2\01-database\deploy_clean_v2_full.sql',
                 'kAM2\01-database\verify_clean_deploy.sql',
                 'kAM2\01-database\selftest_acceptance.sql',
                 'kAM2\01-database\variant_test_pack.sql',
                 'kAM2\01-database\source-objects',
                 'kAM2\01-database\operational-add-ons')) { Pridej $p $db }

$navodDb = @'
kArchiveManager 2.0 - NASAZENI DATABAZOVE CASTI (OFFLINE)
==========================================================

Tento balicek nepotrebuje internet. Staci SQL Server a sqlcmd.

PREDPOKLADY
  * SQL Server 2019 a vys, prihlaseni jako sysadmin
  * sqlcmd (Microsoft Command Line Utilities for SQL Server)
  * dotnet NENI potreba

SPUSTENI (PowerShell jako spravce)
  POZOR: SQLSERVER a KMWE nahradte skutecnymi nazvy. Nepouzivejte zastupne
  zavorky - PowerShell je cte jako presmerovani a prikaz se nespusti.

  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

  Jedno prostredi:
    .\Deploy-Database.ps1 -Server SQLSERVER -SourceDb KMWE -RaiseCompatLevel

  CZ i SK najednou:
    .\Deploy-Database.ps1 -Server SQLSERVER -SourceDb KMWE -AdditionalSourceDbs KMWESK -RaiseCompatLevel

  Nasazeni nanecisto pres existujici (SMAZE obe databaze produktu):
    pridejte -Clean

CO TO UDELA
  Zalozi obe databaze produktu, nahraje jadro, spusti samotesty, nakonfiguruje
  tri plany WMS Edge s retenci 450 dni, zalozi archivni tabulky v oddelenych
  schematech podle zdrojove databaze, profily behu, behovy ucet, ucet konzole,
  operatora konzole a pet jobu SQL Agenta. Nakonec overi konfiguraci.

  Zdrojove databaze WMS se NEDOTKNE - jen z ni cte. Vyjimkou je compatibility
  level, ktery zvysi jen s -RaiseCompatLevel; bez nej skonci a rekne proc.

  PREP a RUN vznikaji VYPNUTE. Nic se nemaze, dokud to nekdo sam nespusti.

HESLA
  Vypisuji se na konci JEDINKRAT a nikam se neukladaji. Opiste si je - heslo
  uctu karch_console budete potrebovat pri nasazeni konzole.

ODINSTALACE
  .\Uninstall-kAM2.ps1 -Part Database -Server SQLSERVER -SourceDb KMWE
  (bez -Apply jen vypise, co by smazal)

POTOM
  Nasadit konzoli balickem kAM2-Offline-Console.zip.
'@
$navodDb | Set-Content (Join-Path $db 'SPUSTENI.txt') -Encoding UTF8

$dbZip = Join-Path $OutDir 'kAM2-Offline-Database.zip'
if (Test-Path $dbZip) { Remove-Item $dbZip -Force }
Compress-Archive -Path (Join-Path $db '*') -DestinationPath $dbZip -CompressionLevel Optimal
Ok ("{0} ({1:N1} MB, {2} souboru)" -f (Split-Path $dbZip -Leaf), ((Get-Item $dbZip).Length / 1MB), (Get-ChildItem $db -Recurse -File).Count)

# ====================================================== balicek 2: konzole
Write-Host "`n== kAM2-Offline-Console" -ForegroundColor Cyan
$co = Join-Path $stage 'console'
New-Item -ItemType Directory -Path $co -Force | Out-Null
foreach ($p in @('console\Deploy-Console.ps1',
                 'console\Start-Console-Standalone.ps1',
                 'console\Test-ConsoleConnection.ps1',
                 'console\Diagnose-Iis.ps1')) { Pridej $p $co -As (Split-Path $p -Leaf) }
Pridej 'Uninstall-kAM2.ps1' $co
Pridej 'kAM2\02-admin-console\app' $co -As 'app'
if (Test-Path (Join-Path $co 'app\logs')) { Remove-Item (Join-Path $co 'app\logs') -Recurse -Force }
$ds = Join-Path $co 'app\DEPLOYMENT_SUMMARY.txt'
if (Test-Path $ds) { Remove-Item $ds -Force }

# NuGet uklada nativni ovladac do runtimes\win-x64\native\, odkud si ho
# framework-dependent nasazeni samo nenajde.
$sni = Join-Path $co 'app\Microsoft.Data.SqlClient.SNI.dll'
if (-not (Test-Path $sni)) {
    $src = Join-Path $co 'app\runtimes\win-x64\native\Microsoft.Data.SqlClient.SNI.dll'
    if (-not (Test-Path $src)) { throw 'Microsoft.Data.SqlClient.SNI.dll nenalezen - konzole by se nepripojila.' }
    Copy-Item $src $sni -Force
}
Ok 'nativni ovladac v korenu app'

if (-not (Test-Path $HostingBundle)) { throw "Chybi instalator Hosting Bundle: $HostingBundle" }
$podpis = Get-AuthenticodeSignature $HostingBundle
if ($podpis.Status -ne 'Valid') { throw "Instalator nema platny podpis (stav: $($podpis.Status)). Do balicku ho nedavam." }
New-Item -ItemType Directory -Path (Join-Path $co 'installers') -Force | Out-Null
Copy-Item $HostingBundle (Join-Path $co 'installers') -Force
Ok ("Hosting Bundle pribalen: {0} ({1:N0} MB, podpis {2})" -f (Split-Path $HostingBundle -Leaf), ((Get-Item $HostingBundle).Length / 1MB), $podpis.Status)

$navodCo = @'
kArchiveManager 2.0 - NASAZENI ADMIN CONSOLE (OFFLINE)
=======================================================

Tento balicek nepotrebuje internet. Instalator .NET Hosting Bundle je uvnitr
ve slozce installers a skript ho v pripade potreby nainstaluje sam.

PREDPOKLADY
  * Databazova cast uz musi byt nasazena (kAM2-Offline-Database.zip)
  * Roli IIS si skript doinstaluje sam prepinacem -InstallIis
    (po prvni instalaci role muze byt nutny restart - skript to rekne)

SPUSTENI (PowerShell jako spravce)
  POZOR: SQLSERVER nahradte skutecnym nazvem nebo IP. Nepouzivejte zastupne
  zavorky - PowerShell je cte jako presmerovani a prikaz se nespusti.

  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

  A) Konzole bezi na TEMZE stroji jako SQL Server - DOPORUCENO
     Pripoji se identitou aplikacniho fondu IIS, takze se nikde nespravuje
     zadne heslo:

     .\Deploy-Console.ps1 -AuthMode Windows -SqlServer localhost -SourceDb KMWE -InstallIis

  B) Konzole bezi JINDE, nebo stroje nejsou v domene
     Skript se na heslo uctu karch_console zepta sam:

     .\Deploy-Console.ps1 -AuthMode SqlLogin -SqlServer SQLSERVER -InstallIis

OVERENI
  .\Test-ConsoleConnection.ps1 -SqlServer SQLSERVER

  Projde fond IIS, modul ASP.NET Core, port 1433, skutecne prihlaseni, pet roli
  karch_ i opravneni pro grafy, a nakonec health, readiness a dashboard.

KDYZ NECO NEJDE
  .\Diagnose-Iis.ps1

  Nic nemeni, jen vypise kompletni obraz: soucasti IIS, klicove knihovny, stav
  sluzeb, vysledek appcmd a presne zneni pripadne vyjimky.

  Zname uskali: na nekterych strojich nefunguje PowerShell provider
  WebAdministration (REGDB_E_CLASSNOTREG), i kdyz IIS sam je v poradku. Skript
  to pozna a prepne na appcmd.exe, takze nasazeni probehne i tak. Opravit se to
  da takto (jako spravce):
    regsvr32 /s %windir%\System32\inetsrv\AppHostNavigators.dll

PRIHLASENI
  Cteni (Dashboard, Analysis, Runs, Document lookup) je anonymni.
  Editaci odemkne uzivatel a heslo operatora z Deploy-Database.ps1.

ODINSTALACE
  .\Uninstall-kAM2.ps1 -Part Console
  (bez -Apply jen vypise, co by smazal)
'@
$navodCo | Set-Content (Join-Path $co 'SPUSTENI.txt') -Encoding UTF8

$coZip = Join-Path $OutDir 'kAM2-Offline-Console.zip'
if (Test-Path $coZip) { Remove-Item $coZip -Force }
Compress-Archive -Path (Join-Path $co '*') -DestinationPath $coZip -CompressionLevel Optimal
Ok ("{0} ({1:N1} MB, {2} souboru)" -f (Split-Path $coZip -Leaf), ((Get-Item $coZip).Length / 1MB), (Get-ChildItem $co -Recurse -File).Count)

# ================================================================= overeni
Write-Host "`n== Overeni obsahu" -ForegroundColor Cyan
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Test-Zip {
    param([string] $Zip, [string[]] $Musi)
    $a = [IO.Compression.ZipFile]::OpenRead($Zip)
    try { $jmena = $a.Entries.FullName } finally { $a.Dispose() }
    $zpetna = @($jmena | Where-Object { $_.Contains('\') })
    if ($zpetna.Count -gt 0) { throw "V $(Split-Path $Zip -Leaf) maji polozky zpetna lomitka - sestavte pod pwsh." }
    $chybi = @($Musi | Where-Object { $jmena -notcontains $_ })
    if ($chybi) { throw ("V $(Split-Path $Zip -Leaf) chybi:`n  " + ($chybi -join "`n  ")) }
    Ok "$(Split-Path $Zip -Leaf): vsech $($Musi.Count) klicovych polozek, celkem $($jmena.Count)"

    $a = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($e in $a.Entries | Where-Object { $_.Name -match '\.(ps1|json|txt|sql)$' }) {
            $sr = New-Object IO.StreamReader($e.Open()); $txt = $sr.ReadToEnd(); $sr.Close()
            if ($txt -match 'Password\s*=\s*[''"][A-Za-z0-9+/=_.#-]{12,}[''"]') { throw "V $($e.FullName) vypada neco jako zapsane heslo." }
            if ($txt -match ([regex]::Escape('Users\') + '[a-z]+' + [regex]::Escape('\'))) { throw "V $($e.FullName) je osobni cesta." }
        }
    } finally { $a.Dispose() }
    Ok "$(Split-Path $Zip -Leaf): zadne zapsane heslo ani osobni cesta"
}

Test-Zip -Zip $dbZip -Musi @(
    'Deploy-Database.ps1', 'Uninstall-kAM2.ps1', 'Run-Deploy.ps1', 'SPUSTENI.txt',
    'sql/01_precheck.sql', 'sql/02_databases.sql', 'sql/56_agent_jobs.sql',
    'sql/60_configure_kmwe_edge.sql', 'sql/61_console_principal_sql_login.sql',
    'sql/62_add_source_database.sql',
    'kAM2/01-database/deploy_clean_v2_full.sql',
    'kAM2/01-database/operational-add-ons/053_runtime_least_privilege_principal.sql',
    'kAM2/01-database/operational-add-ons/064_console_default_operator.sql')

Test-Zip -Zip $coZip -Musi @(
    'Deploy-Console.ps1', 'Start-Console-Standalone.ps1', 'Test-ConsoleConnection.ps1',
    'Diagnose-Iis.ps1', 'Uninstall-kAM2.ps1', 'SPUSTENI.txt',
    'app/KArchiveManager.AdminConsole.Api.dll', 'app/appsettings.json',
    'app/web.config', 'app/wwwroot/index.html', 'app/Microsoft.Data.SqlClient.SNI.dll',
    ('installers/' + (Split-Path $HostingBundle -Leaf)))

Remove-Item $stage -Recurse -Force
Write-Host "`nHotovo: $OutDir" -ForegroundColor Green
Get-ChildItem $OutDir -Filter *.zip | ForEach-Object { "   {0,-30} {1,8:N1} MB" -f $_.Name, ($_.Length / 1MB) }
Write-Host "`nKonzolovy balicek se kvuli velikosti neverzuje - predejte ho na mediu." -ForegroundColor Yellow
