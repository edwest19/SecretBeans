# Verifying a release

A signature answers one question: **did this come from the publisher, unchanged?**

It does not say the code is correct, or safe, or does what the README claims. Those you
establish by reading it and running its self-check. Signing and reviewing are different
jobs, and a signature that gets mistaken for an audit is worse than no signature.

## Before you start

A release is three files: `SecretBeans-<version>.zip`, `SecretBeans-<version>.cat` and
`SecretBeans-<version>.sha256`. The zip has no folder of its own inside it, so unpack it
into a new folder named `SecretBeans-<version>`, and keep the `.cat` and `.sha256` beside
that folder. The commands below assume that layout and are run from the folder that holds
all three.

Check a freshly unpacked copy, before you add a configuration file or run anything. The
catalogue and the checksums describe the files exactly as released, and a file you have
since edited will not match them.

## Three ways, in increasing order of effort

### 1. The catalogue — checks every file at once

`SecretBeans-<version>.cat` lists every file in the release with its hash, and is signed as
a whole:

```powershell
Test-FileCatalog -CatalogFilePath SecretBeans-<version>.cat -Path .\SecretBeans-<version> -Detailed
```

`Valid` means every file matches the catalogue and the catalogue's signature is intact.
`ValidationFailed` names the file that differs.

To see who signed it:

```powershell
Get-AuthenticodeSignature SecretBeans-<version>.cat | Format-List Status, SignerCertificate
```

### 2. The checksums — needs no signing infrastructure

`SecretBeans-<version>.sha256` is plain text: one SHA-256 hash and a path per line. Check
the lot:

```powershell
Get-Content SecretBeans-<version>.sha256 | ForEach-Object {
    $hash, $file = $_ -split '\s+', 2
    $actual = (Get-FileHash ".\SecretBeans-<version>\$file" -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $hash) { "CHANGED: $file" }
}
```

Silence means everything matched. This proves the files are the ones the checksum file
describes — but only that, since anyone who could alter the files could alter the checksums
too. It is a useful cross-check, not a substitute for the signature.

### 3. The scripts themselves

If the release ships signed `.ps1` files:

```powershell
Get-ChildItem .\SecretBeans-<version> -Recurse -Filter *.ps1 | Get-AuthenticodeSignature | Format-Table Status, Path
```

Every one should say `Valid`. `NotSigned` on some files means the release signed only the
catalogue — which is fine, and covers them all; see above.

A signed script does not need unblocking under a `RemoteSigned` execution policy. Instead,
the first time it runs, PowerShell asks whether you trust its publisher, and runs it only
if you answer Run once or Always run. That is how Microsoft's `about_Signing` help
describes it.

## Then check it actually works

```powershell
powershell -ExecutionPolicy Bypass -File tests\Test-SecretBeans.ps1
```

Builds a small ledger in a temporary folder, runs its checks, deletes it. Touches nothing of
yours and needs no configuration, though it does need hledger installed. That tells you the
code runs correctly here, which is a different and more useful thing than knowing who sent
it.

## What none of this covers

- **That the code is correct.** Read [PROVENANCE.md](../PROVENANCE.md); it records what was
  tested, and what was not.
- **That it is safe to run.** It is PowerShell, it is short, and it is meant to be read.
  Everything it writes is listed in the next section.
- **That the maintainer is trustworthy.** A certificate proves an identity was validated, not
  that the person behind it deserves your confidence.

## What SecretBeans writes

It writes in two places.

**The configuration file** you choose in step 1. SecretBeans rewrites it:

- in step 1, if you change the ledger root there, and
- every time you press Next on step 3 (opening balances), whether or not anything changed.

The file is rewritten from scratch. Comments you added, and any setting SecretBeans does not
know about, are dropped. The opening balances you type in step 3 are stored in it as plain
text.

**The ledger root** named in that configuration, which is created if it does not exist.
Each build makes or reuses a period folder inside it, holding:

- `csv` — copies of your downloads, renamed. The originals stay where they were.
- `rules` — one rules file per account, taken from the previous period if it has one, and
  otherwise made from a template. Choosing a category in the window adds or updates a rule
  in the matching file.
- `journal` — four journal files, rewritten on every build.
- `reports` — created empty.

SecretBeans itself deletes nothing. It does overwrite: the journal files on every build, and
the CSV copies each time you build the same period again. A rules file already in the
period folder is never replaced by a copy from elsewhere.

It reads your downloads folder, the previous period's rules and its own templates without
changing them. It runs hledger — `print` to read each CSV, `check` on the result — and opens
File Explorer when you press a button that shows a folder.

*Corrected November 2026: the August version of this page said the only thing SecretBeans
writes to is the ledger folder. That was wrong. It also rewrites the configuration file, as
described above.*

---

*Written by Claude (Anthropic) with Edwin West, August 2026, and corrected November 2026.
Not an Anthropic product and not reviewed by Anthropic — see
[PROVENANCE.md](../PROVENANCE.md).*
