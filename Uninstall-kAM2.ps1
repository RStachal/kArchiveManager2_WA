<#
.SYNOPSIS
    Odstrani kArchiveManager 2.0 - databazovou cast, konzoli, nebo oboji.

.DESCRIPTION
    Smazat dve databaze produktu NESTACI. Prezije to vic, nez je na prvni
    pohled videt, a cast toho lezi UVNITR zdrojove databaze WMS:

      * serverove loginy karch_runtime_svc a karch_console
      * ve zdrojove databazi WMS: uzivatele karch_*, role karch_runtime
        a opravneni SELECT/DELETE na mapovanych tabulkach
      * v msdb: uzivatele a prava na cteni sysjobs a spol.
      * pet jobu SQL Agenta
      * slozka se zalohami archivni databaze
      * zvyseny compatibility level zdrojove databaze

    Bez -Apply skript jen VYPISE, co by smazal, a nic nezmeni.

    ARCHIV JE PO SMAZANI ZDROJOVEHO RADKU JEDINA KOPIE. Pokud archivni databaze
    obsahuje radky, skript odmitne pokracovat bez -IConfirm a napred vypise,
    kolik jich je.

    Zadna diakritika ani BOM - skript putuje mezi stroji.

.PARAMETER Part
    Database | Console | Both

.PARAMETER RestoreCompatLevel
    Vrati zdrojovou databazi na tuto uroven (napr. 100). Vychozi 0 = nemenit.

.EXAMPLE
    # jen ukazat, co by zmizelo
    .\Uninstall-kAM2.ps1 -Part Both -Server localhost -SourceDb KMWE

.EXAMPLE
    .\Uninstall-kAM2.ps1 -Part Both -Server localhost -SourceDb KMWE -Apply -RestoreCompatLevel 100
#>
[CmdletBinding()]
param(
    [ValidateSet('Database', 'Console', 'Both')]
    [string] $Part        = 'Both',

    [string] $Server      = 'localhost',
    [string] $SourceDb,
    [string[]] $AdditionalSourceDbs = @(),
    [string] $AdminDb     = 'kArchiveManagerAdmin',
    [string] $ArchiveDb   = 'kArchiveManagerBackups',
    [string[]] $Logins    = @('karch_runtime_svc', 'karch_console'),
    [int]    $RestoreCompatLevel = 0,

    [string] $SitePath    = 'C:\inetpub\kArchiveManager\AdminConsole',
    [string] $AppPoolName = 'kAM Admin Console',
    [string] $SiteName    = 'kAM Admin Console',
    [int]    $Port        = 8089,

    [switch] $Apply,
    [switch] $IConfirm
)

$ErrorActionPreference = 'Stop'

