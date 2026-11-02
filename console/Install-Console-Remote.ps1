<#
.SYNOPSIS
    Nasadi Admin Console na IIS na stroji, ktery NENI SQL serverem.

.DESCRIPTION
    Dodavany runbook pocita s tim, ze konzole bezi na temze stroji jako SQL
    Server, a pripojuje se Windows autentizaci pres identitu aplikacniho fondu
    IIS. Tady to nelze ze dvou duvodu:

      * konzole bezi na RADIM-STACHAL, SQL Server na WA01,
      * ani jeden stroj neni v domene, takze Windows autentizace mezi nimi
        neprojde.

    Konzole se proto pripojuje SQL loginem (karch_console), kteremu prava
    pridelil skript sql/61_console_principal_sql_login.sql.

    Skript je bezpecne pustit opakovane: existujici aplikacni fond i aplikaci
    jen prenastavi.

.PARAMETER SqlPassword
    Heslo loginu karch_console. Do skriptu se nezapisuje a do appsettings.json
    se zapise jen tehdy, kdyz se nepouzije -UseEnvVar.

.PARAMETER UseEnvVar
    Heslo se nezapise do appsettings.json, ale do promenne prostredi
    aplikacniho fondu (ConnectionStrings__ArchiveManagerAdmin). Soubor na disku
    pak heslo neobsahuje. Doporuceno.

.EXAMPLE
    .\Install-Console-Remote.ps1 -SqlServer <sql-server> -SqlPassword 'heslo' -UseEnvVar
#>
[CmdletBinding()]
param(
    # Vychozi zdroj je aplikace primo z repozitare - je verzovana, takze
    # prezije vymenu stroje. ZIP je jen alternativa, kdyz se nasazuje bez
    # klonu repozitare.
    [string] $AppSource   = (Join-Path (Split-Path $PSScriptRoot -Parent) 'kAM2\02-admin-console\app'),
    [string] $PayloadZip,
    [string] $SitePath    = 'C:\inetpub\kArchiveManager\AdminConsole',
    [string] $AppPoolName = 'kAM Admin Console',
    [string] $SiteName    = 'kAM Admin Console',
    [int]    $Port        = 8089,

    [Parameter(Mandatory = $true)]
    [string] $SqlServer,
    [string] $SqlLogin    = 'karch_console',
    [Parameter(Mandatory = $true)]
    [string] $SqlPassword,
    [string] $AdminDb     = 'kArchiveManagerAdmin',
    [switch] $UseEnvVar
)

$ErrorActionPreference = 'Stop'

function Step($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Ok($t)   { Write-Host "   OK  $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   !!  $t" -ForegroundColor Yellow }

# ---------------------------------------------------------------- 0) predpoklady
Step '0) Kontrola predpokladu'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Spustte prosim jako spravce (IIS i ACL to vyzaduji).'
}

if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
    throw 'Chybi role IIS s modulem WebAdministration. Nainstalujte Web-Server a Web-Mgmt-Console.'
}
Import-Module WebAdministration
Ok 'IIS a modul WebAdministration'

# .NET 10 Hosting Bundle - NE runtime 8/9, jak tvrdi dodavany handover README.
# Modul AspNetCoreModuleV2 je jediny spolehlivy ukazatel, ze je bundle nasazeny.
$ancm = Get-WebGlobalModule -Name 'AspNetCoreModuleV2' -ErrorAction SilentlyContinue
if (-not $ancm) {
    throw @'
Chybi AspNetCoreModuleV2 - neni nainstalovany ASP.NET Core Hosting Bundle.
Aplikace cili na net10.0, takze je potreba .NET 10 Hosting Bundle
(dotnet-hosting-10.0.x-win.exe). Runtime 8 ani 9 nestaci. Po instalaci
bundlu spustte: iisreset
'@
}
$runtimes = @()
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) { $runtimes = & dotnet --list-runtimes 2>$null | Where-Object { $_ -match 'Microsoft\.AspNetCore\.App 10\.' } }
if ($runtimes) { Ok ("Hosting Bundle: " + ($runtimes | Select-Object -First 1)) }
else { Warn 'AspNetCoreModuleV2 je pritomen, ale ASP.NET Core 10 runtime se nepodarilo potvrdit. Pokud aplikace nenabehne, doinstalujte .NET 10 Hosting Bundle.' }

