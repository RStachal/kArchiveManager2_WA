<#
.SYNOPSIS
    Nasadi celou databazovou cast kArchiveManager 2.0 nad WMS Edge jednim krokem.

.DESCRIPTION
    Spoji do jedne sekvence vse, co se jinak spousti po castech: zalozeni
    databazi, jadro, konfiguraci planu Edge, archivni tabulky, pozadavky na
    indexy, profily behu, behovy ucet, ucet konzole, operatora konzole a joby
    SQL Agenta. Na konci vypise vygenerovana hesla - jedinkrat, nikam je
    neuklada.

    Bez -Clean odmitne prepsat existujici nasazeni. S -Clean obe databaze
    SMAZE a zalozi znovu; pred smazanim vypise, co v archivu je, a jestli tam
    jsou radky, vyzaduje navic -IConfirm.

    Zdrojove databaze WMS se NEDOTYKA - krome zvyseni compatibility level, a to
    jen kdyz to vyslovne povolite prepinacem -RaiseCompatLevel.

    Zadna diakritika ani BOM: skript putuje mezi stroji a Windows PowerShell 5.1
    cte soubor bez BOM jako ANSI, cimz by se diakritika v retezcich rozbila.

.PARAMETER SourceDb
    Zdrojova databaze WMS Edge (napr. KMWE).

.PARAMETER ConsoleOnSqlServer
    Konzole pobezi na tomto stroji -> pouzije se Windows autentizace identitou
    aplikacniho fondu IIS a SQL login pro konzoli se nezaklada. Jinak vznikne
    login karch_console s vygenerovanym heslem.

.EXAMPLE
    .\Deploy-Database.ps1 -Server localhost -SourceDb KMWE

.EXAMPLE
    # znovu nanecisto, vcetne smazani predchoziho nasazeni
    .\Deploy-Database.ps1 -Server localhost -SourceDb KMWE -Clean -IConfirm
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Server,
    [Parameter(Mandatory = $true)] [string] $SourceDb,
    [string[]] $AdditionalSourceDbs = @(),
    [string] $AdminDb       = 'kArchiveManagerAdmin',
    [string] $ArchiveDb     = 'kArchiveManagerBackups',
    [int]    $RetentionDays = 450,          # 15 mesicu
    [string] $Timezone      = 'Central European Standard Time',
    [string] $RunnerLogin   = 'karch_runtime_svc',
    [string] $ConsoleLogin  = 'karch_console',
    [string] $OperatorName  = 'admin',
    [switch] $ConsoleOnSqlServer,
    [switch] $RaiseCompatLevel,
    [switch] $Clean,
    [switch] $IConfirm,
    [string] $RepoRoot      = ''
)

$ErrorActionPreference = 'Stop'
$krok = 0
function Nadpis($t) { $script:krok++; Write-Host "`n== $script:krok) $t" -ForegroundColor Cyan }
function Ok($t)     { Write-Host "   OK   $t" -ForegroundColor Green }
function Warn($t)   { Write-Host "   !!   $t" -ForegroundColor Yellow }

# sqlcmd -b vraci nenulovy kod pri chybe; bez nej chyby tise projdou
function Sql {
    param([string] $Query, [string] $Db = 'master')
    $out = & sqlcmd -S $Server -E -b -d $Db -h-1 -W -s'|' -Q $Query 2>&1
    if ($LASTEXITCODE -ne 0) { throw "SQL selhalo v $Db`:`n$($out -join "`n")" }
    return @($out | Where-Object { $_ -match '\S' })
}
function SqlFile {
    param([string] $Path, [string] $Db = 'master')
    $log = Join-Path $env:TEMP ("kam_" + [IO.Path]::GetFileNameWithoutExtension($Path) + '.log')
    & sqlcmd -S $Server -E -b -d $Db -i $Path -o $log 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        $t = if (Test-Path $log) { (Get-Content $log | Where-Object { $_ -match 'Msg |Error' } | Select-Object -First 5) -join "`n" } else { '' }
        throw "Skript selhal: $Path`n$t`nCely vypis: $log"
    }
    return $log
}

