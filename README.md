# SecretBeans

**Written by Claude (Anthropic)** with Edwin West, August 2026.
Not an Anthropic product and not reviewed by Anthropic.
[PROVENANCE.md](PROVENANCE.md) records who wrote what, what was tested, and what was not.

SecretBeans turns bank and credit-card CSV downloads into an [hledger](https://hledger.org)
journal. It runs on Windows, through a five-step window.

Each run creates a dated folder holding the CSVs, the rules used on them, and the journal they
produced. The journal is rebuilt from scratch every time, so changing a rule and building again
always gives the same answer — no stale transaction is ever left over from an earlier run.

- [Why another importer](#why-another-importer)
- [What you need](#what-you-need)
- [First-time setup](#first-time-setup)
- [Each month](#each-month)
- [What a run produces](#what-a-run-produces)
- [Using the journal with hledger, on this machine or another](#using-the-journal-with-hledger-on-this-machine-or-another)
- [Status and known limits](#status-and-known-limits)
- [Auditing it](#auditing-it)

## Why another importer

Two mistakes cost real money and are invisible in the usual reports. SecretBeans is built
around catching both.

**A transfer between two accounts you own appears on both statements.** Move $2,400 from
savings to checking and both exports report it. Import both and the transfer is counted
twice — the outflow doubled, the inflow doubled. Expense totals stay correct, so nothing
looks wrong. The ledger this was built from had **37** such transfers.

**A credit-card payment does the same thing**, once on the card statement and once on the
bank statement. Same shape, same silence: **57** payments counted twice.

SecretBeans reports both after every build, before you accept it, and tells the dangerous case
(one event on two statements) apart from the harmless one (a statement genuinely listing the
same amount twice). It never deletes anything by itself. [docs/TRANSFERS.md](docs/TRANSFERS.md)
explains how to fix them; read it before your first import.

## What you need

- **Windows PowerShell 5.1.** It is built into Windows; there is nothing to install.
- **hledger**, from [hledger.org/install](https://hledger.org/install.html). SecretBeans looks
  for it on PATH first, then in the usual Windows install folders. If yours is somewhere else,
  start SecretBeans with `-HledgerPath` pointing at `hledger.exe`.

## First-time setup

**1. Get SecretBeans.** Download the release from the
[Releases page](https://github.com/edwest19/SecretBeans/releases) and unzip it. To confirm it
came from the publisher unchanged, follow [docs/VERIFYING.md](docs/VERIFYING.md).

**2. Check it works on your machine.** In a PowerShell window, from the SecretBeans folder:

```powershell
powershell -ExecutionPolicy Bypass -File tests\Test-SecretBeans.ps1
```

This builds a small made-up ledger in a temporary folder, runs its checks (19 on Windows; the
check that builds the window only runs on Windows), and deletes it. It never touches your data
and needs no configuration.

**3. Write a configuration file.** The configuration tells SecretBeans one thing: which
downloaded file belongs to which account. Copy `templates\config.psd1` somewhere private —
**not** into a public repository, because it names your accounts — and edit it:

```powershell
@{
    LedgerRoot    = 'C:\Users\you\Ledger'    # where period folders are created
    Currency      = '$'
    OpeningEquity = 'equity:opening balances'
    ReviewAccount = 'expenses:review'        # anything the rules can't place goes here

    Accounts = @(
        @{ Name='freedom'; Match='Chase1234*'; Account='liabilities:creditcard:chase:freedom'; Type='card' }
        @{ Name='primary'; Match='Chase5678*'; Account='assets:bank:chase:checking:primary';   Type='bank' }
    )
}
```

- `Name` is a short, stable name. It becomes the CSV's and the rules file's name, so letters,
  digits, dot, dash and underscore only.
- `Match` is a wildcard for the download's file name. Banks name each download differently
  (`Chase1234_Activity_20260821.csv`), which is why the stable `Name` matters.
- `Type` picks the starter rules on the first run. Only `bank` and `card` exist today; any
  other type gets a minimal stub you fill in.
- `LedgerRoot` should be a folder that holds **nothing but period folders** — see the warning
  under [Each month](#each-month).

SecretBeans writes this file back when you change the ledger root or the opening balances in the
window, and the rewritten file does not keep your comments.

Nothing here describes a CSV's columns. Each account's `.rules` file does that, which is why an
institution SecretBeans has never seen needs a rules file, not a change to the tool.

**4. Start it.**

```powershell
powershell -ExecutionPolicy Bypass -File SecretBeans.ps1 -ConfigPath C:\path\to\config.psd1 -DownloadFolder C:\path\to\downloads
```

Both are optional. Without `-ConfigPath`, SecretBeans looks for `config.psd1` beside
`SecretBeans.ps1`, and you can browse to it in the first step of the window instead.
`-DownloadFolder` defaults to your Downloads folder.

## Each month

1. **Download a CSV for every account, covering the whole period you want in the ledger** — not
   just the new month. Each period folder is built only from the CSVs inside it; nothing is
   carried over from last month except the rules. Put the downloads in one folder, ideally with
   nothing else in it.
2. **Run SecretBeans** and go through the window:

   | Step | What you do |
   |---|---|
   | 1. Where things are | Confirm the configuration file, the ledger root and the downloads folder. |
   | 2. Matches | Check which download it matched to which account. **Every account should say `Ok`.** An account marked `Missing` is left out of this period's journal, but any opening balance it has stays in, so its balance will be wrong. `Ambiguous` means more than one download matched; it used the newest. |
   | 3. Opening balances | What each account held just before the earliest transaction, from a statement. It fills in last period's figures, which are still right only if your downloads start on the same date as last time. |
   | 4. Build | Name the period (it suggests the current month, e.g. `2026-11 November`) and build. **Read the report: uncategorised, awaiting review, and possible duplicates.** Type a category beside anything it could not place and it writes the rule for you. The rule matches that description exactly (`if %description ^...$`), so it claims nothing else. Edit rules, build again, repeat until it is right. |
   | 5. Done | Shows where the journal is and the hledger command to report on it. |

Step 4 is the point of the whole thing. Because every build starts from the CSVs, you can keep
correcting rules until the answer is right without ever accumulating mistakes.

Next period's rules start from this period's, so every correction you make carries forward. A
sudden jump in uncategorised transactions on a new period means that did not happen — see below.

> **Keep the ledger root for period folders only.** To find last period, SecretBeans takes the
> last folder in the ledger root in name order. Any other folder there whose name sorts after
> the periods — `Import`, `notes`, `reports` — is taken as last period instead, and the new
> period starts from the starter templates rather than your corrected rules. Keep downloads and
> anything else outside the ledger root, and keep the default `yyyy-MM` start to period names.

## What a run produces

```
<LedgerRoot>\
  2026-11 November\
    csv\        the downloads, renamed to each account's Name
    rules\      the rules used on them - edit these
    journal\
      main.journal       the entry point: point hledger here
      accounts.journal   every account used, so `hledger check accounts` passes
      opening.journal    the opening balances you typed in step 3
      generated.journal  every transaction, rebuilt from csv\ and rules\
    reports\
```

Everything in `journal\` is generated and overwritten on the next build. Change the rules, not
the journal.

## Using the journal with hledger, on this machine or another

`main.journal` is the file to give hledger. It pulls in the other three with relative paths, so
the `journal` folder works wherever it is copied or synced, and hledger can read it on any
operating system. The files are written as UTF-8 without a byte-order mark.

The last step of the window prints the exact command for your period. You can pass the path with
`-f`, or set the `LEDGER_FILE` environment variable so every hledger command uses it. Period
folder names contain a space, so quote the path.

**Always using the newest period.** Paste this into PowerShell to point hledger at the newest
period that has a journal, for the rest of that session. A period still being built or synced is
skipped:

```powershell
$root   = 'C:\path\to\Ledger'
$latest = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -match '^\d{4}-\d{2} ' -and
                         (Test-Path -LiteralPath (Join-Path $_.FullName 'journal\main.journal')) } |
          Sort-Object Name | Select-Object -Last 1
if ($latest) { $env:LEDGER_FILE = Join-Path $latest.FullName 'journal\main.journal' }
```

To have it in every session, put the same lines in your PowerShell profile — the file named by
`$PROFILE`. Put the lines themselves in that file, not commands that add them: a profile that
appends to itself grows by a copy every time PowerShell starts. A profile only runs if your
execution policy allows scripts; `Get-ExecutionPolicy -List` shows it. `hledger files` shows which
journal hledger is reading.

The same thing for bash or any POSIX shell:

```sh
ROOT="/path/to/Ledger"
latest=
for d in "$ROOT"/[0-9][0-9][0-9][0-9]-[0-9][0-9]*/; do latest=$d; done
if [ -f "${latest}journal/main.journal" ]; then
    export LEDGER_FILE="${latest}journal/main.journal"
fi
```

**Reading the ledger on another computer.** Make the ledger root reachable there — a synced
folder, a network share, or a copy — and run hledger on that computer. Only the `journal` folder
is needed for reporting.

- **OneDrive.** If the ledger root is in OneDrive, set it to *Always keep on this device* on the
  computer that reads it (right-click it in Explorer, or `attrib +p "<folder>"`). Otherwise new
  journal files can arrive online-only — `attrib` shows them with an `O` — and hledger run over
  SSH could not open them: it failed with `openFile: invalid argument`. Pinning the folder and the
  journal files with `attrib +p` fixed it. Whether pinning the folder also covers period folders
  added later has not been checked yet; `attrib` on a new period's journal files will show it.
- **Let the sync finish.** A build rewrites all four journal files. If the other computer reads
  them mid-sync, it can see a new `main.journal` alongside an old `generated.journal`.
- **Building needs Windows.** The other computer reads and reports; to change anything, edit the
  rules and build again in SecretBeans.

What was tested:

- A journal built by SecretBeans on one Windows computer, synced through OneDrive, and read by
  hledger 1.51.2 on a second Windows computer over SSH, once pinned as above. The PowerShell
  snippet ran there from a Windows PowerShell 5.1 profile and picked the newest period.
- The PowerShell snippet in PowerShell 7, including skipping a period with no journal yet, and the
  shell snippet in bash and dash.
- hledger 1.51.2 on Linux reading a journal folder made by SecretBeans's own build code, copied to
  another location with a space in its path, converted to Windows (CRLF) line endings, through both
  `-f` and `LEDGER_FILE` — reports identical to the original.

What was not: hledger older than 1.51.2 on the reading side.

## Status and known limits

Used end to end on Windows PowerShell 5.1.26100.9168 with hledger 1.51.2: 24 months of five
Chase accounts, 2,211 transactions, `hledger check` passed, nothing uncategorised. That was one
machine with one locale; see [PROVENANCE.md](PROVENANCE.md) for what that does and does not
cover.

Known limits:

- **Only Chase exports have been used.** The design does not depend on any institution, but that
  generality is a design claim, not a tested one.
- **Only `bank` and `card` starter rules ship.** Investment, loan, payment-app and HSA exports need
  a rules file written against a real export; until then they get a commented stub and a build
  that still runs.
- **One Windows machine, one locale.** A locale bug was found and fixed during development, so the
  risk on other locales is real rather than theoretical.

## Layout

```
SecretBeans.ps1      launcher - run this
src\                 the five modules: SbConfig, SbAccounts, SbBuild, SbJournal, SbGui
templates\           config.psd1 to copy, and starter rules per account type
tests\               Test-SecretBeans.ps1, the self-check
docs\                TRANSFERS.md, VERIFYING.md, SIGNING.md
tools\               Build-Release.ps1 and Sign-Release.ps1 (in the repository, not the release)
```

## Releases

Each release ships a signed catalogue covering every file, plus SHA-256 checksums.
[docs/VERIFYING.md](docs/VERIFYING.md) explains how to check them, and
[docs/SIGNING.md](docs/SIGNING.md) covers producing one — and what a signature does and does
not prove.

## Auditing it

The project is built to be checked rather than trusted. Each period folder holds the CSVs, the
rules used on them and the journal produced — delete the journal, build again, and you should
get it back byte for byte. Every transaction traces to one CSV row through one rules file. The
only input that is not a CSV is the opening balance you type from a statement, and it lives
alone in `opening.journal`.

If a rebuild does not reproduce a journal you were handed, do not trust that journal.

[PROVENANCE.md](PROVENANCE.md) lists what was verified and how, and what was not.

## Licence

MIT. Copyright (c) 2026 Edwin West. Written by Claude (Anthropic) — see
[PROVENANCE.md](PROVENANCE.md).
