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
    [string] $HostingBundlePath,
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

# Pritomnost appcmd.exe jeste neznamena, ze se da IIS ridit z PowerShellu: po
# cerstve instalaci role nejsou zaregistrovane COM komponenty a provider pada na
# REGDB_E_CLASSNOTREG, dokud se stroj nerestartuje. Jedina spolehliva kontrola
# je provider zkusit pouzit.
function Test-IisUsable {
    try {
        Import-Module WebAdministration -ErrorAction Stop
        $null = Get-Website -ErrorAction Stop
        return $true
    }
    catch { return $false }
}

# ============================================================================
# Prace s IIS: provider WebAdministration, nebo appcmd.exe
# ----------------------------------------------------------------------------
# Provider umi selhat na REGDB_E_CLASSNOTREG, i kdyz IIS sam funguje bezvadne.
# Zmereno na Windows 11 build 26300: vsechny soucasti IIS zapnute vcetne
# IIS-ManagementScriptingTools, sluzby W3SVC i WAS bezi, "appcmd list site"
# vraci 0 a vidi Default Web Site, Import-Module WebAdministration projde - a
# presto Get-Website pada. Chybi registrace COM tridy
# Microsoft.AppHostQueryProcessor z AppHostNavigators.dll.
#
# appcmd.exe umi vse, co tu potrebujeme, a na te COM tride nezavisi. Skript
# proto pouzije provider, kdyz funguje, a jinak prepne na appcmd.
# ============================================================================
$script:Appcmd  = Join-Path $env:windir 'System32\inetsrv\appcmd.exe'
$script:IisMode = 'provider'

function Invoke-Appcmd {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Argumenty)
    $out = & $script:Appcmd @Argumenty 2>&1
    return [pscustomobject]@{ Kod = $LASTEXITCODE; Vystup = ($out -join "`n") }
}

function Test-AppcmdUsable {
    if (-not (Test-Path $script:Appcmd)) { return $false }
    return ((Invoke-Appcmd 'list' 'site').Kod -eq 0)
}

function New-AppPoolX {
    param([string] $Name)
    if ($script:IisMode -eq 'provider') {
        if (-not (Test-Path "IIS:\AppPools\$Name")) { New-WebAppPool -Name $Name | Out-Null }
        Set-ItemProperty "IIS:\AppPools\$Name" -Name managedRuntimeVersion     -Value ''
        Set-ItemProperty "IIS:\AppPools\$Name" -Name startMode                 -Value 'AlwaysRunning'
        Set-ItemProperty "IIS:\AppPools\$Name" -Name processModel.identityType -Value 'ApplicationPoolIdentity'
        Set-ItemProperty "IIS:\AppPools\$Name" -Name processModel.idleTimeout  -Value '00:00:00'
        return
    }
    if ((Invoke-Appcmd 'list' 'apppool' $Name).Kod -ne 0) {
        $r = Invoke-Appcmd 'add' 'apppool' "/name:$Name"
        if ($r.Kod -ne 0) { throw "appcmd add apppool selhalo:`n$($r.Vystup)" }
    }
    foreach ($nast in @('/managedRuntimeVersion:',
                        '/startMode:AlwaysRunning',
                        '/processModel.identityType:ApplicationPoolIdentity',
                        '/processModel.idleTimeout:00:00:00')) {
        $r = Invoke-Appcmd 'set' 'apppool' "/apppool.name:$Name" $nast
        if ($r.Kod -ne 0) { throw "appcmd set apppool $nast selhalo:`n$($r.Vystup)" }
    }
}

