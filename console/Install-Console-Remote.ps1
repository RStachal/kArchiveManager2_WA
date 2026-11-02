<#
.SYNOPSIS
    Nasadí Admin Console na IIS na stroji, který NENÍ SQL serverem.

.DESCRIPTION
    Dodávaný runbook počítá s tím, že konzole běží na témže stroji jako SQL
    Server, a připojuje se Windows autentizací přes identitu aplikačního fondu
    IIS. Tady to nelze ze dvou důvodů:

      * konzole běží na RADIM-STACHAL, SQL Server na WA01,
      * ani jeden stroj není v doméně, takže Windows autentizace mezi nimi
        neprojde.

    Konzole se proto připojuje SQL loginem (karch_console), kterému práva
    přidělil skript sql/61_console_principal_sql_login.sql.

    Skript je bezpečné pustit opakovaně: existující aplikační fond i aplikaci
    jen přenastaví.

.PARAMETER SqlPassword
    Heslo loginu karch_console. Do skriptu se nezapisuje a do appsettings.json
    se zapíše jen tehdy, když se nepoužije -UseEnvVar.

.PARAMETER UseEnvVar
    Heslo se nezapíše do appsettings.json, ale do proměnné prostředí
    aplikačního fondu (ConnectionStrings__ArchiveManagerAdmin). Soubor na disku
    pak heslo neobsahuje. Doporučeno.

.EXAMPLE
    .\Install-Console-Remote.ps1 -SqlServer 192.168.120.128 -SqlPassword 'xxx' -UseEnvVar
#>
[CmdletBinding()]
param(
    [string] $PayloadZip  = (Join-Path $PSScriptRoot 'AdminConsole-payload.zip'),
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

# ---------------------------------------------------------------- 0) předpoklady
Step '0) Kontrola předpokladů'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Spusťte prosím jako správce (IIS i ACL to vyžadují).'
}

if (-not (Get-Module -ListAvailable -Name WebAdministration)) {
    throw 'Chybí role IIS s modulem WebAdministration. Nainstalujte Web-Server a Web-Mgmt-Console.'
}
Import-Module WebAdministration
Ok 'IIS a modul WebAdministration'

# .NET 10 Hosting Bundle — NE runtime 8/9, jak tvrdí dodávaný handover README.
# Modul AspNetCoreModuleV2 je jediný spolehlivý ukazatel, že je bundle nasazený.
$ancm = Get-WebGlobalModule -Name 'AspNetCoreModuleV2' -ErrorAction SilentlyContinue
if (-not $ancm) {
    throw @'
Chybí AspNetCoreModuleV2 — není nainstalovaný ASP.NET Core Hosting Bundle.
Aplikace cílí na net10.0, takže je potřeba .NET 10 Hosting Bundle
(dotnet-hosting-10.0.x-win.exe). Runtime 8 ani 9 nestačí. Po instalaci
bundlu spusťte: iisreset
'@
}
$runtimes = @()
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) { $runtimes = & dotnet --list-runtimes 2>$null | Where-Object { $_ -match 'Microsoft\.AspNetCore\.App 10\.' } }
if ($runtimes) { Ok ("Hosting Bundle: " + ($runtimes | Select-Object -First 1)) }
else { Warn 'AspNetCoreModuleV2 je přítomen, ale ASP.NET Core 10 runtime se nepodařilo potvrdit. Pokud aplikace nenaběhne, doinstalujte .NET 10 Hosting Bundle.' }

if (-not (Test-Path $PayloadZip)) { throw "Chybí balíček s aplikací: $PayloadZip" }
Ok "Balíček: $PayloadZip"

# --------------------------------------------------------- 1) dostupnost SQL
Step "1) Dostupnost SQL Serveru $SqlServer"
$tcp = Test-NetConnection -ComputerName $SqlServer -Port 1433 -WarningAction SilentlyContinue
if (-not $tcp.TcpTestSucceeded) {
    throw "Na $SqlServer`:1433 se nelze připojit. Ověřte, že SQL Server naslouchá na TCP a že port nezavírá firewall."
}
Ok 'TCP 1433 odpovídá'