# Nahradi deklaraci promenne ve zdroji skriptu a vrati cestu k docasne kopii.
# Nahrazuje VZDY JEN PRVNI VYSKYT - pojistky nize si musi zachovat zastupny text.
function NewTempSql {
    param([string] $Source, [hashtable] $Replace)
    if (-not (Test-Path $Source)) { throw "Chybi skript: $Source" }
    $t = [IO.File]::ReadAllText($Source, [Text.Encoding]::UTF8)
    foreach ($k in $Replace.Keys) {
        $i = $t.IndexOf($k)
        if ($i -lt 0) { throw "Ve skriptu $Source nenalezen vzor: $k" }
        $t = $t.Substring(0, $i) + $Replace[$k] + $t.Substring($i + $k.Length)
    }
    $tmp = Join-Path $env:TEMP ('kam_' + [IO.Path]::GetFileName($Source))
    [IO.File]::WriteAllText($tmp, $t, (New-Object Text.UTF8Encoding($true)))   # BOM kvuli SSMS i sqlcmd
    return $tmp
}

# Hash hesla operatora. Dodavany navod posila na "dotnet ... hash-password", coz
# by do balicku pritahlo celou aplikaci (11 MB) a vyzadovalo dotnet na SQL serveru.
# Format je PBKDF2-SHA256$<iteraci>$<base64 sul>$<base64 klic>, tedy PBKDF2 s
# HMAC-SHA256, 100 000 iteraci, sul 16 B, klic 32 B. Overeno proti vystupu
# aplikace na shodnem paru - vysledek je bajt za bajtem stejny.
function New-OperatorHash {
    param([Parameter(Mandatory = $true)][string] $Password)
    $iter = 100000
    $salt = [byte[]]::new(16)
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $k = New-Object Security.Cryptography.Rfc2898DeriveBytes(
            $Password, $salt, $iter, [Security.Cryptography.HashAlgorithmName]::SHA256)
    try { $key = $k.GetBytes(32) } finally { $k.Dispose() }
    return 'PBKDF2-SHA256$' + $iter + '$' + [Convert]::ToBase64String($salt) + '$' + [Convert]::ToBase64String($key)
}

function NewPassword {
    $ok = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'.ToCharArray()
    $sp = '-_.#+='.ToCharArray()
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    $b = [byte[]]::new(24); $rng.GetBytes($b)
    (-join ($b[0..20] | ForEach-Object { $ok[$_ % $ok.Length] })) +
    (-join ($b[21..23] | ForEach-Object { $sp[$_ % $sp.Length] }))
}

# Kde balicek lezi. Nelze to dat jako vychozi hodnotu do param(): pri spusteni
# pres "powershell -File .\Deploy-Database.ps1" je $PSScriptRoot v dobe
# vyhodnocovani param() prazdny a skript spadl na "Cannot bind argument to
# parameter 'Path' because it is an empty string" jeste pred prvnim krokem.
# V tele skriptu uz naplneny je; $MyInvocation je zaloha pro ostatni zpusoby.
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
    }
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = (Get-Location).Path }
}
if (-not (Test-Path (Join-Path $RepoRoot 'sql'))) {
    throw "V $RepoRoot neni slozka sql. Spoustejte skript ze slozky, kam jste balicek rozbalili, nebo predejte -RepoRoot."
}

# Pri spusteni pres "powershell -File" prijde -AdditionalSourceDbs KMWESK,KMWEPL
# jako JEDEN retezec, ne pole. Rozdelime ho proto sami; na bezne volani z konzole
# to nema vliv.
$AdditionalSourceDbs = @($AdditionalSourceDbs | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$vsechnyZdroje = @($SourceDb) + $AdditionalSourceDbs

$sqlDir  = Join-Path $RepoRoot 'sql'
$addOns  = Join-Path $RepoRoot 'kAM2\01-database\operational-add-ons'
$appDir  = Join-Path $RepoRoot 'kAM2\02-admin-console\app'
$hesla   = [ordered]@{}

Write-Host "`n=== kArchiveManager 2.0 - nasazeni databazove casti ===" -ForegroundColor White
Write-Host "    server $Server / zdroj $SourceDb / retence $RetentionDays dni"

# ---------------------------------------------------------------- 1) predpoklady
Nadpis 'Predpoklady'
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) { throw 'Chybi sqlcmd (Microsoft Command Line Utilities for SQL Server).' }
$exist = Sql -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(10), COUNT(*)) FROM sys.databases WHERE name = N'$SourceDb';"
if ("$exist".Trim() -ne '1') { throw "Zdrojova databaze $SourceDb neexistuje." }
$compat = ("$(Sql -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(5), compatibility_level) FROM sys.databases WHERE name = N'$SourceDb';")").Trim()
Ok "zdroj $SourceDb existuje, compatibility level $compat"

