<#
.SYNOPSIS
    Vrati archivovane radky zpet do zdrojovych databazi WMS.

.DESCRIPTION
    Pouziva produktovou proceduru arch.usp_RestoreFromArchive, tedy tutez cestu,
    kterou by sel operator pri skutecne potrebe obnovit doklad. Neni to tedy
    obchvat, ale demonstrace funkce, kterou produkt nabizi.

    Slouzi k vraceni prostredi do stavu pred ostrym behem, aby slo nasazeni
    vyzkouset znovu nad stejnymi daty.

    Bez -Apply probehne NANECISTO: procedura se vola s @DryRun = 1, nic se
    nezapisuje, a skript jen ukaze, kolik radku by se vratilo.

    Archiv se ZACHOVAVA (@PurgeArchive = 0). Radky tak po obnove existuji na
    obou stranach - to je zamerne, protoze mazat archiv ve chvili, kdy jeste
    neni jiste, ze obnova dopadla dobre, by bylo neopatrne. Archiv se stejne
    smaze pri odinstalaci.

    ZAPISUJE DO ZDROJOVE DATABAZE WMS. To je jedina operace v celem balicku,
    ktera to dela, a proto vyzaduje -Apply vyslovne.

    Bez diakritiky a bez BOM - skript putuje mezi stroji.

.EXAMPLE
    .\Rollback-Sources.ps1 -Server localhost -SourceDbs KMWE,KMWESK

.EXAMPLE
    .\Rollback-Sources.ps1 -Server localhost -SourceDbs KMWE,KMWESK -Apply
#>
[CmdletBinding()]
param(
    [string] $Server = 'localhost',
    [Parameter(Mandatory = $true)]
    [string[]] $SourceDbs,
    [string] $ArchiveDb = 'kArchiveManagerBackups',
    [string[]] $Processes = @('RECEIVING', 'SHIPPING', 'RF_LOG2'),
    [int] $MaxRows = 1000000,
    [switch] $PurgeArchive,
    [switch] $Apply
)

$ErrorActionPreference = 'Stop'

# Pri spusteni pres "powershell -File" prijde -SourceDbs KMWE,KMWESK jako JEDEN
# retezec, ne pole. Rozdelime ho proto sami; na normalni volani to nema vliv.
$SourceDbs = @($SourceDbs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Processes = @($Processes | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
function Nadpis($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Ok($t)     { Write-Host "   OK   $t" -ForegroundColor Green }
function Warn($t)   { Write-Host "   !!   $t" -ForegroundColor Yellow }

function Sql {
    param([string] $Query, [string] $Db = 'master')
    $out = & sqlcmd -S $Server -E -b -d $Db -h-1 -W -s'|' -Q $Query 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SQL selhalo v $Db`:`n$($out -join "`n")" }
    return @($out | Where-Object { $_ -match '\S' })
}

# Mapovane tabulky si bereme z konfigurace, ne z pevneho seznamu - jinak by
# skript pri zmene konfigurace pocital neco jineho, nez co se obnovuje.
function Spocitej {
    param([string] $Db)
    # jednodussi a spolehlivejsi: slozit dotaz primo
    $tabulky = Sql -Db 'kArchiveManagerAdmin' -Query @"
SET NOCOUNT ON;
SELECT DISTINCT CONVERT(varchar(80), QUOTENAME(os.SourceSchema) + '.' + QUOTENAME(os.SourceTable))
FROM arch.ObjectSpec os JOIN arch.ProcessDatabase pd ON pd.ProcessId = os.ProcessId
WHERE pd.SourceDb = N'$Db';
"@
    $casti = @($tabulky | ForEach-Object { "(SELECT COUNT_BIG(*) FROM $($_.Trim()))" })
    if ($casti.Count -eq 0) { return 0 }
    $vysledek = Sql -Db $Db -Query ("SET NOCOUNT ON; SELECT CONVERT(varchar(20), " + ($casti -join ' + ') + ");")
    return [int64]("$vysledek".Trim())
}

Write-Host "`n=== Obnova zdrojovych dat z archivu ===" -ForegroundColor White
Write-Host ("    server $Server / prostredi " + ($SourceDbs -join ', ') + " / archiv $ArchiveDb")
if (-not $Apply) { Write-Host '    NANECISTO - nic se nezapisuje. Pro provedeni pridejte -Apply.' -ForegroundColor Yellow }
else { Write-Host '    ZAPISUJE DO ZDROJOVYCH DATABAZI WMS.' -ForegroundColor Yellow }

$pred = @{}
Nadpis 'Stav pred obnovou'
foreach ($db in $SourceDbs) {
    $pred[$db] = Spocitej -Db $db
    $arch = [int64]("$(Sql -Db $ArchiveDb -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(20), ISNULL(SUM(p.rows),0)) FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id JOIN sys.partitions p ON p.object_id=t.object_id AND p.index_id IN (0,1) WHERE s.name = N'$db';")".Trim())
    Write-Host ("   {0,-8} zdroj {1,8:N0}    archiv {2,8:N0}" -f $db, $pred[$db], $arch)
}

Nadpis $(if ($Apply) { 'Obnova' } else { 'Obnova nanecisto' })
foreach ($db in $SourceDbs) {
    foreach ($p in $Processes) {
        $dry = if ($Apply) { 0 } else { 1 }
        $purge = if ($PurgeArchive) { 1 } else { 0 }
        try {
            $r = Sql -Db 'kArchiveManagerAdmin' -Query @"
SET NOCOUNT ON;
EXEC arch.usp_RestoreFromArchive
     @ProcessCode = N'$p', @SourceDb = N'$db', @ArchiveDb = N'$ArchiveDb',
     @DryRun = $dry, @MaxRows = $MaxRows, @PurgeArchive = $purge,
     @RequestedBy = N'rollback';
"@
            $shrnuti = ($r | Select-Object -Last 1)
            Ok ("{0,-8} {1,-10} {2}" -f $db, $p, $shrnuti)
        }
        catch { Warn ("{0,-8} {1,-10} {2}" -f $db, $p, $_.Exception.Message.Split("`n")[0]) }
    }
}

Nadpis 'Stav po obnove'
$vseSedi = $true
foreach ($db in $SourceDbs) {
    $po = Spocitej -Db $db
    $pribylo = $po - $pred[$db]
    Write-Host ("   {0,-8} zdroj {1,8:N0}  ->  {2,8:N0}   pribylo {3,8:N0}" -f $db, $pred[$db], $po, $pribylo)
    if ($Apply -and $pribylo -le 0) { $vseSedi = $false }
}

Write-Host ''
if (-not $Apply) {
    Write-Host 'Nic se nezmenilo. Pro provedeni spustte znovu s -Apply.' -ForegroundColor Yellow
}
elseif ($vseSedi) {
    Write-Host 'Hotovo. Zdrojova data jsou zpet, archiv zustal zachovan.' -ForegroundColor Green
    Write-Host 'Dalsi krok: Uninstall-kAM2.ps1, pak nasazeni z noveho balicku.' -ForegroundColor Green
}
else {
    Write-Host 'Obnova neprinesla ocekavany prirustek - prohlednete si vypis vyse.' -ForegroundColor Red
}
