# SecretBeans

**Written by Claude (Anthropic)** with Edwin West, August 2026.
Not an Anthropic product and not reviewed by Anthropic.
[PROVENANCE.md](PROVENANCE.md) records who wrote what, what was tested, and what was not.

A step-by-step importer that turns bank and credit-card CSV downloads into an
[hledger](https://hledger.org) journal, on Windows, with a GUI.

Every run creates a dated folder holding the CSVs, the rules used on them, and the journal
they produced. The journal is rebuilt from scratch each time, so changing a rule and
rebuilding always gives you the same answer — there is never a stale transaction left over
from an earlier run.

## Why another importer

Two mistakes cost real money and are invisible in the usual reports. SecretBeans is built
around catching both.

**A transfer between two accounts you own appears on both statements.** Move $2,400 from
savings to checking and both exports report it. Import both and the transfer is counted
twice — the outflow doubled, the inflow doubled. Expense totals stay correct, so nothing
looks wrong. In the ledger this was built from, **37 transfers** were double-counted, to a
six-figure total.

**A credit-card payment does the same thing**, once on the card statement and once on the
bank statement. Same shape, same silence: **57 payments** counted twice.

SecretBeans reports both classes after every build, before you accept it, and distinguishes
the dangerous case (one event on two statements) from the harmless one (a statement genuinely
listing the same amount twice).

## How it works

Nothing here knows the shape of your CSV. The `.rules` file beside it already declares its
columns, date format and account — which is why an institution SecretBeans has never seen
works by writing a rules file, not by changing the tool.

Your configuration only maps a downloaded file name to a short, stable name:

```powershell
@{
    Accounts = @(
        @{ Name='freedom';  Match='Chase1234*'; Account='liabilities:creditcard:chase:freedom'; Type='card' }
        @{ Name='primary';  Match='Chase5678*'; Account='assets:bank:chase:checking:primary';   Type='bank' }
        @{ Name='broker';   Match='*Fidelity*'; Account='assets:investment:fidelity';           Type='investment' }
    )
}
```

Downloads are named differently every month (`Chase1234_Activity_20260821.csv`), which is why
the short name matters: it is what the rules file, the journal and the next month's build all
key on.

## Running it

```
powershell -ExecutionPolicy Bypass -File SecretBeans.ps1
```

## A run

1. Point it at the folder your downloads landed in
2. Check the file-to-account matches it worked out, and fix any it got wrong
3. Confirm the period name — `2026-09 September`
4. It copies the CSVs and last period's rules into a new folder and builds
5. **It shows you what is uncategorised, what needs review, and what looks duplicated.
   Edit the rules, rebuild, repeat until you are happy**
6. Accept

Step 5 is the point of the whole thing. Rebuilding from scratch is what makes it safe to
keep correcting rules until the answer is right.

## Check it works on your machine

```
powershell -ExecutionPolicy Bypass -File tests\Test-SecretBeans.ps1
```

Builds a small synthetic ledger in a temporary folder, runs 13 checks against it, and deletes
it. It never touches your data and needs no configuration. If it passes, SecretBeans works on
your machine.

## Requirements

- Windows PowerShell 5.1 — built into Windows, nothing to install
- [hledger](https://hledger.org/install.html) on PATH

## Status

Used end to end on Windows PowerShell 5.1.26100.9168 with hledger 1.51.2: 24 months of five
Chase accounts, 2,211 transactions, `hledger check` passed, nothing uncategorised. 17 self-checks
passing. One machine, one locale — see [PROVENANCE.md](PROVENANCE.md) for what that does and
does not cover. That was one machine with one locale; see [PROVENANCE.md](PROVENANCE.md) for what that
does and does not cover.

Working end to end: configuration, file matching, period folders, rebuild, diagnostics, and a
five-step window with a review loop that writes rules for you.

In progress:

- starter rules for investment, loan, payment-app and HSA exports. Only `bank` and `card`
  templates ship today. Those two are real; the others need writing against actual exports
  rather than being guessed at, so an account with no template gets a commented stub and a
  build that still runs.

## Layout

```
SecretBeans.ps1        launcher - run this
src\                   the modules, including SbGui.ps1
tools\                 Build-Release.ps1
templates\             a config to copy, and starter rules per account type
docs\                  TRANSFERS.md is worth reading before your first import
```

## Releases

Each release ships a signed catalogue covering every file, plus SHA-256 checksums.
[docs/VERIFYING.md](docs/VERIFYING.md) explains how to check them, and [docs/SIGNING.md](docs/SIGNING.md) covers producing one — and, just as importantly,
what a signature does and does not prove.

## Auditing it

The project is built to be checked rather than trusted. Each period folder holds the CSVs, the
rules used on them and the journal produced — delete the journal, rebuild, and you should get it
back byte for byte. Every transaction traces to one CSV row through one rules file. The only
input that is not a CSV is the opening balance you type from a statement, and it lives alone in
`opening.journal`.

If a rebuild does not reproduce a journal you were handed, do not trust that journal.

[PROVENANCE.md](PROVENANCE.md) lists what was verified and how, and what was not.

## Licence

MIT. Copyright (c) 2026 Edwin West. Written by Claude (Anthropic) — see
[PROVENANCE.md](PROVENANCE.md).