if ($PayloadZip) {
    if (-not (Test-Path $PayloadZip)) { throw "Chybi balicek s aplikaci: $PayloadZip" }
    Ok "Zdroj: balicek $PayloadZip"
}
else {
    if (-not (Test-Path $AppSource)) {
        throw "Chybi aplikace: $AppSource`nSpustte skript z klonu repozitare, nebo predejte -PayloadZip."
    }
    if (-not (Test-Path (Join-Path $AppSource 'KArchiveManager.AdminConsole.Api.dll'))) {
        throw "V $AppSource neni KArchiveManager.AdminConsole.Api.dll - spatna cesta?"
    }
    Ok "Zdroj: $AppSource (z repozitare)"
}

# --------------------------------------------------------- 1) dostupnost SQL
Step "1) Dostupnost SQL Serveru $SqlServer"
$tcp = Test-NetConnection -ComputerName $SqlServer -Port 1433 -WarningAction SilentlyContinue
if (-not $tcp.TcpTestSucceeded) {
    throw "Na $SqlServer`:1433 se nelze pripojit. Overte, ze SQL Server nasloucha na TCP a ze port nezavira firewall."
}
Ok 'TCP 1433 odpovida'

$csTest = "Server=$SqlServer;Database=$AdminDb;User ID=$SqlLogin;Password=$SqlPassword;TrustServerCertificate=True;Encrypt=True;Connect Timeout=10;"
try {
    $cn = New-Object System.Data.SqlClient.SqlConnection $csTest
    $cn.Open()
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = "SELECT SUSER_SNAME() + ' / ' + DB_NAME() + ' / ' + CONVERT(varchar(20), COUNT(*)) + ' procesu' FROM arch.Process"
    Ok ('Prihlaseni proslo: ' + $cmd.ExecuteScalar())
    $cn.Close()
}
catch { throw "SQL login selhal: $($_.Exception.Message)" }

# ------------------------------------------------------------ 2) soubory
Step '2) Nasazeni souboru aplikace'
if (Test-Path $SitePath) {
    $bak = "$SitePath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Warn "Cil existuje - puvodni obsah odkladam do $bak"
    Move-Item $SitePath $bak
}
New-Item -ItemType Directory -Path $SitePath -Force | Out-Null

if ($PayloadZip) {
    Expand-Archive -Path $PayloadZip -DestinationPath $SitePath -Force
}
else {
    # logs/ je behovy balast predchozi instalace, nekopiruje se
    Copy-Item (Join-Path $AppSource '*') $SitePath -Recurse -Force -Exclude 'logs'
    if (Test-Path (Join-Path $SitePath 'logs')) { Remove-Item (Join-Path $SitePath 'logs') -Recurse -Force }
}
$n = (Get-ChildItem $SitePath -Recurse -File).Count
Ok "souboru: $n"

# Nativni ovladac SqlClientu: NuGet ho uklada do runtimes\win-x64\native\, odkud
# si ho ASP.NET Core u framework-dependent nasazeni sam nenajde. Bez kopie do
# korene konzole nenavaze spojeni - to je vada c. 1 z ADMIN-CONSOLE.md.
$sniRoot = Join-Path $SitePath 'Microsoft.Data.SqlClient.SNI.dll'
if (-not (Test-Path $sniRoot)) {
    $sniSrc = Join-Path $SitePath 'runtimes\win-x64\native\Microsoft.Data.SqlClient.SNI.dll'
    if (Test-Path $sniSrc) {
        Copy-Item $sniSrc $sniRoot -Force
        Ok 'nativni ovladac SqlClientu zkopirovan do korene'
    }
    else {
        Warn 'Microsoft.Data.SqlClient.SNI.dll nenalezen - konzole se nemusi pripojit.'
    }
}
else { Ok 'nativni ovladac SqlClientu je v koreni' }

# ------------------------------------------------------- 3) appsettings.json
Step '3) Konfigurace'
$appsettings = Join-Path $SitePath 'appsettings.json'
$cfg = Get-Content $appsettings -Raw | ConvertFrom-Json

