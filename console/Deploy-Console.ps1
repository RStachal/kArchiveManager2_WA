<#
.SYNOPSIS
    Nasadi Admin Console na IIS jednim krokem, vcetne role IIS a prav.

.DESCRIPTION
    Spoji do jedne sekvence vse, co se jinak dela rucne: doinstaluje chybejici
    roli IIS, overi .NET 10 Hosting Bundle, nasadi soubory aplikace, vyresi
    nativni ovladac SqlClientu, zalozi aplikacni fond a web, pridel? opravneni
    a nakonec overi, ze konzole skutecne odpovida.

    DVA REZIMY AUTENTIZACE:

      -AuthMode Windows   konzole bezi na TEMZE stroji jako SQL Server. Pripoji
                          se identitou aplikacniho fondu IIS, takze se nikde
                          nespravuje zadne heslo. Skript sam zalozi login pro
                          "IIS APPPOOL\<fond>" a pridel? mu pet roli karch_*,
                          cteni v archivu i zdroji, cteni msdb a DMV pravo.
                          BEZPECNEJSI - preferujte ho, kdyz to topologie dovoli.

      -AuthMode SqlLogin  konzole bezi JINDE nez SQL Server, nebo stroje nejsou
                          v domene. Pouzije SQL login (prava mu pridelil uz
                          Deploy-Database.ps1) a heslo ulozi do promenne
                          prostredi aplikacniho fondu, ne do souboru na disku.

    Bez diakritiky a bez BOM - skript putuje mezi stroji a Windows PowerShell
    5.1 cte soubor bez BOM jako ANSI, cimz by se diakritika v retezcich
    rozbila a parser by skoncil.

.EXAMPLE
    # konzole na databazovem stroji - nejjednodussi a nejbezpecnejsi
    .\Deploy-Console.ps1 -AuthMode Windows -SqlServer localhost -SourceDb KMWE

.EXAMPLE
    # konzole na jinem stroji
    .\Deploy-Console.ps1 -AuthMode SqlLogin -SqlServer 192.168.1.10
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Windows', 'SqlLogin')]
    [string] $AuthMode,
    [Parameter(Mandatory = $true)] [string] $SqlServer,
    [string] $AdminDb     = 'kArchiveManagerAdmin',
    [string] $ArchiveDb   = 'kArchiveManagerBackups',
    [string] $SourceDb,                                   # jen pro -AuthMode Windows
    [string] $SqlLogin    = 'karch_console',
    [string] $SqlPassword,                                # jen pro -AuthMode SqlLogin
    [string] $AppSource   = '',
    [string] $SitePath    = 'C:\inetpub\kArchiveManager\AdminConsole',
    [string] $AppPoolName = 'kAM Admin Console',
    [string] $SiteName    = 'kAM Admin Console',
    [int]    $Port        = 8089,
    [switch] $InstallIis
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
$krok = 0
function Nadpis($t) { $script:krok++; Write-Host "`n== $script:krok) $t" -ForegroundColor Cyan }
function Ok($t)     { Write-Host "   OK   $t" -ForegroundColor Green }
function Warn($t)   { Write-Host "   !!   $t" -ForegroundColor Yellow }

# IIS se NESMI detekovat pres Get-Module -ListAvailable: modul WebAdministration
# vyzaduje elevaci, takze bez prav spravce vrati nulu i na stroji, kde IIS je.
# Autoritativni je pritomnost appcmd.exe, ta zadnou elevaci nepotrebuje.
function Test-IisInstalled {
    return (Test-Path (Join-Path $env:windir 'System32\inetsrv\appcmd.exe'))
}

# Heslo radeji dotazem nez parametrem: v prikazove radce by zustalo v historii
# PowerShellu, a pri vkladani navodu se snadno zkomoli (zastupne <zavorky> navic
# PowerShell cte jako presmerovani a prikaz se vubec nespusti).
if ($AuthMode -eq 'SqlLogin' -and -not $SqlPassword) {
    $sec = Read-Host -Prompt 'Heslo uctu karch_console (z vypisu Deploy-Database.ps1)' -AsSecureString
    $SqlPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    if (-not $SqlPassword) { throw 'Heslo nezadano.' }
}
if ($AuthMode -eq 'Windows'  -and -not $SourceDb)    { throw 'Pro -AuthMode Windows je nutny -SourceDb (prideluje se na nem cteni).' }

Write-Host "`n=== Admin Console - nasazeni na $env:COMPUTERNAME ===" -ForegroundColor White
Write-Host "    rezim $AuthMode / SQL $SqlServer / port $Port"