# Compat < 130: TRY_CONVERT neni k dispozici a konfigurace logu by selhala.
# POZOR: precheck tvrdi, ze selze AT TIME ZONE - to je nepresne, ta funguje
# i na urovni 100. Skutecne chybi TRY_CONVERT.
if ([int]$compat -lt 130) {
    if (-not $RaiseCompatLevel) {
        throw @"
$SourceDb je na compatibility level $compat. Konfigurace logu pouziva TRY_CONVERT,
ktery vyzaduje 130 a vys. Bud spustte s -RaiseCompatLevel (ZMENI CHOVANI
OPTIMALIZATORU WMS DATABAZE - u zakaznika vyzaduje souhlas dodavatele WMS),
nebo upravte vyraz na TRY_CAST, ktery funguje i na urovni 100.
"@
    }
    Warn "zvysuji compatibility level $SourceDb ze $compat na 130"
    $null = Sql -Query "ALTER DATABASE [$SourceDb] SET COMPATIBILITY_LEVEL = 130;"
    Ok 'compatibility level 130'
}

# --------------------------------------------------------------- 2) uklid
Nadpis 'Stav predchoziho nasazeni'
$jsou = ("$(Sql -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(5), COUNT(*)) FROM sys.databases WHERE name IN (N'$AdminDb', N'$ArchiveDb');")").Trim()
if ($jsou -ne '0') {
    if (-not $Clean) { throw "Databaze uz existuji ($jsou ze 2). Pro nasazeni nanecisto pouzijte -Clean." }

    # Archiv je po smazani zdrojoveho radku jedina kopie - nikdy ho nemazat naslepo.
    $radky = '0'
    if (("$(Sql -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(5), COUNT(*)) FROM sys.databases WHERE name = N'$ArchiveDb';")").Trim() -eq '1') {
        $radky = ("$(Sql -Db $ArchiveDb -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(20), ISNULL(SUM(p.rows),0)) FROM sys.tables t JOIN sys.partitions p ON p.object_id=t.object_id AND p.index_id IN (0,1);")").Trim()
    }
    Write-Host "   v archivu $ArchiveDb je radku: $radky"
    if ([int64]$radky -gt 0 -and -not $IConfirm) {
        throw "Archiv obsahuje $radky radku. Smazani by o ne neodvratne prislo - potvrdte prepinacem -IConfirm."
    }
    foreach ($d in @($AdminDb, $ArchiveDb)) {
        if (("$(Sql -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(5), COUNT(*)) FROM sys.databases WHERE name = N'$d';")").Trim() -eq '1') {
            $null = Sql -Query "ALTER DATABASE [$d] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$d];"
            Ok "smazano: $d"
        }
    }
}
else { Ok 'zadne predchozi nasazeni' }

# ------------------------------------------------------- 3) databaze a jadro
Nadpis 'Databaze a jadro produktu'
& (Join-Path $RepoRoot 'Run-Deploy.ps1') -Server $Server -SourceDb $SourceDb `
    -AdminDb $AdminDb -ArchiveDb $ArchiveDb -RetentionDays $RetentionDays `
    -SourceTimezone $Timezone -Stage deploy | Out-Null
if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw 'Faze deploy selhala, podrobnosti v _logs.' }
Ok 'databaze, jadro, verify, samotesty i variantni sada'