if ($UseEnvVar) {
    # Heslo zustane mimo soubor na disku; preda ho promenna prostredi fondu.
    $cfg.ConnectionStrings.ArchiveManagerAdmin = ''
    Ok 'Connection string v souboru ponechan prazdny (heslo ponese promenna fondu)'
}
else {
    $cfg.ConnectionStrings.ArchiveManagerAdmin =
        "Server=$SqlServer;Database=$AdminDb;User ID=$SqlLogin;Password=$SqlPassword;TrustServerCertificate=True;Encrypt=True;"
    Warn 'Heslo je zapsane v appsettings.json. Zvazte -UseEnvVar.'
}
$cfg.AdminConsole.WindowsAuthEnabled = $false
$cfg | ConvertTo-Json -Depth 10 | Set-Content $appsettings -Encoding UTF8
Ok 'appsettings.json zapsan'

# ------------------------------------------------------------- 4) IIS
Step '4) IIS: aplikacni fond a web'
if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) { New-WebAppPool -Name $AppPoolName | Out-Null }
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name managedRuntimeVersion -Value ''          # No Managed Code
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name startMode              -Value 'AlwaysRunning'
Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name processModel.identityType -Value 'ApplicationPoolIdentity'
Ok "fond '$AppPoolName' (No Managed Code)"

if ($UseEnvVar) {
    $cs = "Server=$SqlServer;Database=$AdminDb;User ID=$SqlLogin;Password=$SqlPassword;TrustServerCertificate=True;Encrypt=True;"
    $envColl = Get-ItemProperty "IIS:\AppPools\$AppPoolName" -Name environmentVariables -ErrorAction SilentlyContinue
    Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter "system.applicationHost/applicationPools/add[@name='$AppPoolName']/environmentVariables" `
        -Name '.' -AtElement @{name='ConnectionStrings__ArchiveManagerAdmin'} -ErrorAction SilentlyContinue
    Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
        -Filter "system.applicationHost/applicationPools/add[@name='$AppPoolName']/environmentVariables" `
        -Name '.' -Value @{name='ConnectionStrings__ArchiveManagerAdmin'; value=$cs}
    Ok 'Connection string ulozen do promenne prostredi fondu'
}

if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) { Remove-Website -Name $SiteName }
New-Website -Name $SiteName -Port $Port -PhysicalPath $SitePath -ApplicationPool $AppPoolName | Out-Null
Ok "web '$SiteName' na portu $Port"

# ACL: fond potrebuje cist obsah a zapisovat logy
$id = "IIS AppPool\$AppPoolName"
$acl = Get-Acl $SitePath
$acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $id, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl $SitePath $acl
Ok "ACL pro $id"

Restart-WebAppPool -Name $AppPoolName
Start-Sleep -Seconds 3

# ------------------------------------------------------------- 5) overeni
Step '5) Overeni'
$base = "http://localhost:$Port"
$fail = $false
foreach ($u in @('/health', '/api/readiness')) {
    try {
        $r = Invoke-WebRequest -Uri ($base + $u) -UseBasicParsing -TimeoutSec 20
        $body = $r.Content
        if ($body.Length -gt 200) { $body = $body.Substring(0, 200) + '...' }
        Ok "$u -> HTTP $($r.StatusCode)  $body"
    }
    catch { Warn "$u -> $($_.Exception.Message)"; $fail = $true }
}

Write-Host ''
if ($fail) {
    Write-Host 'Nektere overeni neproslo. Nejcastejsi priciny:' -ForegroundColor Yellow
    Write-Host '  * chybi .NET 10 Hosting Bundle (aplikace cili na net10.0, ne 8/9) -> doinstalovat a iisreset'
    Write-Host '  * firewall na SQL serveru zavira 1433'
    Write-Host '  * login karch_console nema prava -> spustit sql/61_console_principal_sql_login.sql'
    Write-Host "  * podrobnosti: Event Viewer -> Application, zdroj 'IIS AspNetCore Module V2'"
}
else {
    Write-Host "Hotovo. Konzole bezi na $base" -ForegroundColor Green
    Write-Host "Ze site: http://$env:COMPUTERNAME`:$Port  (pokud port pusti firewall)"
}
