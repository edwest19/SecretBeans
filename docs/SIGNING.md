# Signing a release

Notes for whoever publishes SecretBeans. Not needed to use it.

## The short version

Sign the **catalogue** (`.cat`) — one file covering every file in the release. Sign the
**scripts** (`.ps1`) too if your tooling supports it, because that is what lets people run
SecretBeans under a `RemoteSigned` or `AllSigned` execution policy without unblocking
anything.

The two are done by different tools, and which formats each supports is the thing to check
first.

## Which tool signs what

You need **both** tools. They are independent and each does what the other doesn't.

| | `.cat` | `.ps1` |
|---|---|---|
| `signtool` + the Artifact Signing dlib | yes | no |
| Sign CLI (`dotnet tool install sign`) | no | yes |

**Both were confirmed working against a real Artifact Signing account** (Public Trust
certificate profile, personal Microsoft account) on 28 August 2026, signing SecretBeans 0.1.0:
seven `.ps1` files and the catalogue, all timestamped, all verifying. Earlier drafts of this
page said `.ps1` support was undocumented and needed testing. It has now been tested, and it
works.

Nothing in SecretBeans depends on the scripts being signed — the catalogue covers every file
on its own. Signing the scripts is what additionally lets people run SecretBeans under a
`RemoteSigned` or `AllSigned` execution policy without unblocking anything.

## The three things signtool needs

**A timestamp URL.** `http://timestamp.acs.microsoft.com` for Trusted Signing. Timestamping
matters more than usual here: Trusted Signing certificates are short-lived, and a timestamp
is what keeps a signature valid after the certificate behind it has expired. Never sign
without one.

**A metadata file.** Create `metadata.json` yourself:

```json
{
  "Endpoint": "https://eus.codesigning.azure.net/",
  "CodeSigningAccountName": "your-signing-account",
  "CertificateProfileName": "your-cert-profile"
}
```

### Where each value comes from

All three are on the same resource in the Azure portal. Search for **Trusted Signing
Accounts** (shown in some tenants as Artifact Signing) and open your account.

| Key | Where |
|---|---|
| `Endpoint` | **Overview** blade → **Account URI** |
| `CodeSigningAccountName` | the resource name at the top of that same page |
| `CertificateProfileName` | left nav → **Objects** → **Certificate profiles** → the Name column |