# ------------------------------------------------------- 4) konfigurace Edge
Nadpis 'Konfigurace planu WMS Edge'
$cfg = NewTempSql -Source (Join-Path $sqlDir '60_configure_kmwe_edge.sql') -Replace @{
    "DECLARE @SourceDb   sysname = N'KMWE';"   = "DECLARE @SourceDb   sysname = N'$SourceDb';"
    "DECLARE @Retention  int     = 450;"       = "DECLARE @Retention  int     = $RetentionDays;"
}
$null = SqlFile -Path $cfg -Db $AdminDb
Remove-Item $cfg -Force
$plany = Sql -Db $AdminDb -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(12), p.ProcessCode) + ' (' + CONVERT(varchar(10), p.SelectionStrategy) + ', tabulek ' + CONVERT(varchar(3), (SELECT COUNT(*) FROM arch.ObjectSpec o WHERE o.ProcessId=p.ProcessId)) + ')' FROM arch.Process p ORDER BY p.ProcessCode;"
$plany | ForEach-Object { Ok $_ }

# -------------------------------------------------- 5) archivni tabulky
Nadpis 'Archivni tabulky'
foreach ($p in @('RECEIVING', 'SHIPPING', 'RF_LOG2')) {
    $null = Sql -Db $AdminDb -Query "EXEC arch.usp_ProvisionArchiveTablesForProcess @ProcessCode=N'$p', @SourceDb=N'$SourceDb', @ArchiveDb=N'$ArchiveDb';"
}
$tab = ("$(Sql -Db $ArchiveDb -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(5), COUNT(*)) FROM sys.tables;")").Trim()
Ok "zalozeno tabulek: $tab (ve schematu $SourceDb)"

# --------------------------------------------------------- 6) profily behu
# JOB_DEFAULT zaklada jen 04_seed_order.sql, coz je seed pro AAD. Pri nasazeni
# nad Edge by joby na prvni spusteni spadly, proto se zaklada tady.
Nadpis 'Profily behu'
$null = Sql -Db $AdminDb -Query @"
IF NOT EXISTS (SELECT 1 FROM arch.RunProfile WHERE RunProfileCode = N'JOB_DEFAULT')
    EXEC arch.usp_Api_SaveRunProfile @RunProfileCode=N'JOB_DEFAULT', @RequestedBy=N'deploy',
         @ChangeReason=N'Profil pro joby PREP/RUN', @Description=N'Vychozi profil jobu',
         @IsEnabled=1, @RunOnSchedule=1, @RunOrder=100, @RunWindowMinutes=55, @DryRun=0, @PausedCooldownSeconds=0;
IF NOT EXISTS (SELECT 1 FROM arch.RunProfile WHERE RunProfileCode = N'DRY')
    EXEC arch.usp_Api_SaveRunProfile @RunProfileCode=N'DRY', @RequestedBy=N'deploy',
         @ChangeReason=N'Zkouska nanecisto', @Description=N'Beh nanecisto, nic nemaze',
         @IsEnabled=1, @RunOnSchedule=0, @RunOrder=900, @SourceDbFilter=N'$SourceDb',
         @RunWindowMinutes=55, @DryRun=1, @PausedCooldownSeconds=0;
"@
Ok 'JOB_DEFAULT (ostry, okno 55 min) a DRY (nanecisto)'

# ----------------------------------------------- 6b) cheap-mode pro log
# Validace to sama doporucuje: odstrani AT TIME ZONE z kandidatniho scanu, coz
# je u produkcnich objemu logu (stovky milionu radku) dominantni naklad.
# Driv se to zapinalo rucne a pri kazdem cistem nasazeni se to ztratilo.
Nadpis 'Cheap-mode pro systemovy log'
$null = Sql -Db $AdminDb -Query "EXEC arch.usp_Api_ApplyConfigFix @ActionKey=N'ENABLE_CHEAP_MODE', @ProcessCode=N'RF_LOG2', @SourceDb=N'$SourceDb';"
Ok "$SourceDb - cheap-mode zapnut"

