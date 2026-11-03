<#
.SYNOPSIS
    Zjisti, proc na tomto stroji nefunguje provider WebAdministration.

.DESCRIPTION
    Nic nemeni, jen cte a vypise kompletni obraz: verzi systemu, stav soucasti
    IIS, dostupnost appcmd, vysledek importu modulu a PRESNE zneni vyjimky.
    Vystup je urceny k vlozeni do odpovedi.

    Spustte JAKO SPRAVCE - cast dotazu bez elevace nic nevrati.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
function Sekce($t) { Write-Output ""; Write-Output "--- $t" }

Write-Output '===== DIAGNOSTIKA IIS ====='
Write-Output ("stroj: $env:COMPUTERNAME   cas: " + (Get-Date -Format 'yyyy-MM-dd HH:mm'))

$spravce = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Output "jako spravce: $spravce"
if (-not $spravce) { Write-Output '!! BEZ ELEVACE - vysledky nize jsou neuplne. Spustte jako spravce.' }

Sekce 'System'
$os = Get-CimInstance Win32_OperatingSystem
Write-Output ("  {0}  build {1}  ProductType {2} ({3})" -f $os.Caption, $os.BuildNumber, $os.ProductType,
    $(switch ($os.ProductType) { 1 { 'klient' } 2 { 'radic domeny' } 3 { 'server' } default { '?' } }))
Write-Output ("  PowerShell: " + $PSVersionTable.PSVersion)

Sekce 'Soucasti IIS'
if ($os.ProductType -eq 1) {
    try {
        Get-WindowsOptionalFeature -Online -ErrorAction Stop |
            Where-Object { $_.FeatureName -like 'IIS-*' -and $_.State -eq 'Enabled' } |
            ForEach-Object { Write-Output ("  [zapnuto] " + $_.FeatureName) }
        Write-Output ''
        Write-Output '  KLICOVE soucasti:'
        foreach ($f in 'IIS-WebServerRole', 'IIS-WebServer', 'IIS-ManagementConsole',
                       'IIS-ManagementScriptingTools', 'IIS-WebServerManagementTools') {
            $s = (Get-WindowsOptionalFeature -Online -FeatureName $f -ErrorAction SilentlyContinue).State
            Write-Output ("    {0,-32} {1}" -f $f, $(if ($s) { $s } else { 'NEEXISTUJE POD TIMTO NAZVEM' }))
        }
    }
    catch { Write-Output "  CHYBA pri cteni soucasti: $($_.Exception.Message)" }
}
else {
    Get-WindowsFeature -Name Web-* -ErrorAction SilentlyContinue |
        Where-Object InstallState -eq 'Installed' |
        ForEach-Object { Write-Output ("  [instalovano] " + $_.Name) }
}

Sekce 'Soubory a sluzby'
foreach ($p in "$env:windir\System32\inetsrv\appcmd.exe",
               "$env:windir\System32\inetsrv\Microsoft.Web.Administration.dll",
               "$env:windir\System32\inetsrv\nativerd.dll",
               "$env:windir\System32\inetsrv\AppHostNavigators.dll",
               (Join-Path ${env:ProgramFiles} 'IIS\Asp.Net Core Module\V2\aspnetcorev2.dll'),
               "$env:windir\System32\WindowsPowerShell\v1.0\Modules\WebAdministration\WebAdministration.psd1") {
    Write-Output ("  {0,-6} {1}" -f $(if (Test-Path $p) { 'je' } else { 'CHYBI' }), $p)
}
foreach ($s in 'W3SVC', 'WAS') {
    $svc = Get-Service $s -ErrorAction SilentlyContinue
    Write-Output ("  sluzba {0,-6} {1}" -f $s, $(if ($svc) { $svc.Status } else { 'NENI' }))
}

Sekce 'appcmd (nezavisle na PowerShellu)'
$appcmd = "$env:windir\System32\inetsrv\appcmd.exe"
if (Test-Path $appcmd) {
    $out = & $appcmd list site 2>&1
    Write-Output ("  navratovy kod: $LASTEXITCODE")
    $out | Select-Object -First 5 | ForEach-Object { Write-Output "    $_" }
}

Sekce 'Import modulu WebAdministration'
try {
    Import-Module WebAdministration -ErrorAction Stop
    Write-Output '  Import-Module: PROSLO'
    try {
        $w = Get-Website -ErrorAction Stop
        Write-Output ("  Get-Website: PROSLO, webu: " + @($w).Count)
    }
    catch { Write-Output ("  Get-Website SELHAL: " + $_.Exception.GetType().Name + ": " + $_.Exception.Message) }
    try {
        $m = Get-WebGlobalModule -ErrorAction Stop
        Write-Output ("  Get-WebGlobalModule: PROSLO, modulu: " + @($m).Count)
        $ancm = @($m | Where-Object Name -like 'AspNetCore*')
        if ($ancm) { $ancm | ForEach-Object { Write-Output ("    " + $_.Name) } }
        else { Write-Output '    AspNetCoreModuleV2 NENI - chybi .NET Hosting Bundle' }
    }
    catch { Write-Output ("  Get-WebGlobalModule SELHAL: " + $_.Exception.GetType().Name + ": " + $_.Exception.Message) }
}
catch { Write-Output ("  Import-Module SELHAL: " + $_.Exception.GetType().Name + ": " + $_.Exception.Message) }

Sekce 'IIS:\ provider'
try { $null = Get-ChildItem 'IIS:\' -ErrorAction Stop; Write-Output '  IIS:\ PROSLO' }
catch { Write-Output ("  IIS:\ SELHAL: " + $_.Exception.Message) }

Sekce '.NET runtimes'
$dn = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dn) { & dotnet --list-runtimes 2>$null | ForEach-Object { Write-Output "  $_" } }
else { Write-Output '  dotnet neni na PATH' }

Write-Output ''
Write-Output '===== KONEC ====='
