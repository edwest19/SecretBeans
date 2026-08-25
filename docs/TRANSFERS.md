# Transfers between your own accounts

This is the mistake that costs the most and shows the least.

## What happens

Move $2,400 from savings to checking. Both statements report it, so both CSVs contain it, and
each produces a transaction:

```
2024-10-21 Online Transfer from MMA ...3456 transaction#: 10293847566
    assets:bank:chase:checking:primary       $2,400.00
    equity:start                            -$2,400.00      <- from the checking export

2024-10-21 Online Transfer to CHK ...5678 transaction#: 10293847566 10/21
    assets:bank:chase:savings               -$2,400.00
    assets:bank:chase:checking:primary       $2,400.00      <- from the savings export
```

Checking is credited **twice**. Worse, each export only knows its *own* account and has to
guess the far end — above, the checking side guessed wrong and dumped it in `equity:start`.

Every expense figure stays perfectly correct, which is why this survives for years.

## The fix: one account owns each pair

Choose an order for your accounts. The higher account records the transfer; the lower one
skips it. Any consistent order works — what matters is that exactly one side records it.

With `primary > secondary > savings`:

**primary.csv.rules** — highest, so it records every transfer it is part of:

```
if %description Transfer (from|to) (SAV|MMA).*3456
  account2 assets:bank:chase:savings

if %description Transfer (from|to) CHK.*9012
  account2 assets:bank:chase:checking:secondary
```

**secondary.csv.rules** — records its transfers with savings, skips the ones primary owns:

```
if %description Transfer (from|to) (SAV|MMA).*3456
  account2 assets:bank:chase:savings

if %description Transfer (from|to) CHK.*5678
  skip
```

**savings.csv.rules** — lowest, so it skips every transfer with a tracked checking account:

```
if %description Transfer (from|to) CHK.*(5678|9012)
  skip
```

Put these at the **end** of the file. When several conditional blocks match, the last one
wins, so a block at the end overrides anything above it.

## Credit-card payments are the same problem

A card payment appears on the card statement as `Payment Thank You` and on the bank statement
as `CHASE CREDIT CRD EPAY`. Pick one owner. Prefer the **card** statement: it knows which card
was paid, while the bank description often does not. The cost is that the payment carries the
card's posting date, usually a day or two before the cash left the bank.

```
# in the bank's rules file
if %description CHASE CREDIT CRD
  skip
```

## Never use a catch-all for the far end

A rule like `account2 equity:start` for anything you have not identified will hide this
problem indefinitely. `equity:start` absorbs any amount without complaint and never looks
wrong in a report. Send unidentified transfers somewhere that stands out — an
`expenses:review` account you check after every import.

## What SecretBeans checks

After each build it looks for transactions where every posting is an asset, liability or
equity account — transfers, not purchases — and flags pairs with the same amount within a few
days. Two identical purchases on one day are ordinary life; two identical *transfers* usually
are not.

It reports whether the pair came from two different statements or one. Two statements is the
costly bug. One statement listing the same amount twice is usually two real transfers, so it
is shown but ranked lower. Neither is deleted automatically.

---

*Written by Claude (Anthropic) with Edwin West, August 2026. Not an Anthropic product — see [PROVENANCE.md](../PROVENANCE.md).*

The double-counting described here was found in a real ledger during development: 37
transfers and 57 card payments, each recorded twice, and every one of them invisible in an
expense report. The account numbers and amounts in the examples above are invented; the
mechanism is not.