# ------------------------------------------- 6c) dalsi zdrojova prostredi
# Plany jsou na zdrojove databazi nezavisle, takze dalsi prostredi znamena jen
# radky v arch.ProcessDatabase. Prepisy zustavaji NULL, takze plati tataz
# pravidla; archivni schema vznikne pod nazvem zdrojove databaze, cimz se CZ a
# SK oddeli v teze archivni databazi.
if ($AdditionalSourceDbs.Count -gt 0) {
    Nadpis 'Dalsi zdrojova prostredi'
    $poradi = 2000
    foreach ($db in $AdditionalSourceDbs) {
        $compatDb = ("$(Sql -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(5), compatibility_level) FROM sys.databases WHERE name = N'$db';")").Trim()
        if (-not $compatDb) { throw "Zdrojova databaze $db neexistuje." }
        if ([int]$compatDb -lt 130) {
            if (-not $RaiseCompatLevel) { throw "$db je na compatibility level $compatDb; konfigurace logu vyzaduje 130. Spustte s -RaiseCompatLevel." }
            $null = Sql -Query "ALTER DATABASE [$db] SET COMPATIBILITY_LEVEL = 130;"
            Warn "$db - compatibility level $compatDb na 130"
        }
        $cfg2 = NewTempSql -Source (Join-Path $sqlDir '62_add_source_database.sql') -Replace @{
            "DECLARE @SourceDb   sysname = N'KMWESK';" = "DECLARE @SourceDb   sysname = N'$db';"
            'DECLARE @RunOrderBase int   = 2000;'      = "DECLARE @RunOrderBase int   = $poradi;"
        }
        $null = SqlFile -Path $cfg2 -Db $AdminDb
        Remove-Item $cfg2 -Force
        foreach ($p in @('RECEIVING', 'SHIPPING', 'RF_LOG2')) {
            $null = Sql -Db $AdminDb -Query "EXEC arch.usp_ProvisionArchiveTablesForProcess @ProcessCode=N'$p', @SourceDb=N'$db', @ArchiveDb=N'$ArchiveDb';"
        }
        $null = Sql -Db $AdminDb -Query "EXEC arch.usp_Api_ApplyConfigFix @ActionKey=N'ENABLE_CHEAP_MODE', @ProcessCode=N'RF_LOG2', @SourceDb=N'$db';"
        Ok "$db - plany namapovany, archivni schema zalozeno, cheap-mode zapnut"
        $poradi += 1000
    }
}

# ------------------------------------------------------------ 7) behovy ucet
Nadpis 'Behovy ucet jobu'
$hesla[$RunnerLogin] = NewPassword
$r = NewTempSql -Source (Join-Path $addOns '053_runtime_least_privilege_principal.sql') -Replace @{
    "N'<<SET-A-STRONG-PASSWORD>>'"       = "N'$($hesla[$RunnerLogin])'"
    "N'KMWEBV,Edge,KMWE_Test,AAD'"       = "N'$($vsechnyZdroje -join ',')'"
    '@Apply               bit           = 0'  = '@Apply               bit           = 1'
}
$null = SqlFile -Path $r -Db $AdminDb
Remove-Item $r -Force
# 053 existujici login nechava byt, takze heslo se musi nastavit zvlast
$null = Sql -Query "ALTER LOGIN [$RunnerLogin] WITH PASSWORD = N'$($hesla[$RunnerLogin])', CHECK_POLICY = ON, CHECK_EXPIRATION = OFF; ALTER LOGIN [$RunnerLogin] ENABLE;"
$sysadm = ("$(Sql -Query "SET NOCOUNT ON; SELECT CASE WHEN IS_SRVROLEMEMBER('sysadmin', N'$RunnerLogin') = 1 THEN 'ANO' ELSE 'ne' END;")").Trim()
if ($sysadm -eq 'ANO') { throw "$RunnerLogin je sysadmin - joby ho odmitnou (chyba 51001). Odeberte mu roli." }
Ok "${RunnerLogin}: prava na $SourceDb (SELECT+DELETE) a archiv (INSERT+SELECT, bez DELETE), neni sysadmin"

