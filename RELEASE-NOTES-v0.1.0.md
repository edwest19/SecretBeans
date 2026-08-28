# SecretBeans v0.1.0

First release. Turns bank and credit-card CSV downloads into an
[hledger](https://hledger.org) journal, on Windows, through a five-step window.

**Written by Claude (Anthropic)** with Edwin West. Not an Anthropic product and not reviewed
by Anthropic — see [PROVENANCE.md](PROVENANCE.md) for who wrote what, what was tested, and
what was not.

## What it does

Each run creates a dated folder holding the CSVs, the rules used on them, and the journal
they produced. The journal is rebuilt from scratch every time, so correcting a rule and
rebuilding always gives the same answer — there is never a stale transaction left behind.

The window walks it: point at your downloads → check the file-to-account matches → enter
opening balances → **build, read what it reports, fix the rules, build again** → done.

That fourth step is the point. It shows what is uncategorised, what needs review, and what
looks duplicated. Type a category beside anything it could not identify and it writes the
rule for you, keeping it for next period.

## Why it exists

Two mistakes cost real money and are invisible in ordinary reports.

**A transfer between two accounts you own appears on both statements.** Import both and it
is counted twice — outflow doubled, inflow doubled. Expense totals stay correct, so nothing
looks wrong. The ledger this was built from had 37 such transfers.

**A credit-card payment does the same**, once on the card statement and once on the bank's.
Same shape, same silence: 57 payments.

SecretBeans reports both after every build, before you accept it, and tells the dangerous
case (one event on two statements) apart from the harmless one (a statement genuinely listing
the same amount twice). It never deletes anything by itself.

## Requirements

- Windows PowerShell 5.1 — built into Windows, nothing to install
- [hledger](https://hledger.org/install.html) on PATH

## Verifying this release

See [docs/VERIFYING.md](docs/VERIFYING.md). Signature, catalogue and checksums are provided,
and the self-check runs against a synthetic ledger without touching your data:

```powershell
powershell -ExecutionPolicy Bypass -File tests\Test-SecretBeans.ps1
```

## Known limits

- Only Chase exports have been used. The design does not depend on any institution — the
  `.rules` file declares each CSV's shape — but that generality is untested.
- Only `bank` and `card` rules templates ship. Investment, loan, payment-app and HSA exports
  need a rules file written against a real export.
- Verified on one Windows machine with one locale. A locale bug of exactly that kind was
  found and fixed during development, so the risk is real rather than theoretical.
