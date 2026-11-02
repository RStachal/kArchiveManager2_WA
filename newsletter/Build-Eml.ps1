<#
    Sestaví .eml pro import do Outlooku.

    Proč System.Net.Mail a ne ruční MIME: korektně zakóduje UTF-8 češtinu
    v hlavičkách i v tělech a sestaví multipart/related s CID obrázky.
    SmtpClient s DeliveryMethod = SpecifiedPickupDirectory nic neodesílá,
    jen zapíše hotový .eml na disk.

    Proč se hotový soubor ještě upravuje: LinkedResource v System.Net.Mail
    neumí nastavit Content-Disposition. Bez "inline" zařadí klienti obrázek
    mezi přílohy a cid: odkaz v těle pak nerozliší - obrázky se nezobrazí.
    Doplňuje se proto dodatečně do hotového MIME.
#>
[CmdletBinding()]
param(
    [string] $Dir      = $PSScriptRoot,
    [string] $OutFile  = 'kArchiveManager-2.0-newsletter.eml',
    [string] $From     = 'radim.stachal@kodys.cz',
    [string] $To       = 'radim.stachal@kodys.cz',
    [string] $PdfFile  = 'kArchiveManager-2.0-newsletter.pdf',
    [string] $Subject  = "k.Archive Manager 2.0 $([char]0x2014) univerz$([char]0x00E1)ln$([char]0x00ED) auditovan$([char]0x00E1) archivace dat WMS"
)

$ErrorActionPreference = 'Stop'
# System.Net.Mail zije v System.dll, ktera je v PowerShellu uz nactena - zadny Add-Type.

$utf8 = New-Object System.Text.UTF8Encoding($false)

$htmlPath = Join-Path $Dir 'body.html'
$textPath = Join-Path $Dir 'body.txt'
foreach ($p in @($htmlPath, $textPath)) {
    if (-not (Test-Path $p)) { throw "Chybi soubor: $p" }
}

# Obrazky: CID -> soubor. CID musi mit tvar local@domain (RFC 2045) a presne
# odpovidat src="cid:..." v body.html.
$images = [ordered]@{
    'kodyslogo@kam.kodys.cz' = Join-Path $Dir 'kodys-logo.png'
    'shotrfl@kam.kodys.cz'   = Join-Path $Dir 'shot_rfl.png'
    'shotruns@kam.kodys.cz'  = Join-Path $Dir 'shot_runs.png'
    'shotdash@kam.kodys.cz'  = Join-Path $Dir 'shot_dash.png'
}
foreach ($cid in $images.Keys) {
    if (-not (Test-Path $images[$cid])) { throw "Chybi obrazek pro cid:$cid -> $($images[$cid])" }
}

$html = [System.IO.File]::ReadAllText($htmlPath, $utf8)
$text = [System.IO.File]::ReadAllText($textPath, $utf8)