# ---------------------------------------------------------------- 1) spravce
Nadpis 'Predpoklady'
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Spustte jako spravce - IIS, ACL i zalozeni loginu to vyzaduji.'
}
Ok 'bezi jako spravce'

# ------------------------------------------------------------------- 2) IIS
Nadpis 'Role IIS'
if (-not (Test-IisInstalled)) {
    if (-not $InstallIis) {
        throw @'
Role IIS neni nainstalovana. Spustte znovu s -InstallIis, nebo ji doinstalujte rucne:
  Windows Server:  Install-WindowsFeature -Name Web-Server, Web-Mgmt-Console -IncludeManagementTools
  Windows 10/11:   Enable-WindowsOptionalFeature -Online -All -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-ManagementConsole
Po instalaci muze byt nutny restart.
'@
    }
    Warn 'instaluji roli IIS - muze to trvat nekolik minut'
    # Serverove a klientske Windows to delaji jinak
    if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) {
        Enable-WindowsOptionalFeature -Online -All -NoRestart `
            -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-ManagementConsole | Out-Null
    }
    else {
        Install-WindowsFeature -Name Web-Server, Web-Mgmt-Console -IncludeManagementTools | Out-Null
    }
    if (-not (Test-IisInstalled)) {
        throw 'Role IIS se nainstalovala, ale modul WebAdministration zatim neni k dispozici. Restartujte stroj a spustte skript znovu.'
    }
    Ok 'role IIS nainstalovana'
}
Import-Module WebAdministration
Ok 'modul WebAdministration'

# Aplikace cili na net10.0. Runtime 8 ani 9 nestaci, prestoze to dodavany
# handover README tvrdi. AspNetCoreModuleV2 je jediny spolehlivy ukazatel.
if (-not (Get-WebGlobalModule -Name 'AspNetCoreModuleV2' -ErrorAction SilentlyContinue)) {
    throw @'
Chybi AspNetCoreModuleV2 - neni nainstalovany ASP.NET Core Hosting Bundle.
Aplikace cili na net10.0, takze je potreba .NET 10 HOSTING BUNDLE (ne jen runtime):
  https://dotnet.microsoft.com/download/dotnet/10.0
Po instalaci spustte: iisreset
'@
}
Ok 'Hosting Bundle (AspNetCoreModuleV2)'

# -------------------------------------------------------------- 3) spojeni
Nadpis "Dostupnost SQL Serveru $SqlServer"
$t = Test-NetConnection -ComputerName $SqlServer -Port 1433 -WarningAction SilentlyContinue
if (-not $t.TcpTestSucceeded) { throw "Na $SqlServer`:1433 se nelze pripojit - firewall, nebo SQL nenaslouch? na TCP." }
Ok 'TCP 1433 odpovida'

$csBase = "Server=$SqlServer;Database=$AdminDb;TrustServerCertificate=True;Encrypt=True;"
$cs = if ($AuthMode -eq 'Windows') { $csBase + 'Trusted_Connection=True;' }
      else { $csBase + "User ID=$SqlLogin;Password=$SqlPassword;" }

if ($AuthMode -eq 'SqlLogin') {
    try {
        $cn = New-Object System.Data.SqlClient.SqlConnection ($cs + 'Connect Timeout=10;')
        $cn.Open()
        $c = $cn.CreateCommand()
        $c.CommandText = "SELECT CONCAT(SUSER_SNAME(), ' / ', DB_NAME(), ' / procesu: ', (SELECT COUNT(*) FROM arch.Process))"
        Ok ('prihlaseni proslo: ' + $c.ExecuteScalar())
        $cn.Close()
    }
    catch { throw "SQL login selhal: $($_.Exception.Message)" }
}

# ----------------------------------------------------------- 4) soubory
Nadpis 'Soubory aplikace'
$dll = Join-Path $AppSource 'KArchiveManager.AdminConsole.Api.dll'
if (-not (Test-Path $dll)) { throw "Chybi aplikace: $dll`nSpoustite skript z klonu repozitare? Jinak predejte -AppSource." }

if (Test-Path $SitePath) {
    $bak = "$SitePath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Warn "cil existuje - odkladam do $bak"
    if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) { Stop-Website -Name $SiteName -ErrorAction SilentlyContinue }
    if (Test-Path "IIS:\AppPools\$AppPoolName") { Stop-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
    Move-Item $SitePath $bak
}
New-Item -ItemType Directory -Path $SitePath -Force | Out-Null
Copy-Item (Join-Path $AppSource '*') $SitePath -Recurse -Force
if (Test-Path (Join-Path $SitePath 'logs')) { Remove-Item (Join-Path $SitePath 'logs') -Recurse -Force }
Ok ("souboru: " + (Get-ChildItem $SitePath -Recurse -File).Count)

# NuGet uklada nativni ovladac do runtimes\win-x64\native\, odkud si ho
# framework-dependent nasazeni samo nenajde. Bez kopie v korenu se konzole
# k databazi nepripoji.
$sni = Join-Path $SitePath 'Microsoft.Data.SqlClient.SNI.dll'
if (-not (Test-Path $sni)) {
    $src = Join-Path $SitePath 'runtimes\win-x64\native\Microsoft.Data.SqlClient.SNI.dll'
    if (Test-Path $src) { Copy-Item $src $sni -Force; Ok 'nativni ovladac zkopirovan do korene' }
    else { Warn 'Microsoft.Data.SqlClient.SNI.dll nenalezen - pripojeni nemusi projit' }
}
else { Ok 'nativni ovladac je v korenu' }

# ----------------------------------------------------------- 5) konfigurace
Nadpis 'Konfigurace'
$appsettings = Join-Path $SitePath 'appsettings.json'
$cfgObj = Get-Content $appsettings -Raw | ConvertFrom-Json
# Heslo se do souboru nezapisuje nikdy - nese ho promenna prostredi fondu.
$cfgObj.ConnectionStrings.ArchiveManagerAdmin = if ($AuthMode -eq 'Windows') { $cs } else { '' }
$cfgObj.AdminConsole.WindowsAuthEnabled = $false      # prihlaseni resi operatori v databazi
$cfgObj.AdminConsole.DbOperatorsEnabled = $true
$cfgObj | ConvertTo-Json -Depth 10 | Set-Content $appsettings -Encoding UTF8
Ok 'appsettings.json'

# --------------------------------------------------------------- 6) IIS
Nadpis 'Aplikacni fond a web'
if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) { New-WebAppPool -Name $AppPoolName | Out-Null }
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name managedRuntimeVersion       -Value ''              # No Managed Code
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name startMode                   -Value 'AlwaysRunning'
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.identityType   -Value 'ApplicationPoolIdentity'
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.idleTimeout    -Value '00:00:00'
Ok "fond '$AppPoolName' (No Managed Code, AlwaysRunning)"

