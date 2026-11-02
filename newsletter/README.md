# Newsletter k vydání k.Archive Manager 2.0

Interní sdělení pro kolegy KODYS, vydané 8. 10. 2026. Tři podoby téhož obsahu:
webová stránka, tělo e-mailu a PDF příloha.

## Co je zdroj a co se generuje

Ve verzích jsou **jen zdroje**. Odvozené soubory se vyrábějí skripty a do gitu
nepatří (`.gitignore`).

| Soubor | Role |
| --- | --- |
| `newsletter.html` | **zdroj** webové podoby; na místě obrázků nese značky `PLACEHOLDER_RFL/_RUNS/_DASH` |
| `body.html` | **zdroj** těla e-mailu (tabulkový layout, odkazy `cid:`) |
| `body.txt` | **zdroj** textové alternativy e-mailu |
| `kodys-logo.png` | logo vyrenderované z firemního SVG konzole (Outlook neumí SVG) |
| `shot_rfl.png`, `shot_runs.png`, `shot_dash.png` | snímky Admin Console |
| `kArchiveManager-2.0-newsletter.pdf` | odeslaná příloha — ponechána jako záznam toho, co kolegové dostali |
| `newsletter_final.html`, `print.html`, `*.eml` | **generované**, neverzují se |

## Jak to sestavit

```powershell
.\Build-Web.ps1    # newsletter.html -> newsletter_final.html + print.html
.\Build-Pdf.ps1    # print.html      -> PDF (headless Edge, A4)
.\Build-Eml.ps1    # body.html+txt   -> .eml pro Outlook (vyžaduje hotové PDF)
```

Pořadí je závazné: `Build-Eml.ps1` bez existujícího PDF skončí chybou, takže
nemůže vzniknout e-mail bez přílohy. Jiný prohlížeč ani tiskárna potřeba nejsou,
PDF renderuje headless Edge.

`newsletter_final.html` je to, co se publikuje jako stránka.

## Proč jsou tři podoby, a ne jedna

Outlook renderuje Wordovým enginem, který nezná CSS proměnné, flexbox, grid ani
webové fonty a **blokuje obrázky v `data:` URI**. Webová podoba stojí na všech
čtyřech, takže by v Outlooku přišla jako bílá stránka bez obrázků. Tělo e-mailu
je proto postavené zvlášť: tabulkový layout, styly inline s doslovnými hexy,
náhradní fonty (Georgia místo Bitter, Segoe UI místo Source Sans) a obrázky jako
CID přílohy. Graf selektivity je v e-mailu sestavený z buněk s `bgcolor`, aby se
vykreslil i příjemci se zablokovaným stahováním obrázků.

PDF se tiskne z webové podoby, ne z těla e-mailu — má skutečné fonty a působí
jako dokument.

## Dvě pasti, na které se přišlo až za provozu

1. **`LinkedResource` v `System.Net.Mail` neumí nastavit `Content-Disposition`.**
   Bez `inline` zařadí klienti obrázek mezi přílohy a odkaz `cid:` v těle už
   k němu nepřiřadí — obrázky se nezobrazí a místo nich přibudou přílohy.
   `Build-Eml.ps1` proto hlavičku doplňuje do hotového MIME a ověří si, že ji
   dostaly všechny části; jinak skončí chybou.
2. **`Content-ID` musí mít tvar `<local@doména>`** (RFC 2045). Holý tvar
   `<shotrfl>` přísnější klienti odmítnou.

## Údaje, které je před dalším použitím nutné ověřit

Čísla v textu pocházejí z měření na referenční instanci v září 2026. Dvě místa
jsou vázaná na tehdejší konfiguraci:

- **Retence u `ADV_LOGMSG_ARCH` byla 23 dní**, u ostatních pěti sad 90. Text
  proto říká jen „u aplikačního logu kratší“, bez čísla.
- **Stopa na jednotlivý dokument (`AuditLevel = ROW`) byla zapnutá u dvou sad
  ze šesti.** Odrážka o auditu je formulovaná tak, aby to odpovídalo: rozlišuje,
  co se eviduje vždy, a co je volitelné. Při změně konfigurace je potřeba text
  zkontrolovat, ne jen čísla.