`Endpoint` is region-specific and must match the region the account was created in. A
mismatch returns **403 Forbidden** with an internal `SignerSign()` failure — which reads like
a permissions problem and is not one. Copy the Account URI off the Overview blade rather than
deriving it from the region; for reference the form is `https://<region-code>.codesigning.azure.net`,
e.g. `eus` East US, `wus2` West US 2, `neu` North Europe, `weu` West Europe, `jpe` Japan East.
The full list is in [Microsoft's signing integrations page](https://learn.microsoft.com/en-us/azure/trusted-signing/how-to-signing-integrations#create-a-json-file).

Optional extra keys the dlib accepts, none of which SecretBeans needs: `CorrelationId` for
tagging a request with a build number, `ExcludeCredentials` for skipping authentication methods
that would otherwise be tried and time out, and `AccessToken` for supplying an Azure AD token
directly.

### Where the file goes

Anywhere — the full path is handed to signtool with `/dmdf`, so nothing depends on its
location. `C:\tools\metadata.json`, beside the dlib, is what the commands below assume.

Keep it **out of both repositories.** It names your signing endpoint, account and certificate
profile. `.gitignore` lists `metadata.json` as a backstop, but the right answer is for it not
to be in the repo folder at all.

**The dlib.** `Azure.CodeSigning.Dlib.dll` — the piece that teaches signtool to talk to the
service. Two ways to get it:

*Installer (easier).* [Azure/artifact-signing-clienttools releases](https://github.com/Azure/artifact-signing-clienttools/releases)
→ `ArtifactSigningClientTools.msi`. It bundles the dlib, signtool, the Windows SDK signing
tools and the .NET 8 runtime the dlib needs. As of v1.0.4 it installs everything into one flat
folder, `%LocalAppData%\Microsoft\MicrosoftArtifactSigningClientTools\`. `Sign-Release.ps1`
matches that folder by pattern rather than by exact name, since the product has already been
renamed once. Install it as the account you will sign from — a per-user MSI run elevated lands
in the administrator's profile instead.

*NuGet (manual).* The **Microsoft.ArtifactSigning.Client** package on nuget.org — this is the
current package; **Microsoft.Trusted.Signing.Client** is its unlisted predecessor from before
the Artifact Signing rename. Download the `.nupkg`, rename it to `.zip`, unzip, and take
`bin\x64\Azure.CodeSigning.Dlib.dll` or `bin\x86\` to match your signtool. You will also need
the .NET 8 Desktop Runtime installed separately.

Architecture has to match. An x86 dlib under x64 signtool fails with an error that never
mentions architecture, so `Sign-Release.ps1` reads the machine type out of the file's PE header
before it calls anything. The MSI's flat layout leaves nothing to infer from the path, and a
managed AnyCPU assembly reports a machine type that is not a CPU at all — in that case the
script says it could not tell rather than pretending it checked.

## One command

`tools\Sign-Release.ps1` does all of the below in the right order, refuses to continue at each
point where a mistake would otherwise go unnoticed, and reads your account details from
`metadata.json` so nothing account-specific is in this repository.

```powershell
tools\Sign-Release.ps1 -Version 0.1.0                 # catalogue only
tools\Sign-Release.ps1 -Version 0.1.0 -SignScripts    # scripts too
```

The rest of this page is what it does, for anyone who would rather drive it by hand or check
its work.

## Signing in

Nothing in `metadata.json` says who you are. The dlib works that out at signing time by walking
the Azure SDK's `DefaultAzureCredential` chain — environment variables, managed identity,
Visual Studio, Azure CLI, Azure PowerShell, and finally an interactive browser prompt.

**Log in before you sign, and the browser is never involved:**

```powershell
az login --tenant <your-tenant>.onmicrosoft.com
az account show
```

`AzureCliCredential` sits above `InteractiveBrowserCredential` in the chain, so a CLI login is
picked up first.

This is worth doing rather than clicking through the browser prompt, because the interactive
path has no tenant to aim at. With a personal Microsoft account it authenticates against a
generic tenant called **"Microsoft Services"**, where your signing account does not exist, and
fails with:

> Selected user account does not exist in tenant 'Microsoft Services' and cannot access the
> application '04b07795-8ddb-461a-bbee-02f9e1bf7b46' in that tenant.

That app ID is the Azure CLI's. The account is fine; the directory is wrong. `az login
--tenant` names the directory explicitly and the problem disappears.

### Sign CLI needs telling as well

Sign CLI does its own authentication, separately from the dlib, and left to itself it walks the
whole `DefaultAzureCredential` chain. On a machine that is not an Azure VM,
`ManagedIdentityCredential` does not politely report itself unavailable — it throws, after six
retries against the VM metadata address `169.254.169.254`, and that aborts the chain **before**
it ever reaches your Azure CLI login. The failure looks like an authentication problem with
your account. It isn't.

Name the credential and none of that happens:

```
--azure-credential-type azure-cli
```

`Sign-Release.ps1` passes this by default. The allowed values are `azure-cli`,
`azure-powershell`, `managed-identity` and `workload-identity`.

Whichever identity you end up as needs the **Code Signing Certificate Profile Signer** role on
the signing account, assigned under Access control (IAM). Owning the subscription is not
enough — it is a separate assignment. A missing role shows up as a 403 *after* a successful
sign-in, so the two failures look different: tenant problems stop you at the login screen,
role problems stop you at signtool.

## Signing the catalogue

```powershell
signtool sign /v /debug /fd SHA256 `
    /tr "http://timestamp.acs.microsoft.com" /td SHA256 `
    /dlib "<path to Azure.CodeSigning.Dlib.dll>" `
    /dmdf "C:\tools\metadata.json" `
    ".\release\SecretBeans-0.1.0.cat"

signtool verify /pa /v ".\release\SecretBeans-0.1.0.cat"
```

## Signing the scripts

Install Sign CLI into `C:\tools`, **not** into the repository — it unpacks a whole dependency
tree, and none of it belongs in source control. It needs the .NET **SDK**; the Artifact Signing
installer supplies only the runtime.

```powershell
dotnet tool install --tool-path C:\tools --prerelease sign
```

Test one file before doing all of them:

```powershell
C:\tools\sign.exe code artifact-signing ".\release\SecretBeans-0.1.0\SecretBeans.ps1" `
    --artifact-signing-account "your-signing-account" `
    --artifact-signing-certificate-profile "your-cert-profile" `
    --artifact-signing-endpoint "https://eus.codesigning.azure.net/" `
    --azure-credential-type azure-cli `
    --timestamp-url "http://timestamp.acs.microsoft.com"

Get-AuthenticodeSignature ".\release\SecretBeans-0.1.0\SecretBeans.ps1"
```

The verb is `artifact-signing`. `trusted-signing` still runs but warns that it is obsolete, and
its `--trusted-signing-*` options were renamed to match. Run
`C:\tools\sign.exe code artifact-signing --help` if any of this stops matching — this tooling
has been renamed once already and may be again.

`Status: Valid` means it worked. Check `TimeStamperCertificate` is populated too. Without a
countersignature the signature stops verifying in 72 hours.

Then sign the rest and repackage, so the catalogue and checksums describe the signed files
rather than the unsigned ones:

```powershell
powershell -ExecutionPolicy Bypass -File tools\Build-Release.ps1 -Version 0.1.0 -SkipStage
```

Then sign the new catalogue, and publish.

## Order matters

1. Build
2. Sign the `.ps1` files, if supported
3. **Repackage with `-SkipStage`** — the catalogue must hash the signed files
4. Sign the catalogue
5. Verify both
6. Publish the zip, the `.cat` and the `.sha256`

Two ways to get this wrong, and neither announces itself:

**Signing a script after the catalogue is made** invalidates the catalogue. The signature block
appended to a `.ps1` changes its hash, and the catalogue is now describing files that no longer
exist in that form.

**Repackaging without `-SkipStage`** throws the script signatures away. A normal build deletes
the staged folder and copies the unsigned originals back out of the repository, so you end up
with a correctly signed catalogue of unsigned scripts — which verifies perfectly and is not what
you meant to ship. `-SkipStage` re-hashes what is already staged and copies nothing.

`Sign-Release.ps1` makes both impossible, and calls `Test-FileCatalog` afterwards to prove the
catalogue matches what is on disk rather than trusting the ordering.

## A caveat worth keeping in mind

A signature says the release came from you, unchanged. It says nothing about whether the code
is correct. [VERIFYING.md](VERIFYING.md) makes that distinction to whoever downloads it, and
it is worth not blurring — the value of signing depends on people knowing what it does and
does not mean.

---

*Written by Claude (Anthropic) with Edwin West, August 2026. Not an Anthropic product — see
[PROVENANCE.md](../PROVENANCE.md).*