if ($AuthMode -eq 'SqlLogin') {
    Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter "system.applicationHost/applicationPools/add[@name='$AppPoolName']/environmentVariables" `
        -Name '.' -AtElement @{name = 'ConnectionStrings__ArchiveManagerAdmin' } -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter "system.applicationHost/applicationPools/add[@name='$AppPoolName']/environmentVariables" `
        -Name '.' -Value @{name = 'ConnectionStrings__ArchiveManagerAdmin'; value = $cs }
    Ok 'connection string v promenne prostredi fondu (heslo neni na disku)'
}

if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) { Remove-Website -Name $SiteName }
New-Website -Name $SiteName -Port $Port -PhysicalPath $SitePath -ApplicationPool $AppPoolName | Out-Null
Ok "web '$SiteName' na portu $Port"

$identita = "IIS AppPool\$AppPoolName"
$acl = Get-Acl $SitePath
$acl.SetAccessRule((New-Object Security.AccessControl.FileSystemAccessRule(
            $identita, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl $SitePath $acl
Ok "ACL pro $identita"

# ------------------------------------------- 7) prava identite fondu v SQL
if ($AuthMode -eq 'Windows') {
    Nadpis 'Opravneni identite aplikacniho fondu'
    # Pet roli, ne pouhy karch_viewer: pri nedostatecnych pravech konzole
    # NEHLASI chybu, ale vraci nespravne odpovedi (nuly v grafech, prazdne
    # panely, "databaze v poradku: ne" bez jedine chybejici polozky).
    # karch_runtime se ZAMERNE neprideluje - to je role behoveho uctu.
    $q = @"
DECLARE @l sysname = N'$identita';
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @l)
    EXEC('CREATE LOGIN ' + QUOTENAME(@l) + ' FROM WINDOWS;');

DECLARE @sql nvarchar(max) = N'USE [$AdminDb];'
 + N'IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''' + @l + N''') CREATE USER ' + QUOTENAME(@l) + N' FOR LOGIN ' + QUOTENAME(@l) + N';'
 + N'ALTER ROLE karch_viewer         ADD MEMBER ' + QUOTENAME(@l) + N';'
 + N'ALTER ROLE karch_operator       ADD MEMBER ' + QUOTENAME(@l) + N';'
 + N'ALTER ROLE karch_config_admin   ADD MEMBER ' + QUOTENAME(@l) + N';'
 + N'ALTER ROLE karch_advanced_admin ADD MEMBER ' + QUOTENAME(@l) + N';'
 + N'ALTER ROLE karch_approver       ADD MEMBER ' + QUOTENAME(@l) + N';'
 + N'GRANT VIEW DATABASE PERFORMANCE STATE TO ' + QUOTENAME(@l) + N';';
EXEC sys.sp_executesql @sql;

-- archiv a zdroj: pouze cteni
DECLARE @db sysname, @c CURSOR;
SET @c = CURSOR FOR SELECT N'$ArchiveDb' UNION ALL SELECT N'$SourceDb';
OPEN @c; FETCH NEXT FROM @c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'USE ' + QUOTENAME(@db) + N';'
     + N'IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''' + @l + N''') CREATE USER ' + QUOTENAME(@l) + N' FOR LOGIN ' + QUOTENAME(@l) + N';'
     + N'ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@l) + N';'
     + N'GRANT VIEW DATABASE PERFORMANCE STATE TO ' + QUOTENAME(@l) + N';';
    EXEC sys.sp_executesql @sql;
    FETCH NEXT FROM @c INTO @db;
END
CLOSE @c; DEALLOCATE @c;

-- msdb: go-live kontrola cte sysjobs a spol.
SET @sql = N'USE msdb;'
 + N'IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N''' + @l + N''') CREATE USER ' + QUOTENAME(@l) + N' FOR LOGIN ' + QUOTENAME(@l) + N';'
 + N'GRANT SELECT ON dbo.sysjobs TO '         + QUOTENAME(@l) + N';'
 + N'GRANT SELECT ON dbo.sysjobsteps TO '     + QUOTENAME(@l) + N';'
 + N'GRANT SELECT ON dbo.sysjobschedules TO ' + QUOTENAME(@l) + N';'
 + N'GRANT SELECT ON dbo.sysschedules TO '    + QUOTENAME(@l) + N';'
 + N'GRANT SELECT ON dbo.sysjobservers TO '   + QUOTENAME(@l) + N';'
 + N'GRANT SELECT ON dbo.sysjobactivity TO '  + QUOTENAME(@l) + N';'
 + N'GRANT SELECT ON dbo.sysjobhistory TO '   + QUOTENAME(@l) + N';'
 + N'GRANT SELECT ON dbo.sysoperators TO '    + QUOTENAME(@l) + N';';
EXEC sys.sp_executesql @sql;
PRINT 'prava pridelena';
"@
    $out = & sqlcmd -S $SqlServer -E -b -d master -h-1 -W -Q $q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Prideleni prav selhalo:`n$($out -join "`n")" }
    Ok "${identita}: pet roli karch_*, cteni v archivu i zdroji, cteni msdb, DMV pravo"
}

# ------------------------------------------------------------- 8) overeni
Nadpis 'Overeni'
Restart-WebAppPool -Name $AppPoolName
Start-Sleep -Seconds 4

$base = "http://localhost:$Port"
$potize = $false
foreach ($u in @('/health', '/api/readiness')) {
    try {
        $r = Invoke-WebRequest -Uri ($base + $u) -UseBasicParsing -TimeoutSec 25
        $telo = $r.Content
        if ($telo.Length -gt 170) { $telo = $telo.Substring(0, 170) + '...' }
        if ($telo -match '"databaseOk"\s*:\s*false') {
            Warn "$u -> HTTP $($r.StatusCode), ale databaseOk=false (chybi opravneni, ne databaze): $telo"
            $potize = $true
        }
        else { Ok "$u -> HTTP $($r.StatusCode)  $telo" }
    }
    catch { Warn "$u -> $($_.Exception.Message)"; $potize = $true }
}

Write-Host ''
if ($potize) {
    Write-Host 'Neco neprochazi. Nejcastejsi priciny:' -ForegroundColor Yellow
    Write-Host '  * chybi .NET 10 Hosting Bundle (aplikace cili na net10.0, ne 8/9) -> doinstalovat, iisreset'
    Write-Host '  * Microsoft.Data.SqlClient.SNI.dll neni v korenu aplikace'
    Write-Host '  * ucet nema vsech pet roli karch_* nebo VIEW DATABASE PERFORMANCE STATE'
    Write-Host '  * chybi EXECUTE na operatorske API -> konzole hlasi "Edit access not configured"'
    Write-Host "  * podrobnosti: Event Viewer -> Application, zdroj 'IIS AspNetCore Module V2'"
}
else {
    Write-Host "Hotovo. Konzole bezi na $base" -ForegroundColor Green
    Write-Host "Ze site: http://$env:COMPUTERNAME`:$Port  (pokud port pusti firewall)" -ForegroundColor Green
    Write-Host 'Prihlaseni k editaci: uzivatel a heslo operatora z Deploy-Database.ps1' -ForegroundColor Green
}
