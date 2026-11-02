<#
.SYNOPSIS
    Spusti Admin Console bez IIS, primo pres Kestrel.

.DESCRIPTION
    Aplikace je framework-dependent a nema vlastni .exe; web.config ji v IIS
    stejne jen obaluje (processPath="dotnet"). Pro overeni komunikace tedy IIS
    neni potreba vubec - staci ASP.NET Core 10 Runtime.

    Hodi se na pracovni stanici, kde se role IIS kvuli jednomu testu instalovat
    nevyplati. Pro trvaly provoz je IIS na miste (automaticky start, restart po
    padu, sdruzovani) - na to je Install-Console-Remote.ps1.

    Connection string se predava PROMENNOU PROSTREDI jen tomuto procesu, takze
    heslo nikde na disku nezustane.

    Bezi dokud okno neukoncite (Ctrl+C). Zadne diakritiky ani BOM - skript
    putuje mezi stroji a nesmi na kodovani zaviset.

.EXAMPLE
    .\Start-Console-Standalone.ps1 -SqlServer 192.168.120.128 -SqlPassword 'heslo'
#>
[CmdletBinding()]
param(
    [string] $AppSource = '',
    [Parameter(Mandatory = $true)]
    [string] $SqlServer,
    [string] $SqlLogin  = 'karch_console',
    [Parameter(Mandatory = $true)]
    [string] $SqlPassword,
    [string] $AdminDb   = 'kArchiveManagerAdmin',
    [int]    $Port      = 8089
)

$ErrorActionPreference = 'Stop'

# Aplikace muze lezet bud vedle skriptu (samostatny balicek .\app) nebo
# v klonu repozitare (..\kAM2\02-admin-console\app). Hleda se v tomto poradi.
function Resolve-AppSource {
    param([string] $Hint)
    if ($Hint -and (Test-Path (Join-Path $Hint 'KArchiveManager.AdminConsole.Api.dll'))) { return $Hint }
    $kandidati = @(
        (Join-Path $PSScriptRoot 'app'),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'kAM2\02-admin-console\app')
    )
    foreach ($k in $kandidati) {
        if (Test-Path (Join-Path $k 'KArchiveManager.AdminConsole.Api.dll')) { return $k }
    }
    throw "Aplikace nenalezena. Hledal jsem:`n  " + ($kandidati -join "`n  ") + "`nPredejte cestu parametrem -AppSource."
}
$AppSource = Resolve-AppSource -Hint $AppSource
function Ok($t)   { Write-Host "   OK  $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   !!  $t" -ForegroundColor Yellow }

Write-Host "`n== Kontrola predpokladu" -ForegroundColor Cyan

# --- dotnet a ASP.NET Core 10 ---
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) {
    throw @'
Chybi dotnet. Nainstalujte ASP.NET Core Runtime 10 (NE Hosting Bundle, ten je
pro IIS):  https://dotnet.microsoft.com/download/dotnet/10.0
Staci "ASP.NET Core Runtime" pro Windows x64. Pote otevrete nove okno
PowerShellu, aby se promenna PATH nacetla.
'@
}
$asp = & dotnet --list-runtimes 2>$null | Where-Object { $_ -match 'Microsoft\.AspNetCore\.App 10\.' }
if (-not $asp) {
    $mam = (& dotnet --list-runtimes 2>$null | Where-Object { $_ -match 'Microsoft\.AspNetCore\.App' }) -join '; '
    throw "Chybi ASP.NET Core Runtime 10. Nalezeno: $(if($mam){$mam}else{'nic'}). Aplikace cili na net10.0."
}
Ok ("runtime: " + ($asp | Select-Object -First 1).Trim())

# --- aplikace ---
$dll = Join-Path $AppSource 'KArchiveManager.AdminConsole.Api.dll'
if (-not (Test-Path $dll)) {
    throw "Chybi aplikace: $dll`nSpoustite skript z klonu repozitare? Jinak predejte -AppSource."
}
Ok "aplikace: $dll"