# Pri spusteni pres "powershell -File" prijde pole jako jediny retezec.
$AdditionalSourceDbs = @($AdditionalSourceDbs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
function Nadpis($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Zmena($t)  { if ($Apply) { Write-Host "   SMAZANO  $t" -ForegroundColor Green } else { Write-Host "   smazal by: $t" -ForegroundColor Yellow } }
function Info($t)   { Write-Host "   -        $t" -ForegroundColor DarkGray }
function Warn($t)   { Write-Host "   !!       $t" -ForegroundColor Yellow }

# IIS se NESMI detekovat pres Get-Module -ListAvailable: modul WebAdministration
# vyzaduje elevaci, takze bez prav spravce vrati nulu i na stroji, kde IIS je.
# Autoritativni je pritomnost appcmd.exe, ta zadnou elevaci nepotrebuje.
function Test-IisInstalled {
    return (Test-Path (Join-Path $env:windir 'System32\inetsrv\appcmd.exe'))
}

function Sql {
    param([string] $Query, [string] $Db = 'master')
    $out = & sqlcmd -S $Server -E -b -d $Db -h-1 -W -s'|' -Q $Query 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SQL selhalo v $Db`:`n$($out -join "`n")" }
    return @($out | Where-Object { $_ -match '\S' })
}

Write-Host "`n=== Odinstalace kArchiveManager 2.0 ===" -ForegroundColor White
Write-Host "    cast $Part / server $Server$(if ($SourceDb) { " / zdroj $SourceDb" })"
if (-not $Apply) { Write-Host "    NAHLED - nic se nemeni. Pro provedeni pridejte -Apply." -ForegroundColor Yellow }

# ======================================================= KONZOLE
if ($Part -in @('Console', 'Both')) {
    Nadpis 'Konzole'

    $jeSpravce = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                 ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($Apply -and -not $jeSpravce) { throw 'Pro -Apply na konzoli spustte jako spravce.' }

    # a) IIS - jen kdyz je vubec nainstalovany
    if ((Test-IisInstalled) -and -not $jeSpravce) {
        Warn 'IIS je nainstalovany, ale modul WebAdministration vyzaduje elevaci - cast IIS preskakuji.'
        Warn 'Pro uklid IIS spustte jako spravce.'
    }
    elseif (Test-IisInstalled) {
        Import-Module WebAdministration
        if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) {
            Zmena "web IIS '$SiteName'"
            if ($Apply) { Stop-Website -Name $SiteName -ErrorAction SilentlyContinue; Remove-Website -Name $SiteName }
        }
        else { Info "web IIS '$SiteName' neexistuje" }

        if (Test-Path "IIS:\AppPools\$AppPoolName") {
            Zmena "aplikacni fond '$AppPoolName' (vcetne promenne s connection stringem)"
            if ($Apply) {
                Stop-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                Remove-WebAppPool -Name $AppPoolName
            }
        }
        else { Info "aplikacni fond '$AppPoolName' neexistuje" }
    }
    else { Info 'IIS neni nainstalovany (appcmd.exe nenalezen) - konzole bezela pres Kestrel' }

    # b) proces Kestrelu, pokud bezi
    $beziciho = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($beziciho) {
        $pids = $beziciho.OwningProcess | Sort-Object -Unique
        foreach ($procId in $pids) {
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -eq 'dotnet') {
                Zmena "bezici proces dotnet na portu $Port (PID $procId)"
                if ($Apply) { Stop-Process -Id $procId -Force }
            }
            elseif ($p) { Warn "port $Port drzi $($p.ProcessName) (PID $procId) - nechavam byt" }
        }
    }
    else { Info "na portu $Port nic neposloucha" }

    # c) soubory vcetne odlozenych zaloh
    foreach ($d in @($SitePath) + @(Get-Item "$SitePath.bak-*" -ErrorAction SilentlyContinue | Select-Object -Expand FullName)) {
        if ($d -and (Test-Path $d)) {
            Zmena "slozka $d"
            if ($Apply) { Remove-Item $d -Recurse -Force }
        }
    }
    if (-not (Test-Path $SitePath)) { Info "slozka $SitePath neexistuje" }
}

