<#
.SYNOPSIS
    Stahne nasazovaci balicky kArchiveManager 2.0 z GitHubu, rozbali je
    a volitelne rovnou spusti nasazeni.

.DESCRIPTION
    Jediny skript, ktery je potreba dostat na cilovy stroj. Vse ostatni si
    stahne sam:

      kAM2-Database.zip  databazova cast (0,4 MB)
      kAM2-Console.zip   Admin Console vcetne aplikace (3,6 MB)

    Bez -Deploy jen stahne a rozbali - pak si prectete SPUSTENI.txt v kazde
    slozce a spustte prikaz rucne. S -Deploy provede nasazeni rovnou.

    Bez diakritiky a bez BOM: skript se prenasi pres schranku i prohlizec
    a Windows PowerShell 5.1 cte soubor bez BOM jako ANSI, cimz by se
    diakritika v retezcich rozbila a parser by skoncil.

.PARAMETER Part
    Database | Console | Both  - co stahnout (vychozi Both).

.PARAMETER Deploy
    Po rozbaleni rovnou spustit nasazeni. Databazova cast potrebuje -SourceDb,
    konzole potrebuje -AuthMode.

.EXAMPLE
    # jen stahnout a rozbalit do C:\KODYS\kAM2
    .\Get-kAM2.ps1

.EXAMPLE
    # databazova cast rovnou nanecisto (SMAZE predchozi nasazeni produktu)
    .\Get-kAM2.ps1 -Part Database -Deploy -Server localhost -SourceDb KMWE -Clean

.EXAMPLE
    # konzole na databazovem stroji - bez hesla, identitou fondu IIS
    .\Get-kAM2.ps1 -Part Console -Deploy -AuthMode Windows -Server localhost -SourceDb KMWE
#>
[CmdletBinding()]
param(
    [ValidateSet('Database', 'Console', 'Both')]
    [string] $Part        = 'Both',
    [string] $TargetDir   = 'C:\KODYS\kAM2',
    [string] $Branch      = 'main',

    [switch] $Deploy,
    [string] $Server,
    [string] $SourceDb,
    [switch] $Clean,
    [switch] $IConfirm,
    [switch] $RaiseCompatLevel,

    [ValidateSet('Windows', 'SqlLogin')]
    [string] $AuthMode,
    [string] $SqlPassword,
    [int]    $Port        = 8089,
    [switch] $InstallIis
)

$ErrorActionPreference = 'Stop'
function Nadpis($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Ok($t)     { Write-Host "   OK   $t" -ForegroundColor Green }
function Warn($t)   { Write-Host "   !!   $t" -ForegroundColor Yellow }

$baseUrl = "https://raw.githubusercontent.com/RStachal/kArchiveManager2_WA/$Branch/dist"

Write-Host "`n=== kArchiveManager 2.0 ===" -ForegroundColor White
Write-Host "    cast $Part / cil $TargetDir / vetev $Branch"

# TLS 1.2 - starsi Windows PowerShell ho sam nezapne a GitHub nic nizsiho neprijme
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

Nadpis 'Stazeni'
if (-not (Test-Path $TargetDir)) { New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null }

$balicky = @()
if ($Part -in @('Database', 'Both')) { $balicky += @{ Zip = 'kAM2-Database.zip'; Dir = 'database' } }
if ($Part -in @('Console',  'Both')) { $balicky += @{ Zip = 'kAM2-Console.zip';  Dir = 'console'  } }

foreach ($b in $balicky) {
    $zip = Join-Path $TargetDir $b.Zip
    $dir = Join-Path $TargetDir $b.Dir
    try { Invoke-WebRequest -Uri "$baseUrl/$($b.Zip)" -OutFile $zip -UseBasicParsing }
    catch { throw "Stazeni $($b.Zip) selhalo: $($_.Exception.Message)" }
    Ok ("{0} ({1:N1} MB)" -f $b.Zip, ((Get-Item $zip).Length / 1MB))

    if (Test-Path $dir) {
        $bak = "$dir.bak-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Warn "slozka existuje - odkladam do $(Split-Path $bak -Leaf)"
        Move-Item $dir $bak
    }
    Expand-Archive -Path $zip -DestinationPath $dir -Force
    Remove-Item $zip -Force
    # soubory z Invoke-WebRequest nenesou znacku "stazeno ze site", ale po
    # rucnim stazeni prohlizecem ano - Unblock-File pro jistotu
    Get-ChildItem $dir -Recurse -Filter *.ps1 | Unblock-File -ErrorAction SilentlyContinue
    Ok ("rozbaleno: $dir (" + (Get-ChildItem $dir -Recurse -File).Count + " souboru)")
}

if (-not $Deploy) {
    Write-Host "`nHotovo - stazeno a rozbaleno." -ForegroundColor Green
    Write-Host 'Dalsi krok: prectete si SPUSTENI.txt v kazde slozce.' -ForegroundColor Green
    foreach ($b in $balicky) { Write-Host ("   " + (Join-Path (Join-Path $TargetDir $b.Dir) 'SPUSTENI.txt')) }
    return
}

# ====================================================================== nasazeni
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Pro -Deploy spustte jako spravce.'
}

if ($Part -in @('Database', 'Both')) {
    if (-not $Server -or -not $SourceDb) { throw 'Pro nasazeni databazove casti je nutny -Server a -SourceDb.' }
    Nadpis 'Nasazeni databazove casti'
    $p = @{ Server = $Server; SourceDb = $SourceDb }
    if ($Clean)            { $p['Clean'] = $true }
    if ($IConfirm)         { $p['IConfirm'] = $true }
    if ($RaiseCompatLevel) { $p['RaiseCompatLevel'] = $true }
    Push-Location (Join-Path $TargetDir 'database')
    try { & .\Deploy-Database.ps1 @p } finally { Pop-Location }
}

if ($Part -in @('Console', 'Both')) {
    if (-not $AuthMode) { throw 'Pro nasazeni konzole je nutny -AuthMode Windows nebo SqlLogin.' }
    Nadpis 'Nasazeni konzole'
    $p = @{ AuthMode = $AuthMode; SqlServer = $(if ($Server) { $Server } else { 'localhost' }); Port = $Port }
    if ($SourceDb)    { $p['SourceDb'] = $SourceDb }
    if ($SqlPassword) { $p['SqlPassword'] = $SqlPassword }
    if ($InstallIis)  { $p['InstallIis'] = $true }
    Push-Location (Join-Path $TargetDir 'console')
    try { & .\Deploy-Console.ps1 @p } finally { Pop-Location }
}

Write-Host "`nHotovo." -ForegroundColor Green