# ------------------------------------------------------------ 8) ucet konzole
Nadpis 'Ucet konzole'
if ($ConsoleOnSqlServer) {
    Ok 'konzole pobezi zde -> Windows autentizace identitou fondu IIS, SQL login se nezaklada'
    Warn 'prava identite fondu prideli Deploy-Console.ps1'
}
else {
    $hesla[$ConsoleLogin] = NewPassword
    $c = NewTempSql -Source (Join-Path $sqlDir '61_console_principal_sql_login.sql') -Replace @{
        "DECLARE @Password  nvarchar(128) = N'<<SET-A-STRONG-PASSWORD>>';" = "DECLARE @Password  nvarchar(128) = N'$($hesla[$ConsoleLogin])';"
        "DECLARE @SourceDbs nvarchar(4000) = N'KMWE';   -- CSV: KMWE,KMWESK" = "DECLARE @SourceDbs nvarchar(4000) = N'$($vsechnyZdroje -join ',')';"
        "DECLARE @Apply     bit           = 0;"                            = "DECLARE @Apply     bit           = 1;"
    }
    $null = SqlFile -Path $c -Db 'master'
    Remove-Item $c -Force
    Ok "${ConsoleLogin}: pet roli karch_*, cteni v archivu a ve vsech zdrojich ($($vsechnyZdroje -join ', ')), cteni msdb"
    Warn 'Bezi-li jeste stara konzole, zastavte jeji aplikacni fond. Ma v promenne fondu'
    Warn 'predchozi heslo, hlasi se s nim kazdych ~30 s a po par minutach ucet ZAMKNE -'
    Warn 'a zamceny ucet pak odmitne i nove heslo, takze konzoli uz nenasadite.'
}

# ------------------------------------------- 9) operatorske API a operator
# Bez techto grantu hlasi konzole "Edit access not configured" a nikdo se
# neprihlasi k editaci. Dodavany 061_console_operators.sql v balicku chybi.
Nadpis 'Operator konzole'
$null = Sql -Db $AdminDb -Query @"
DECLARE @g nvarchar(max) = N'';
SELECT @g += N'GRANT EXECUTE ON ' + QUOTENAME(s.name) + N'.' + QUOTENAME(p.name) + N' TO ' + QUOTENAME(r.name) + N';'
FROM sys.procedures p JOIN sys.schemas s ON s.schema_id = p.schema_id
CROSS JOIN (SELECT name FROM sys.database_principals WHERE name IN (N'karch_config_admin', N'karch_advanced_admin') AND type = 'R') r
WHERE p.name IN (N'usp_Api_GetConsoleOperatorForAuth', N'usp_Api_ListConsoleOperators',
                 N'usp_Api_SaveConsoleOperator', N'usp_Api_DeleteConsoleOperator');
EXEC sys.sp_executesql @g;
"@
Ok 'EXECUTE na operatorske API prideleno rolim karch_config_admin a karch_advanced_admin'

$hesla["operator $OperatorName"] = NewPassword
$hash = New-OperatorHash $hesla["operator $OperatorName"]
if ($hash -notmatch '^PBKDF2-SHA256\$100000\$') { throw "Vypocet hashe selhal: $hash" }

$o = NewTempSql -Source (Join-Path $addOns '064_console_default_operator.sql') -Replace @{
    "N'CHANGE-ME';   -- <-- paste hash-password output here" = "N'$hash';"
}
$null = SqlFile -Path $o -Db $AdminDb
Remove-Item $o -Force
Ok "operator '$OperatorName' zalozen (povoleny, elevovany)"

# --------------------------------------------------------------- 10) joby
Nadpis 'Joby SQL Agenta'
$j = NewTempSql -Source (Join-Path $sqlDir '56_agent_jobs.sql') -Replace @{
    'DECLARE @Apply         bit           = 0;' = 'DECLARE @Apply         bit           = 1;'
}
$null = SqlFile -Path $j -Db 'msdb'
Remove-Item $j -Force
Sql -Db 'msdb' -Query "SET NOCOUNT ON; SELECT CONVERT(varchar(46), j.name) + ' | vlastnik ' + CONVERT(varchar(20), SUSER_SNAME(j.owner_sid)) + ' | ' + CASE j.enabled WHEN 1 THEN 'zapnuty' ELSE 'vypnuty' END FROM dbo.sysjobs j WHERE j.name LIKE 'kArchiveManager%' ORDER BY j.name;" | ForEach-Object { Ok $_ }