# ======================================================= DATABAZE
if ($Part -in @('Database', 'Both')) {
    Nadpis 'Joby SQL Agenta'
    $joby = Sql -Db msdb -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(60), name) FROM dbo.sysjobs WHERE name LIKE 'kArchiveManager%' ORDER BY name;"
    if ($joby) {
        foreach ($j in $joby) {
            Zmena "job '$($j.Trim())'"
            if ($Apply) { $null = Sql -Db msdb -Query "EXEC dbo.sp_delete_job @job_name = N'$($j.Trim())';" }
        }
    }
    else { Info 'zadne joby kArchiveManager' }

    Nadpis 'Databaze produktu'
    # Archiv je jedina kopie - nejdriv spocitat, co by zmizelo
    $radky = '0'
    if (("$(Sql -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(5), COUNT(*)) FROM sys.databases WHERE name = N'$ArchiveDb';")").Trim() -eq '1') {
        $radky = ("$(Sql -Db $ArchiveDb -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(20), ISNULL(SUM(p.rows),0)) FROM sys.tables t JOIN sys.partitions p ON p.object_id=t.object_id AND p.index_id IN (0,1);")").Trim()
        Write-Host "   v archivu $ArchiveDb je radku: $radky"
        if ([int64]$radky -gt 0 -and $Apply -and -not $IConfirm) {
            throw "Archiv obsahuje $radky archivovanych radku. Po smazani uz nikde nejsou - potvrdte prepinacem -IConfirm."
        }
    }
    foreach ($d in @($AdminDb, $ArchiveDb)) {
        if (("$(Sql -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(5), COUNT(*)) FROM sys.databases WHERE name = N'$d';")").Trim() -eq '1') {
            Zmena "databaze $d"
            if ($Apply) { $null = Sql -Query "ALTER DATABASE [$d] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$d];" }
        }
        else { Info "databaze $d neexistuje" }
    }

    # Tohle je to, co se pri rucnim uklidu prehlizi: uzivatele a role zustavaji
    # UVNITR zdrojove databaze WMS i po smazani databazi produktu.
    foreach ($db in @($SourceDb) + $AdditionalSourceDbs) {
        if (-not $db) { continue }
        Nadpis "Stopy ve zdrojove databazi $db"
        $zbytky = Sql -Db $db -Query @"
SET NOCOUNT ON;
SELECT CONVERT(varchar(10), CASE WHEN type = 'R' THEN 'role' ELSE 'uzivatel' END) + '|' + CONVERT(varchar(30), name)
FROM sys.database_principals
WHERE name LIKE 'karch%' AND type IN ('S','U','E','X','R')
ORDER BY CASE WHEN type = 'R' THEN 2 ELSE 1 END, name;
"@
        if ($zbytky) {
            foreach ($z in $zbytky) {
                $cast = $z.Trim() -split '\|'
                Zmena "$db`: $($cast[0]) $($cast[1])"
            }
            if ($Apply) {
                # uzivatele napred, role az po nich (role nejde smazat s cleny)
                $null = Sql -Db $db -Query @"
DECLARE @sql nvarchar(max) = N'';
SELECT @sql += N'DROP USER ' + QUOTENAME(name) + N';'
  FROM sys.database_principals WHERE name LIKE 'karch%' AND type IN ('S','U','E','X');
SELECT @sql += N'DROP ROLE ' + QUOTENAME(name) + N';'
  FROM sys.database_principals WHERE name LIKE 'karch%' AND type = 'R';
IF @sql <> N'' EXEC sys.sp_executesql @sql;
"@
            }
        }
        else { Info "ve zdrojove databazi $db nic nezbylo" }

        if ($RestoreCompatLevel -gt 0) {
            $nyni = ("$(Sql -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(5), compatibility_level) FROM sys.databases WHERE name = N'$db';")").Trim()
            if ($nyni -ne "$RestoreCompatLevel") {
                Zmena "$db`: compatibility level $nyni -> $RestoreCompatLevel"
                if ($Apply) { $null = Sql -Query "ALTER DATABASE [$db] SET COMPATIBILITY_LEVEL = $RestoreCompatLevel;" }
            }
            else { Info "$db uz je na compatibility level $RestoreCompatLevel" }
        }
        else { Info 'compatibility level se nemeni (pouzijte -RestoreCompatLevel)' }
    }
    if (-not $SourceDb) { Warn 'bez -SourceDb nelze uklidit stopy ve zdrojove databazi WMS' }

    Nadpis 'msdb'
    $mu = Sql -Db msdb -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(40), name) FROM sys.database_principals WHERE name LIKE 'karch%' AND type IN ('S','U','E','X');"
    if ($mu) {
        foreach ($u in $mu) {
            Zmena "msdb: uzivatel $($u.Trim())"
            if ($Apply) { $null = Sql -Db msdb -Query "DROP USER [$($u.Trim())];" }
        }
    }
    else { Info 'v msdb nic nezbylo' }

    Nadpis 'Serverove loginy'
    foreach ($l in $Logins) {
        if (("$(Sql -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(5), COUNT(*)) FROM sys.server_principals WHERE name = N'$l';")").Trim() -eq '1') {
            Zmena "login $l"
            if ($Apply) { $null = Sql -Query "DROP LOGIN [$l];" }
        }
        else { Info "login $l neexistuje" }
    }

    Nadpis 'Zalohy archivni databaze'
    $bp = ("$(Sql -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(400), SERVERPROPERTY('InstanceDefaultBackupPath'));")").Trim()
    $bd = Join-Path $bp $ArchiveDb
    if (Test-Path $bd) {
        $n = (Get-ChildItem $bd -File -ErrorAction SilentlyContinue).Count
        Zmena "slozka se zalohami $bd ($n souboru)"
        if ($Apply) { Remove-Item $bd -Recurse -Force }
    }
    else { Info "slozka se zalohami $bd neexistuje" }
}

Write-Host ''
if ($Apply) { Write-Host 'Hotovo. Prostredi je pripravene na nasazeni nanecisto.' -ForegroundColor Green }
else { Write-Host 'Nic se nezmenilo. Pro provedeni spustte znovu s -Apply.' -ForegroundColor Yellow }