# --- nativni ovladac SqlClientu ---
# NuGet ho uklada do runtimes\win-x64\native\, odkud si ho framework-dependent
# nasazeni samo nenajde. Bez kopie do korene se konzole k databazi nepripoji.
$sniRoot = Join-Path $AppSource 'Microsoft.Data.SqlClient.SNI.dll'
if (-not (Test-Path $sniRoot)) {
    $sniSrc = Join-Path $AppSource 'runtimes\win-x64\native\Microsoft.Data.SqlClient.SNI.dll'
    if (Test-Path $sniSrc) { Copy-Item $sniSrc $sniRoot -Force; Ok 'nativni ovladac zkopirovan do korene' }
    else { Warn 'Microsoft.Data.SqlClient.SNI.dll nenalezen - pripojeni nemusi projit' }
}
else { Ok 'nativni ovladac je v korenu' }

# --- sit a prihlaseni ---
$t = Test-NetConnection -ComputerName $SqlServer -Port 1433 -WarningAction SilentlyContinue
if (-not $t.TcpTestSucceeded) { throw "Na $SqlServer`:1433 se nelze pripojit (firewall nebo SQL nenaslouch? na TCP)." }
Ok 'TCP 1433 odpovida'

$cs = "Server=$SqlServer;Database=$AdminDb;User ID=$SqlLogin;Password=$SqlPassword;TrustServerCertificate=True;Encrypt=True;"
try {
    $cn = New-Object System.Data.SqlClient.SqlConnection ($cs + 'Connect Timeout=10;')
    $cn.Open()
    $c = $cn.CreateCommand()
    $c.CommandText = "SELECT CONCAT(SUSER_SNAME(), ' / ', DB_NAME(), ' / procesu: ', (SELECT COUNT(*) FROM arch.Process))"
    Ok ('prihlaseni proslo: ' + $c.ExecuteScalar())
    $cn.Close()
}
catch { throw "SQL login selhal: $($_.Exception.Message)" }

# --- spusteni ---
Write-Host "`n== Spousteni na http://localhost:$Port" -ForegroundColor Cyan
Write-Host '   (ukoncite klavesami Ctrl+C)' -ForegroundColor DarkGray

# Promenna plati jen pro tento proces, heslo nikde nezustava.
$env:ConnectionStrings__ArchiveManagerAdmin = $cs
$env:ASPNETCORE_ENVIRONMENT = 'Production'

Push-Location $AppSource
try {
    $proc = Start-Process -FilePath $dotnet.Source `
        -ArgumentList @('KArchiveManager.AdminConsole.Api.dll', '--urls', "http://localhost:$Port") `
        -PassThru -NoNewWindow

    # pockat, az naskoci, a overit
    $ok = $false
    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 700
        try {
            $r = Invoke-WebRequest "http://localhost:$Port/health" -UseBasicParsing -TimeoutSec 5
            Write-Host ''
            Ok "/health -> HTTP $($r.StatusCode)  $($r.Content)"
            $ok = $true
            break
        }
        catch { if ($proc.HasExited) { break } }
    }

    if (-not $ok) {
        Warn 'Aplikace neodpovedela do 14 s. Vypis vyse by mel rict proc.'
    }
    else {
        try {
            $rd = Invoke-WebRequest "http://localhost:$Port/api/readiness" -UseBasicParsing -TimeoutSec 10
            $telo = $rd.Content
            if ($telo -match '"databaseOk"\s*:\s*false') {
                Warn "/api/readiness hlasi databaseOk=false - chybi opravneni, ne databaze: $telo"
            }
            else { Ok "/api/readiness -> $telo" }
        }
        catch { Warn "/api/readiness -> $($_.Exception.Message)" }

        Write-Host "`nKonzole bezi: http://localhost:$Port" -ForegroundColor Green
        Write-Host 'Otevrete ji v prohlizeci. Ctrl+C ukonci.' -ForegroundColor Green
    }

    Wait-Process -Id $proc.Id
}
finally {
    Pop-Location
    Remove-Item Env:\ConnectionStrings__ArchiveManagerAdmin -ErrorAction SilentlyContinue
}