# ------------------------------------------------------------ 11) overeni
Nadpis 'Overeni'
foreach ($db in $vsechnyZdroje) {
    $v = Sql -Db $AdminDb -Query "SET NOCOUNT ON; EXEC arch.usp_ValidateConfiguration @SourceDb=N'$db';"
    $chyby = @($v | Where-Object { $_ -match '^ERROR' }).Count
    $varov = @($v | Where-Object { $_ -match '^WARN'  }).Count
    if ($chyby -gt 0) { Warn "${db}: validace konfigurace: $chyby chyb, $varov varovani"; $v | Where-Object { $_ -match '^ERROR' } | ForEach-Object { Write-Host "      $_" } }
    else { Ok "${db}: validace konfigurace bez chyb ($varov varovani)" }

    $i = Sql -Db $AdminDb -Query "SET NOCOUNT ON; EXEC arch.usp_ValidateIndexRequirements @SourceDb=N'$db';"
    $iw = @($i | Where-Object { $_ -match '^WARN' }).Count
    Ok "${db}: indexy - $iw nepokrytych pozadavku (jen varovani, zpracovani neblokuji; DDL se nikdy nespousti do WMS)"

    foreach ($p in @('RECEIVING', 'SHIPPING', 'RF_LOG2')) {
        $null = Sql -Db $AdminDb -Query "EXEC arch.usp_VerifyRunnerPrivileges @ProcessCode=N'$p', @SourceDb=N'$db';"
    }
    Ok "${db}: opravneni behoveho uctu overena u vsech tri planu"
}

# Konzole cte pres vsechna prostredi najednou. Kdyz ji chybi uzivatel byt v
# jednom z nich, dashboard spadne cely na chybe 916 - a aplikace misto toho
# poradi "zkontrolujte connection string", takze se hleda uplne jinde. Proto
# se to overuje tady, dokud je kdo opravit.
if (-not $ConsoleOnSqlServer) {
    $nedostupne = @()
    foreach ($db in (@($AdminDb, $ArchiveDb) + $vsechnyZdroje)) {
        $r = Sql -Db 'master' -Query @"
SET NOCOUNT ON;
EXECUTE AS LOGIN = N'$ConsoleLogin';
BEGIN TRY
    DECLARE @n int;
    SELECT @n = COUNT(*) FROM [$db].sys.tables;
    PRINT 'OK';
END TRY
BEGIN CATCH PRINT 'CHYBA ' + CONVERT(varchar(10), ERROR_NUMBER()); END CATCH
REVERT;
"@
        if (-not ($r -join ' ').Contains('OK')) { $nedostupne += $db }
    }
    if ($nedostupne.Count -gt 0) { Warn ("konzole NEDOSAHNE na: " + ($nedostupne -join ', ') + " - dashboard bude hlasit chybu") }
    else { Ok ("konzole dosahne na vsechny databaze (" + ((@($AdminDb, $ArchiveDb) + $vsechnyZdroje) -join ', ') + ")") }
}
# --------------------------------------------------------------- hotovo
Write-Host "`n=== Hotovo ===" -ForegroundColor Green
Write-Host "`nHESLA - vypisuji se jedinkrat, nikam se neukladaji:" -ForegroundColor Yellow
foreach ($k in $hesla.Keys) { Write-Host ("   {0,-28} {1}" -f $k, $hesla[$k]) -ForegroundColor Yellow }
Write-Host "`nDalsi kroky:" -ForegroundColor Cyan
Write-Host '   1. Nasadit konzoli: console\Deploy-Console.ps1'
Write-Host '   2. PREP a RUN jsou zalozene VYPNUTE - rozvrh nastavit az po overeni'
Write-Host '      (doporuceni: PREP jednou denne tesne po pracovni dobe, RUN hodinove v okne)'
Write-Host '   3. Prvni ostry beh je samostatne rozhodnuti - nic se zatim nesmazalo'
