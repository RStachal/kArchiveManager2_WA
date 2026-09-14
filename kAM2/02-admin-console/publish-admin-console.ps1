param(
    [string] $Configuration = "Release",
    [string] $OutputPath = ".\publish\kAM-admin-console",
    [switch] $DeployToIis,
    [string] $DeployPath = "",
    [string] $IisAppPoolName = "kAM Admin Console",
    [switch] $RunSmoke,
    [string] $SmokeBaseUrl = "http://localhost:8089"
)

$ErrorActionPreference = "Stop"

function Invoke-CheckedCommand {
    param(
        [string] $FilePath,
        [string[]] $Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
    }
}

function Invoke-RoboCopyMirror {
    param(
        [string] $SourcePath,
        [string] $TargetPath
    )

    & robocopy $SourcePath $TargetPath /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    $exitCode = $LASTEXITCODE
    if ($exitCode -ge 8) {
        throw "Robocopy failed with exit code $exitCode while copying '$SourcePath' to '$TargetPath'."
    }
}

function Stop-IisAppPoolIfRunning {
    param([string] $AppPoolName)

    Import-Module WebAdministration -ErrorAction Stop
    if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
        Write-Host "IIS app pool '$AppPoolName' was not found. Skipping stop." -ForegroundColor Yellow
        return
    }

    $state = (Get-WebAppPoolState -Name $AppPoolName).Value
    if ($state -eq "Started") {
        Write-Host "Stopping IIS app pool '$AppPoolName'..." -ForegroundColor Cyan
        Stop-WebAppPool -Name $AppPoolName
    }
}

function Start-IisAppPoolIfExists {
    param([string] $AppPoolName)

    Import-Module WebAdministration -ErrorAction Stop
    if (-not (Test-Path "IIS:\AppPools\$AppPoolName")) {
        Write-Host "IIS app pool '$AppPoolName' was not found. Skipping start." -ForegroundColor Yellow
        return
    }

    Write-Host "Starting IIS app pool '$AppPoolName'..." -ForegroundColor Cyan
    Start-WebAppPool -Name $AppPoolName
}

function Grant-IisPermissions {
    param(
        [string] $TargetPath,
        [string] $AppPoolName
    )

    $identity = "IIS AppPool\$AppPoolName"
    Write-Host "Granting read/execute to '$identity' on '$TargetPath'..." -ForegroundColor Cyan
    Invoke-CheckedCommand "icacls" @($TargetPath, "/grant", "${identity}:(OI)(CI)(RX)", "/T", "/C")

    $logsPath = Join-Path $TargetPath "logs"
    if (-not (Test-Path -LiteralPath $logsPath)) {
        New-Item -ItemType Directory -Path $logsPath | Out-Null
    }

    Write-Host "Granting modify on logs folder to '$identity'..." -ForegroundColor Cyan
    Invoke-CheckedCommand "icacls" @($logsPath, "/grant", "${identity}:(OI)(CI)(M)", "/T", "/C")
}

function Invoke-SmokeChecks {
    param([string] $BaseUrl)

    $normalizedBaseUrl = $BaseUrl.TrimEnd('/')
    foreach ($path in @("/health", "/api/readiness")) {
        $url = "$normalizedBaseUrl$path"
        Write-Host "Smoke check: $url" -ForegroundColor Cyan
        $response = Invoke-WebRequest -Uri $url -Method Get -UseBasicParsing -TimeoutSec 30
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            throw "Smoke check failed for '$url' with status code $($response.StatusCode)."
        }
    }
}

