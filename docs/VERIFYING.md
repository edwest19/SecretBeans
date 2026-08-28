# Verifying a release

A signature answers one question: **did this come from the publisher, unchanged?**

It does not say the code is correct, or safe, or does what the README claims. Those you
establish by reading it and running its self-check. Signing and reviewing are different
jobs, and a signature that gets mistaken for an audit is worse than no signature.

## Three ways, in increasing order of effort

### 1. The catalogue — checks every file at once

`SecretBeans-<version>.cat` lists every file in the release with its hash, and is signed as
a whole. Put it beside the unpacked folder and run:

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
Get-ChildItem -Recurse -Filter *.ps1 | Get-AuthenticodeSignature | Format-Table Status, Path
```

Every one should say `Valid`. `NotSigned` on some files means the release signed only the
catalogue — which is fine, and covers them all; see above.

A signed script also runs under a `RemoteSigned` or `AllSigned` execution policy without
being unblocked first.

## Then check it actually works

```powershell
powershell -ExecutionPolicy Bypass -File tests\Test-SecretBeans.ps1
```

Builds a small ledger in a temporary folder, runs its checks, deletes it. Touches nothing of
yours and needs no configuration. That tells you the code runs correctly here, which is a
different and more useful thing than knowing who sent it.

## What none of this covers

- **That the code is correct.** Read [PROVENANCE.md](../PROVENANCE.md); it records what was
  tested, and what was not.
- **That it is safe to run.** It is PowerShell, it is short, and it is meant to be read. The
  only thing it writes to is the ledger folder in your configuration.
- **That the maintainer is trustworthy.** A certificate proves an identity was validated, not
  that the person behind it deserves your confidence.

---

*Written by Claude (Anthropic) with Edwin West, August 2026. Not an Anthropic product — see
[PROVENANCE.md](../PROVENANCE.md).*