function Set-AppPoolEnvX {
    param([string] $Name, [string] $Key, [string] $Value)
    if ($script:IisMode -eq 'provider') {
        Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Filter "system.applicationHost/applicationPools/add[@name='$Name']/environmentVariables" `
            -Name '.' -AtElement @{name = $Key } -ErrorAction SilentlyContinue
        Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' `
            -Filter "system.applicationHost/applicationPools/add[@name='$Name']/environmentVariables" `
            -Name '.' -Value @{name = $Key; value = $Value }
        return
    }
    $sekce = 'system.applicationHost/applicationPools'
    # napred odebrat, aby se pri opakovanem spusteni nezdvojila
    $null = Invoke-Appcmd 'set' 'config' "-section:$sekce" "/-[name='$Name'].environmentVariables.[name='$Key']" '/commit:apphost'
    $r = Invoke-Appcmd 'set' 'config' "-section:$sekce" "/+[name='$Name'].environmentVariables.[name='$Key',value='$Value']" '/commit:apphost'
    if ($r.Kod -ne 0) { throw "appcmd nastaveni promenne prostredi selhalo:`n$($r.Vystup)" }
}

function Remove-SiteX {
    param([string] $Name)
    if ($script:IisMode -eq 'provider') {
        if (Get-Website -Name $Name -ErrorAction SilentlyContinue) { Remove-Website -Name $Name }
        return
    }
    if ((Invoke-Appcmd 'list' 'site' $Name).Kod -eq 0) { $null = Invoke-Appcmd 'delete' 'site' $Name }
}

function New-SiteX {
    param([string] $Name, [int] $Port, [string] $Path, [string] $Pool)
    if ($script:IisMode -eq 'provider') {
        New-Website -Name $Name -Port $Port -PhysicalPath $Path -ApplicationPool $Pool | Out-Null
        return
    }
    $r = Invoke-Appcmd 'add' 'site' "/name:$Name" "/bindings:http/*:${Port}:" "/physicalPath:$Path"
    if ($r.Kod -ne 0) { throw "appcmd add site selhalo:`n$($r.Vystup)" }
    $r = Invoke-Appcmd 'set' 'app' "$Name/" "/applicationPool:$Pool"
    if ($r.Kod -ne 0) { throw "appcmd prirazeni fondu selhalo:`n$($r.Vystup)" }
}

function Restart-AppPoolX {
    param([string] $Name)
    if ($script:IisMode -eq 'provider') { Restart-WebAppPool -Name $Name; return }
    $null = Invoke-Appcmd 'stop' 'apppool' "/apppool.name:$Name"
    Start-Sleep -Seconds 2
    $null = Invoke-Appcmd 'start' 'apppool' "/apppool.name:$Name"
}

function Stop-SiteAndPoolX {
    param([string] $Site, [string] $Pool)
    if ($script:IisMode -eq 'provider') {
        if (Get-Website -Name $Site -ErrorAction SilentlyContinue) { Stop-Website -Name $Site -ErrorAction SilentlyContinue }
        if (Test-Path "IIS:\AppPools\$Pool") { Stop-WebAppPool -Name $Pool -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
        return
    }
    $null = Invoke-Appcmd 'stop' 'site' "/site.name:$Site"
    $null = Invoke-Appcmd 'stop' 'apppool' "/apppool.name:$Pool"
    Start-Sleep -Seconds 2
}

# Pritomnost modulu ASP.NET Core. Pozor: "appcmd list config /section:
# system.webServer/globalModules" je nespolehlive - bez dostatecnych opravneni
# vrati chybu o redirection.config a tvari se, ze modul neni, i kdyz je.
# Overeno na WA01, kde Hosting Bundle nainstalovany JE. Rozhoduje proto
# existence knihovny, kterou Hosting Bundle uklada; appcmd slouzi jen jako
# potvrzeni, ze je modul i zaregistrovany.
function Test-AncmX {
    if ($script:IisMode -eq 'provider') {
        return [bool](Get-WebGlobalModule -Name 'AspNetCoreModuleV2' -ErrorAction SilentlyContinue)
    }
    $dll = Join-Path ${env:ProgramFiles} 'IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'
    $jeSoubor = Test-Path $dll
    $r = Invoke-Appcmd 'list' 'config' '/section:system.webServer/globalModules'
    $potvrzeno = ($r.Kod -eq 0 -and $r.Vystup -notmatch '^ERROR' -and $r.Vystup -match 'AspNetCoreModuleV2')
    if ($potvrzeno) { return $true }
    if ($jeSoubor) {
        Warn 'AspNetCoreModuleV2: knihovna je na miste, ale registraci v IIS se nepodarilo overit.'
        Warn 'Pokracuji; kdyby aplikace nenabehla, spustte iisreset.'
        return $true
    }
    return $false
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
  Windows Server:  Install-WindowsFeature -Name Web-Server, Web-Mgmt-Console, Web-Scripting-Tools -IncludeManagementTools
  Windows 10/11:   Enable-WindowsOptionalFeature -Online -All -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-ManagementConsole, IIS-ManagementScriptingTools
Po instalaci muze byt nutny restart.
'@
    }
    Warn 'instaluji roli IIS - muze to trvat nekolik minut'
    # Serverove a klientske Windows to delaji jinak
    if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) {
        Enable-WindowsOptionalFeature -Online -All -NoRestart `
            -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-ManagementConsole, IIS-ManagementScriptingTools | Out-Null
    }
    else {
        Install-WindowsFeature -Name Web-Server, Web-Mgmt-Console, Web-Scripting-Tools -IncludeManagementTools | Out-Null
    }
    if (-not (Test-IisUsable)) {
        throw @'
Role IIS se nainstalovala, ale provider WebAdministration porad nefunguje
(REGDB_E_CLASSNOTREG / "Trida neni zaregistrovana").

Modul WebAdministration potrebuje soucast IIS Management Scripting Tools -
sama role webserveru nestaci. Doinstalujte ji a spustte skript znovu:

  Windows 10/11:
    Enable-WindowsOptionalFeature -Online -All -FeatureName IIS-ManagementScriptingTools
  Windows Server:
    Install-WindowsFeature -Name Web-Scripting-Tools

Pokud uz nainstalovana je, restartujte stroj - COM komponenty se registruji
az po restartu.
'@
    }
    Ok 'role IIS nainstalovana a funkcni'
}
# Provider, nebo appcmd - podle toho, co na tomto stroji funguje.
if (Test-IisUsable) {
    $script:IisMode = 'provider'
    Import-Module WebAdministration
    Ok 'rizeni IIS: provider WebAdministration'
}
elseif (Test-AppcmdUsable) {
    $script:IisMode = 'appcmd'
    Warn 'provider WebAdministration nefunguje (REGDB_E_CLASSNOTREG) - prepinam na appcmd.exe'
    Warn 'IIS sam je v poradku, chybi jen registrace COM tridy pro PowerShell.'
    Warn 'Opravit lze takto (jako spravce):  regsvr32 /s %windir%\System32\inetsrv\AppHostNavigators.dll'
    Ok 'rizeni IIS: appcmd.exe'
}
else {
    throw @'
IIS nelze ridit ani pres provider WebAdministration, ani pres appcmd.exe.

Overte, ze je nainstalovana role IIS vcetne soucasti pro skriptovani:
  Windows 10/11:   Enable-WindowsOptionalFeature -Online -All -FeatureName IIS-ManagementScriptingTools
  Windows Server:  Install-WindowsFeature -Name Web-Scripting-Tools

Podrobnou diagnostiku da console\Diagnose-Iis.ps1.
'@
}

# Aplikace cili na net10.0. Runtime 8 ani 9 nestaci, prestoze to dodavany
# handover README tvrdi. AspNetCoreModuleV2 je jediny spolehlivy ukazatel.
# Hosting Bundle: kdyz chybi a mame instalator po ruce, nainstalujeme ho sami.
# V offline balicku lezi v .\installers\, takze zakaznik nic nestahuje.
if (-not (Test-AncmX)) {
    if (-not $HostingBundlePath) {
        $kandidat = Get-ChildItem (Join-Path $PSScriptRoot 'installers') -Filter 'dotnet-hosting-*-win.exe' -ErrorAction SilentlyContinue |
                    Sort-Object Name -Descending | Select-Object -First 1
        if ($kandidat) { $HostingBundlePath = $kandidat.FullName }
    }
    if ($HostingBundlePath -and (Test-Path $HostingBundlePath)) {
        $podpis = Get-AuthenticodeSignature $HostingBundlePath
        if ($podpis.Status -ne 'Valid') { throw "Instalator $HostingBundlePath nema platny podpis (stav: $($podpis.Status)). Nespoustim ho." }
        Warn "instaluji .NET Hosting Bundle z $(Split-Path $HostingBundlePath -Leaf) - muze to trvat nekolik minut"
        $p = Start-Process -FilePath $HostingBundlePath -ArgumentList '/quiet', '/norestart' -Wait -PassThru
        # 0 = hotovo, 3010 = hotovo, vyzaduje restart
        if ($p.ExitCode -notin @(0, 3010)) { throw "Instalace Hosting Bundle skoncila kodem $($p.ExitCode)." }
        if ($p.ExitCode -eq 3010) { Warn 'instalator hlasi, ze je potreba restart' }
        $null = & iisreset /restart 2>&1
        Start-Sleep -Seconds 3
        Ok 'Hosting Bundle nainstalovan'
    }
}
if (-not (Test-AncmX)) {
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

# Stara instance konzole se do SQL hlasi kazdych ~30 s. Po prenasazeni databaze
# ma v promenne aplikacniho fondu stare heslo, takze kazdy pokus selze - a pri
# bezne zasade "limit zamknuti 10" se ucet zamkne driv, nez stihne nekdo nasadit
# novou verzi. Zamceny ucet odmita i SPRAVNE heslo, takze se nasazeni uz nikdy
# nechytne: zamek po deseti minutach vyprsi a stara konzole ho hned zamkne znovu.
# Proto se stara instance zastavuje TED, pred testem prihlaseni - ne az u
# kopirovani souboru, kam to puvodne patrilo.
Stop-SiteAndPoolX -Site $SiteName -Pool $AppPoolName
Ok 'pripadna predchozi instance konzole zastavena (aby nezamkla ucet)'

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
    catch {
        # 18486 = ucet je zamceny. Rozlisit to je zasadni: zamceny ucet odmita
        # i spravne heslo, takze bez teto hlasky clovek marne overuje heslo,
        # ktere je cele tu dobu v poradku.
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [System.Data.SqlClient.SqlException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Number -eq 18486) {
            Write-Host ''
            Warn "Ucet $SqlLogin je na SQL Serveru ZAMCENY - proto neprojde ani spravne heslo."
            Warn 'Zamkla ho predchozi instance konzole: hlasi se starym heslem kazdych ~30 s'
            Warn 'a prekroci limit neuspesnych pokusu. Jeji fond uz tento skript zastavil,'
            Warn 'takze zamek po dobe zamceni (zpravidla 10 minut) sam vyprsi - pak spustte'
            Warn 'skript znovu. Okamzite odemknuti na SQL Serveru:'
            Warn "   ALTER LOGIN [$SqlLogin] WITH PASSWORD = N'<heslo>' UNLOCK;"
            throw "Ucet $SqlLogin je zamceny."
        }
        throw ('SQL login selhal: ' + $(if ($ex) { $ex.Message } else { $_.Exception.Message }))
    }
}

# ----------------------------------------------------------- 4) soubory
Nadpis 'Soubory aplikace'
$dll = Join-Path $AppSource 'KArchiveManager.AdminConsole.Api.dll'
if (-not (Test-Path $dll)) { throw "Chybi aplikace: $dll`nSpoustite skript z klonu repozitare? Jinak predejte -AppSource." }

if (Test-Path $SitePath) {
    $bak = "$SitePath.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
    Warn "cil existuje - odkladam do $bak"
    Stop-SiteAndPoolX -Site $SiteName -Pool $AppPoolName
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
New-AppPoolX -Name $AppPoolName
Ok "fond '$AppPoolName' (No Managed Code, AlwaysRunning)"

if ($AuthMode -eq 'SqlLogin') {
    Set-AppPoolEnvX -Name $AppPoolName -Key 'ConnectionStrings__ArchiveManagerAdmin' -Value $cs
    Ok 'connection string v promenne prostredi fondu (heslo neni na disku)'
}

Remove-SiteX -Name $SiteName
New-SiteX -Name $SiteName -Port $Port -Path $SitePath -Pool $AppPoolName
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
Restart-AppPoolX -Name $AppPoolName
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