$csTest = "Server=$SqlServer;Database=$AdminDb;User ID=$SqlLogin;Password=$SqlPassword;TrustServerCertificate=True;Encrypt=True;Connect Timeout=10;"
try {
    $cn = New-Object System.Data.SqlClient.SqlConnection $csTest
    $cn.Open()
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = "SELECT SUSER_SNAME() + ' / ' + DB_NAME() + ' / ' + CONVERT(varchar(20), COUNT(*)) + ' procesu' FROM arch.Process"
    Ok ('Přihlášení prošlo: ' + $cmd.ExecuteScalar())
    $cn.Close()
}
catch { throw "SQL login selhal: $($_.Exception.Message)" }

# ------------------------------------------------------------ 2) soubory
Step '2) Rozbalení aplikace'
if (Test-Path $SitePath) {
    $bak = "$SitePath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Warn "Cíl existuje — původní obsah odkládám do $bak"
    Move-Item $SitePath $bak
}
New-Item -ItemType Directory -Path $SitePath -Force | Out-Null
Expand-Archive -Path $PayloadZip -DestinationPath $SitePath -Force
$n = (Get-ChildItem $SitePath -Recurse -File).Count
Ok "rozbaleno souborů: $n"

# ------------------------------------------------------- 3) appsettings.json
Step '3) Konfigurace'
$appsettings = Join-Path $SitePath 'appsettings.json'
$cfg = Get-Content $appsettings -Raw | ConvertFrom-Json

if ($UseEnvVar) {
    # Heslo zůstane mimo soubor na disku; předá ho proměnná prostředí fondu.
    $cfg.ConnectionStrings.ArchiveManagerAdmin = ''
    Ok 'Connection string v souboru ponechán prázdný (heslo ponese proměnná fondu)'
}
else {
    $cfg.ConnectionStrings.ArchiveManagerAdmin =
        "Server=$SqlServer;Database=$AdminDb;User ID=$SqlLogin;Password=$SqlPassword;TrustServerCertificate=True;Encrypt=True;"
    Warn 'Heslo je zapsané v appsettings.json. Zvažte -UseEnvVar.'
}
$cfg.AdminConsole.WindowsAuthEnabled = $false
$cfg | ConvertTo-Json -Depth 10 | Set-Content $appsettings -Encoding UTF8
Ok 'appsettings.json zapsán'

# ------------------------------------------------------------- 4) IIS
Step '4) IIS: aplikační fond a web'
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
    Ok 'Connection string uložen do proměnné prostředí fondu'
}

if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) { Remove-Website -Name $SiteName }
New-Website -Name $SiteName -Port $Port -PhysicalPath $SitePath -ApplicationPool $AppPoolName | Out-Null
Ok "web '$SiteName' na portu $Port"

# ACL: fond potřebuje číst obsah a zapisovat logy
$id = "IIS AppPool\$AppPoolName"
$acl = Get-Acl $SitePath
$acl.SetAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    $id, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl $SitePath $acl
Ok "ACL pro $id"

Restart-WebAppPool -Name $AppPoolName
Start-Sleep -Seconds 3

# ------------------------------------------------------------- 5) ověření
Step '5) Ověření'
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
    Write-Host 'Některé ověření neprošlo. Nejčastější příčiny:' -ForegroundColor Yellow
    Write-Host '  * chybí .NET 10 Hosting Bundle (aplikace cílí na net10.0, ne 8/9) -> doinstalovat a iisreset'
    Write-Host '  * firewall na SQL serveru zavírá 1433'
    Write-Host '  * login karch_console nemá práva -> spustit sql/61_console_principal_sql_login.sql'
    Write-Host "  * podrobnosti: Event Viewer -> Application, zdroj 'IIS AspNetCore Module V2'"
}
else {
    Write-Host "Hotovo. Konzole běží na $base" -ForegroundColor Green
    Write-Host "Ze sítě: http://$env:COMPUTERNAME`:$Port  (pokud port pustí firewall)"
}
