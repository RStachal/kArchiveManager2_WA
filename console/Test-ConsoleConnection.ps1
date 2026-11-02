<#
.SYNOPSIS
    Overi, ze Admin Console na tomto stroji vidi SQL Server a funguje.

.DESCRIPTION
    Projde celou cestu od site az po odpoved API a u kazdeho kroku rekne, co
    presne selhalo. Nic nemeni, jen cte - je bezpecne pustit opakovane.

    Zamerne nepouziva diakritiku ani BOM: skript putuje mezi stroji pres
    schranku, editor i prohlizec, a Windows PowerShell 5.1 cte soubor bez BOM
    jako ANSI, cimz by se diakritika v retezcich rozbila a parser by skoncil.

.EXAMPLE
    .\Test-ConsoleConnection.ps1 -SqlServer 192.168.120.128 -SqlPassword 'heslo'

.EXAMPLE
    # jen webova cast, bez primeho dotazu do SQL
    .\Test-ConsoleConnection.ps1 -SkipSql
#>
[CmdletBinding()]
param(
    [string] $SqlServer,
    [string] $SqlLogin  = 'karch_console',
    [string] $SqlPassword,
    [string] $AdminDb   = 'kArchiveManagerAdmin',
    [int]    $Port      = 8089,
    [string] $AppPoolName = 'kAM Admin Console',
    [switch] $SkipSql
)

$ErrorActionPreference = 'Continue'
$vysledky = New-Object System.Collections.ArrayList

function Zapis($krok, $stav, $detail) {
    $null = $vysledky.Add([pscustomobject]@{ Krok = $krok; Stav = $stav; Detail = $detail })
    $barva = switch ($stav) { 'OK' { 'Green' } 'CHYBA' { 'Red' } default { 'Yellow' } }
    Write-Host ("  {0,-6} {1,-34} {2}" -f $stav, $krok, $detail) -ForegroundColor $barva
}

Write-Host "`n=== Overeni Admin Console na $env:COMPUTERNAME ===`n" -ForegroundColor Cyan

# ---------------------------------------------------------------- 1) IIS
try {
    Import-Module WebAdministration -ErrorAction Stop
    $pool = Get-Item "IIS:\AppPools\$AppPoolName" -ErrorAction Stop
    Zapis 'Aplikacni fond' 'OK' "$AppPoolName, stav $($pool.state)"
    if ($pool.state -ne 'Started') {
        Zapis 'Aplikacni fond' 'POZOR' 'fond nebezi - Start-WebAppPool'
    }
}
catch { Zapis 'Aplikacni fond' 'CHYBA' $_.Exception.Message }

try {
    $ancm = Get-WebGlobalModule -Name 'AspNetCoreModuleV2' -ErrorAction Stop
    if ($ancm) { Zapis 'Hosting Bundle' 'OK' 'AspNetCoreModuleV2 je registrovany' }
}
catch {
    Zapis 'Hosting Bundle' 'CHYBA' 'chybi AspNetCoreModuleV2 -> nainstalovat .NET 10 Hosting Bundle a iisreset'
}

# -------------------------------------------------------- 2) sit na SQL
if ($SqlServer) {
    $t = Test-NetConnection -ComputerName $SqlServer -Port 1433 -WarningAction SilentlyContinue
    if ($t.TcpTestSucceeded) { Zapis 'TCP 1433' 'OK' "$SqlServer odpovida" }
    else { Zapis 'TCP 1433' 'CHYBA' "$SqlServer neodpovida - firewall nebo SQL nenaslouch? na TCP" }
}
else { Zapis 'TCP 1433' 'PRESKOC' 'nezadan -SqlServer' }