function Write-DeploymentSummary {
    param(
        [string] $TargetPath,
        [string] $IisPath,
        [string] $AppPoolName,
        [string] $BaseUrl
    )

    $summaryPath = Join-Path $TargetPath "DEPLOYMENT_SUMMARY.txt"
    $normalizedBaseUrl = $BaseUrl.TrimEnd('/')
    $lines = @(
        "kAM Admin Console deployment summary",
        "Generated: $([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')) UTC",
        "",
        "Publish path: $TargetPath",
        "IIS deploy path: $IisPath",
        "IIS app pool: $AppPoolName",
        "",
        "Required IIS/app settings:",
        "- ConnectionStrings__ArchiveManagerAdmin",
        "- AdminConsole__EditPasswordSha256",
        "",
        "Verification URLs:",
        "- $normalizedBaseUrl/health",
        "- $normalizedBaseUrl/api/readiness",
        "- $normalizedBaseUrl/",
        "",
        "Required SQL deployment/check scripts:",
        "- legacy/ArchiveManager1.0/deploy/v2/classic-ssms/20_update_frontend_read_api.sql through 30_frontend_api_readiness_check.sql",
        "- legacy/ArchiveManager1.0/deploy/v2/classic-ssms/32_update_frontend_iis_principal_permissions.sql",
        "- legacy/ArchiveManager1.0/deploy/v2/classic-ssms/33_update_frontend_concurrency_metadata.sql",
        "- legacy/ArchiveManager1.0/deploy/v2/smoke-tests/28_frontend_api_readiness_smoke.sql",
        "- legacy/ArchiveManager1.0/deploy/v2/smoke-tests/30_frontend_iis_principal_permissions_smoke.sql",
        "",
        "Customer runbook:",
        "- legacy/ArchiveManager1.0/docs/admin-console-customer-deploy-runbook.md"
    )

    Set-Content -Path $summaryPath -Value $lines -Encoding UTF8
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$webProject = Join-Path $scriptRoot "KArchiveManager.AdminConsole.Web"
$apiProject = Join-Path $scriptRoot "KArchiveManager.AdminConsole.Api"
$apiCsproj = Join-Path $apiProject "KArchiveManager.AdminConsole.Api.csproj"
$frontendDist = Join-Path $webProject "dist"
$apiWwwroot = Join-Path $apiProject "wwwroot"
if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $publishPath = [System.IO.Path]::GetFullPath($OutputPath)
}
else {
    $publishPath = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot $OutputPath))
}

Write-Host "Building kAM Admin Console frontend..." -ForegroundColor Cyan
Push-Location $webProject
try {
    if (-not (Test-Path -LiteralPath (Join-Path $webProject "node_modules"))) {
        Invoke-CheckedCommand "npm" @("ci")
    }
    Invoke-CheckedCommand "npm" @("run", "build")
}
finally {
    Pop-Location
}

Write-Host "Copying frontend build into API wwwroot..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $apiWwwroot) {
    Remove-Item -LiteralPath $apiWwwroot -Recurse -Force
}
New-Item -ItemType Directory -Path $apiWwwroot | Out-Null
Copy-Item -Path (Join-Path $frontendDist "*") -Destination $apiWwwroot -Recurse -Force

Write-Host "Publishing API and frontend package..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $publishPath) {
    Remove-Item -LiteralPath $publishPath -Recurse -Force
}
Invoke-CheckedCommand "dotnet" @("publish", $apiCsproj, "-c", $Configuration, "-o", $publishPath, "/p:UseAppHost=false")

$publishedIndex = Join-Path $publishPath "wwwroot\index.html"
if (-not (Test-Path -LiteralPath $publishedIndex)) {
    throw "Publish package does not contain frontend index.html: $publishedIndex"
}

Write-Host ""
Write-Host "Publish completed:" -ForegroundColor Green
Write-Host $publishPath
Write-Host ""
Write-DeploymentSummary -TargetPath $publishPath -IisPath "" -AppPoolName $IisAppPoolName -BaseUrl $SmokeBaseUrl

if ($DeployToIis) {
    if ([string]::IsNullOrWhiteSpace($DeployPath)) {
        throw "When -DeployToIis is used, -DeployPath must be provided."
    }

    $resolvedDeployPath = [System.IO.Path]::GetFullPath($DeployPath)
    Write-Host "Deploying package to IIS path..." -ForegroundColor Cyan
    Stop-IisAppPoolIfRunning -AppPoolName $IisAppPoolName

    if (-not (Test-Path -LiteralPath $resolvedDeployPath)) {
        New-Item -ItemType Directory -Path $resolvedDeployPath | Out-Null
    }

    Invoke-RoboCopyMirror -SourcePath $publishPath -TargetPath $resolvedDeployPath
    Grant-IisPermissions -TargetPath $resolvedDeployPath -AppPoolName $IisAppPoolName
    Start-IisAppPoolIfExists -AppPoolName $IisAppPoolName

    Write-Host ""
    Write-Host "IIS deploy completed:" -ForegroundColor Green
    Write-Host $resolvedDeployPath
    Write-DeploymentSummary -TargetPath $resolvedDeployPath -IisPath $resolvedDeployPath -AppPoolName $IisAppPoolName -BaseUrl $SmokeBaseUrl

    if ($RunSmoke) {
        Write-Host ""
        Invoke-SmokeChecks -BaseUrl $SmokeBaseUrl
        Write-Host "Smoke checks passed." -ForegroundColor Green
    }
}
else {
    Write-Host "Copy this folder to the IIS web application directory."
}
