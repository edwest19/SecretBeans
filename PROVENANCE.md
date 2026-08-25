# Provenance

This file records who wrote this software, how it was tested, and — just as importantly —
what has **not** been verified. It is meant to be read by a person or an AI agent auditing
the project before trusting it with financial records.

## Authorship

Every file in this repository was written by **Claude, Anthropic's AI assistant**, during
Claude Code sessions with **Edwin West** in August 2026.

Claude wrote all of the code, the templates and the documentation. Edwin West set the
requirements, made the design decisions, supplied the real financial data it was developed
against, and reviewed the results at each step.

The design decisions were his, not Claude's:

- the journal is rebuilt from CSVs on every run, rather than appended to
- nothing is hand-entered — the rules files are the single source of truth
- each period folder holds 24 months and is self-contained
- Windows PowerShell 5.1 is the target, so it runs on any Windows machine unmodified
- the rules travel with the CSVs they were used on

Claude raised objections to the first two of those (a rebuild destroys hand-entered work; a
24-month window loses older history) and they were overruled deliberately, with the
consequences understood. Both are recorded in the README.

## This project is not endorsed by Anthropic

Claude is made by Anthropic. This project is not an Anthropic product, is not reviewed by
Anthropic, and carries no warranty from them. "Written by Claude" describes who typed it,
nothing more.

## Copyright

The LICENSE names Edwin West as copyright holder. Whether, and to what extent, AI-written code
attracts copyright is unsettled and varies by jurisdiction; this note records the fact of AI
authorship so anyone relying on the licence can take their own view. Nothing here is legal
advice.

`LICENSE` is left as the unmodified MIT text, with no attribution header, because licence
scanners match it verbatim. It is the one file here that carries no Claude attribution, and
that is deliberate.

## Which Claude

The sessions ran on a Claude Code environment configured for the model identifier
`claude-opus-5`. The model actually serving any given turn can differ from the configured one,
so this is the configuration rather than a guarantee about every line.

## What was tested, and how

Development used a real dataset: 24 months of Chase exports for five accounts — two credit
cards, two checking accounts and a savings account — roughly 2,200 transactions.

Verified:

- **The full pipeline runs end to end.** Downloads matched to accounts, period folder created,
  journal rebuilt, diagnostics produced. `hledger check` passes on the result.
- **The output reconciles against the source.** Every posting in the rebuilt journal was
  compared transaction by transaction with the bank's own CSV rows, including the running
  `Balance` column the bank supplies. All three bank accounts matched exactly: 356/356, 42/42
  and 345/345 rows.
- **The duplicate detector finds real duplicates.** It was written after this class of bug was
  found by hand in the source ledger, and it independently re-found the same 31 duplicated
  transfers in a clean rebuild. After the ownership rules were applied it reported zero.
- **It does not over-report.** The four pairs it still flags were checked against the raw CSVs
  and are genuine: the bank really does report two identical large transfers on one day. They are
  flagged for a human, never deleted.
- **It runs on Windows PowerShell 5.1, its target.** Confirmed 24 August 2026 by Edwin West:

      PowerShell : 5.1.26100.9168  (Desktop)
      OS         : Microsoft Windows NT 10.0.26200.0
      hledger    : 1.51.2-ge59e1837a-20260108, windows-x86_64
      15 checks passed, 0 failed

- **The window has been used end to end, on real data.** Edwin West clicked through all five
  steps on 24 August 2026 and imported 24 months of five Chase accounts: 2,211 transactions,
  `hledger check` passed, nothing uncategorised, no cross-statement duplicates, and every cheque
  assigned through the window's own review grid.

  It took several rounds to get there, and what the real run found is worth listing, because
  none of it was caught by construction checks or by testing on Linux:

  - templates were copied verbatim on a first run, so every account collapsed into one called
    `CHANGEME`
  - the template mapped the bank's balance column to hledger's `balance` field, turning it into
    a balance assertion that then failed
  - the window showed one line of a ten-line hledger error, because `$ErrorActionPreference`
    set to `Stop` turns native stderr into a terminating exception
  - grids ran off the right edge: anchored controls added to a panel still at its default
    200x100 size get a huge negative right margin
  - **`Build again` overwrote edited rules with the template**, silently breaking the whole
    review loop - the single worst bug in the project so far
  - `@()` around a `List[object]` throws on this PowerShell build, on the exact line that filled
    the review grid

  Each now has a check that would catch it again.

- **The window constructs on Windows.** The self-check builds the whole five-step form, verifies
  every control is present and on the panel it belongs to, and disposes it — without showing it.
  Passing on the run above. This check found one real misunderstanding while being written:
  `Control.Visible` reports *effective* visibility, so on a form that has never been shown every
  panel reads `$false` no matter what was assigned to it.

  Development and testing were done on PowerShell 7.4.6 on Linux, so this was the open
  question until that run. It passed first time, with no changes needed.
- **The build report the window shows.** `Format-SbDiagnostics` is deliberately separate from
  any window control so it can be tested without a display; it was checked against a real
  2,211-transaction build.
- **A self-check that anyone can re-run.** `tests\Test-SecretBeans.ps1` builds a small synthetic
  ledger in a temp folder, exercises config round-tripping, config validation, file matching,
  period creation, rebuild, `hledger check`, diagnostics, opening balances, the build report and
  rebuild reproducibility, that edited rules survive a rebuild, and that assigning a category
  writes a rule that works and replaces rather than stacks on reassignment - then deletes it.
  17 checks on Windows, 16 elsewhere. The GUI construction check runs only on
  Windows and is skipped elsewhere. It found two real bugs while being
  written: a scope error in the test itself, and an opening balance formatted with the machine's
  locale, which would have written `2.000,00` on a German Windows and been unreadable by hledger.
- **hledger version behaviour.** Tested against hledger 1.51.2. The `&&` matcher used by many
  published rules files requires hledger 1.32 or newer and fails *silently* on older versions,
  so the templates avoid it.

## What has NOT been tested

Read this part before trusting the tool.

- **Only Chase exports have been seen.** The design does not depend on any institution — the
  `.rules` file declares the CSV's shape — but that generality is a design claim, not a tested
  one. Only `bank` and `card` rules templates ship, and both are Chase-shaped.
- **Investment, loan, payment-app and HSA accounts are unhandled.** Those exports carry share
  quantities, principal-and-interest splits and other structures nothing here has been tried
  against.
- **Verified on one Windows machine, not many.** Everything above was run on a single machine
  with one locale, one hledger build, one Windows version and one display scaling. Nothing has
  been tried on a non-English locale (where number formatting differs - a bug of exactly that
  kind was found and fixed during development), an older Windows, a high-DPI display, or a
  machine where hledger is installed somewhere unusual.

## Auditing this yourself

The design is meant to make auditing cheap:

- Each period folder holds the CSVs, the rules used on them and the journal produced. Delete
  the journal, rebuild, and you should get it back byte for byte.
- `generated.journal` says at the top that it is generated and will be overwritten. Every
  transaction in it traces to one CSV row through one rules file.
- The only inputs that are not a CSV are the opening balances, which you type from a statement,
  and they appear in one clearly-labelled `opening.journal`.

If a rebuild does not reproduce a journal you were given, do not trust that journal.

---

*Written by Claude (Anthropic) with Edwin West, August 2026.*