# ------------------------------------------------- 3) prihlaseni do SQL
if (-not $SkipSql -and $SqlServer -and $SqlPassword) {
    try {
        $cs = "Server=$SqlServer;Database=$AdminDb;User ID=$SqlLogin;Password=$SqlPassword;" +
              "TrustServerCertificate=True;Encrypt=True;Connect Timeout=10;"
        $cn = New-Object System.Data.SqlClient.SqlConnection $cs
        $cn.Open()
        $cmd = $cn.CreateCommand()
        $cmd.CommandText = "SELECT CONCAT(SUSER_SNAME(), ' / ', DB_NAME(), ' / procesu: ', (SELECT COUNT(*) FROM arch.Process))"
        Zapis 'Prihlaseni do SQL' 'OK' $cmd.ExecuteScalar()

        # tri prava, bez nichz konzole nehlasi chybu, ale vraci nespravne odpovedi
        $cmd.CommandText = @"
SELECT CONCAT(
  'role: ', (SELECT COUNT(*) FROM sys.database_role_members m
             JOIN sys.database_principals r ON r.principal_id = m.role_principal_id
             JOIN sys.database_principals u ON u.principal_id = m.member_principal_id
             WHERE u.name = SUSER_SNAME() AND r.name LIKE 'karch[_]%'),
  ' / DMV: ', CASE WHEN HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW DATABASE PERFORMANCE STATE') = 1
                   THEN 'ano' ELSE 'NE' END)
"@
        $prava = $cmd.ExecuteScalar()
        if ($prava -match 'role: 5' -and $prava -match 'DMV: ano') { Zapis 'Prava uctu' 'OK' $prava }
        else { Zapis 'Prava uctu' 'POZOR' "$prava  (ocekava se role: 5 / DMV: ano -> spustit sql/61)" }

        $cn.Close()
    }
    catch { Zapis 'Prihlaseni do SQL' 'CHYBA' $_.Exception.Message }
}
else { Zapis 'Prihlaseni do SQL' 'PRESKOC' 'nezadano heslo nebo -SkipSql' }

# -------------------------------------------------------- 4) API konzole
$base = "http://localhost:$Port"
foreach ($u in @('/health', '/api/readiness', '/api/dashboard')) {
    try {
        $r = Invoke-WebRequest -Uri ($base + $u) -UseBasicParsing -TimeoutSec 20
        $telo = $r.Content
        if ($telo.Length -gt 160) { $telo = $telo.Substring(0, 160) + '...' }
        if ($telo -match '"databaseOk"\s*:\s*false') {
            Zapis "API $u" 'POZOR' "HTTP $($r.StatusCode), ale databaseOk=false: $telo"
        }
        else { Zapis "API $u" 'OK' "HTTP $($r.StatusCode)  $telo" }
    }
    catch {
        $kod = $_.Exception.Response.StatusCode.value__
        Zapis "API $u" 'CHYBA' ("HTTP $kod " + $_.Exception.Message)
    }
}

# --------------------------------------------------------------- 5) shrnuti
Write-Host ''
$chyb   = ($vysledky | Where-Object Stav -eq 'CHYBA').Count
$pozor  = ($vysledky | Where-Object Stav -eq 'POZOR').Count
if ($chyb -gt 0) {
    Write-Host "Chyb: $chyb, upozorneni: $pozor" -ForegroundColor Red
    Write-Host 'Nejcastejsi priciny:' -ForegroundColor Yellow
    Write-Host '  * chybi .NET 10 Hosting Bundle (aplikace cili na net10.0, ne 8/9) -> doinstalovat, iisreset'
    Write-Host '  * Microsoft.Data.SqlClient.SNI.dll neni v korenu aplikace, jen v runtimes\win-x64\native'
    Write-Host '  * firewall na SQL serveru zavira 1433'
    Write-Host '  * ucet nema vsech pet roli karch_* nebo VIEW DATABASE PERFORMANCE STATE'
    Write-Host "  * podrobnosti: Event Viewer -> Application, zdroj 'IIS AspNetCore Module V2'"
}
elseif ($pozor -gt 0) { Write-Host "Bez chyb, ale $pozor upozorneni - viz vyse." -ForegroundColor Yellow }
else { Write-Host 'Vse proslo. Konzole je pripojena a odpovida.' -ForegroundColor Green }

Write-Host "`nVystup k odeslani:" -ForegroundColor Cyan
$vysledky | Format-Table -AutoSize | Out-String -Width 200