# Kazde cid: v HTML musi mit svuj soubor a naopak
$used = [regex]::Matches($html, 'src="cid:([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$have = @($images.Keys) | Sort-Object
$missing = $used | Where-Object { $_ -notin $have }
$unused  = $have | Where-Object { $_ -notin $used }
if ($missing) { throw "HTML odkazuje na cid bez souboru: $($missing -join ', ')" }
if ($unused)  { throw "Obrazek bez odkazu v HTML: $($unused -join ', ')" }

$rootCid = 'htmlbody@kam.kodys.cz'

$msg = New-Object System.Net.Mail.MailMessage
try {
    $msg.From = New-Object System.Net.Mail.MailAddress($From, 'KODYS - WMS tym', $utf8)
    $msg.To.Add($To)
    $msg.Subject         = $Subject
    $msg.SubjectEncoding = $utf8
    $msg.BodyEncoding    = $utf8
    $msg.Headers.Add('X-Unsent', '1')   # Outlook otevre jako rozepsanou zpravu, ne jako prijatou

    $plain = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString(
                 $text, $utf8, 'text/plain')
    $msg.AlternateViews.Add($plain)

    $view = [System.Net.Mail.AlternateView]::CreateAlternateViewFromString(
                $html, $utf8, 'text/html')
    $view.ContentId = $rootCid          # korenova cast multipart/related
    foreach ($cid in $images.Keys) {
        $lr = New-Object System.Net.Mail.LinkedResource($images[$cid], 'image/png')
        $lr.ContentId        = $cid
        $lr.ContentType.Name = [System.IO.Path]::GetFileName($images[$cid])
        $view.LinkedResources.Add($lr)
    }
    $msg.AlternateViews.Add($view)

    # Tistitelna podoba jako skutecna priloha (vyrabi Build-Pdf.ps1).
    $pdfPath = Join-Path $Dir $PdfFile
    if (-not (Test-Path $pdfPath)) { throw "Chybi PDF priloha: $pdfPath (spust nejdriv Build-Pdf.ps1)" }
    $att = New-Object System.Net.Mail.Attachment($pdfPath, 'application/pdf')
    $att.Name                        = $PdfFile
    $att.NameEncoding                = $utf8
    $att.ContentDisposition.FileName = $PdfFile
    $att.ContentDisposition.Inline   = $false
    $msg.Attachments.Add($att)

    $pickup = Join-Path $Dir 'pickup'
    if (Test-Path $pickup) { Remove-Item $pickup -Recurse -Force }
    New-Item -ItemType Directory -Path $pickup | Out-Null

    $smtp = New-Object System.Net.Mail.SmtpClient
    $smtp.DeliveryMethod          = [System.Net.Mail.SmtpDeliveryMethod]::SpecifiedPickupDirectory
    $smtp.PickupDirectoryLocation = $pickup
    $smtp.Send($msg)

    $produced = Get-ChildItem $pickup -Filter *.eml | Select-Object -First 1
    if (-not $produced) { throw 'SmtpClient nezapsal zadny .eml.' }

    # --- doplneni toho, co System.Net.Mail neumi -------------------------------
    # Soubor je po zakodovani ciste 7bit ASCII, takze se da bezpecne upravit jako text.
    $raw = [System.IO.File]::ReadAllText($produced.FullName, [System.Text.Encoding]::ASCII)

    # 1) Content-Disposition: inline u kazde obrazkove casti.
    $inlined = 0
    $raw = [regex]::Replace($raw,
        '(?m)^Content-Type: image/png; name=(?<n>[^\r\n]+)\r\n(?<enc>Content-Transfer-Encoding: base64\r\n)(?<cid>Content-ID: <[^>]+>\r\n)',
        {
            param($m)
            $script:inlined++
            $n = $m.Groups['n'].Value.Trim('"')
            "Content-Type: image/png; name=`"$n`"`r`n" +
            $m.Groups['enc'].Value + $m.Groups['cid'].Value +
            "Content-Disposition: inline; filename=`"$n`"`r`n"
        })
    if ($inlined -ne $images.Count) {
        throw "Content-Disposition doplnen jen u $inlined z $($images.Count) obrazku - zmenil se tvar MIME?"
    }

    # 2) start= na multipart/related, aby bylo jednoznacne, ktera cast je telo.
    $before = $raw
    $raw = [regex]::Replace($raw,
        '(?m)^(Content-Type: multipart/related; type="text/html";)',
        "`$1 start=`"<$rootCid>`";")
    if ($raw -eq $before) { throw 'Nepodarilo se doplnit start= na multipart/related.' }

    [System.IO.File]::WriteAllText($produced.FullName, $raw, [System.Text.Encoding]::ASCII)
    # --------------------------------------------------------------------------

    $target = Join-Path $Dir $OutFile
    if (Test-Path $target) { Remove-Item $target -Force }
    Move-Item $produced.FullName $target
    Remove-Item $pickup -Recurse -Force

    $kb = [math]::Round((Get-Item $target).Length / 1KB, 1)
    Write-Output "OK: $target  ($kb KB)  - inline obrazku: $inlined"
}
finally {
    $msg.Dispose()
}
