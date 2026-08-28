# ---------------------------------------------------------------------------
#  SecretBeans - build, sign and verify a release, in the right order
#
#  Written by Claude (Anthropic) in a Claude Code session with Edwin West,
#  August 2026. Not an Anthropic product and not reviewed by Anthropic.
#
#  Order matters here, and getting it wrong fails quietly rather than loudly:
#
#      1. build                       stage the files, hash them, catalogue them
#      2. sign the .ps1 files         optional; appends a signature block
#      3. repackage  (-SkipStage)     the catalogue must hash the SIGNED files
#      4. sign the catalogue          one signature covering the whole release
#      5. verify both                 and check the checksums still describe reality
#
#  Signing a script AFTER the catalogue is made silently invalidates the
#  catalogue, because the signature block appended to a .ps1 changes its hash.
#  Rebuilding without -SkipStage silently DISCARDS the script signatures,
#  because a normal build recopies the unsigned originals from the repository.
#  Either mistake leaves you with something that still verifies and is not what
#  you think it is. This script exists so neither can happen by accident.
#
#  This file contains no account details. Everything specific to your signing
#  account is read from metadata.json, which lives outside the repository.
#
#      tools\Sign-Release.ps1 -Version 0.1.0
#      tools\Sign-Release.ps1 -Version 0.1.0 -SignScripts
#
#  See docs\SIGNING.md for where each value in metadata.json comes from.
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,

    # Names the signing account, certificate profile and regional endpoint.
    # Keep it out of the repository - see docs\SIGNING.md.
    [string]$MetadataFile = 'C:\tools\metadata.json',

    # Azure.CodeSigning.Dlib.dll. Leave this empty and the usual install
    # locations are searched, preferring a copy whose architecture matches
    # signtool's - see Find-Dlib below. Set it to point somewhere specific.
    [string]$Dlib = '',

    # Passed to both signtool and Sign CLI. Artifact Signing certificates are
    # valid for 72 hours, so without a timestamp countersignature the signature
    # stops verifying within three days. Do not blank this out. Every signature
    # produced here is checked for a countersignature afterwards regardless.
    [string]$TimestampUrl = 'http://timestamp.acs.microsoft.com',

    # Which Azure credential Sign CLI should use. Left to its default it runs
    # the whole DefaultAzureCredential chain, and ManagedIdentityCredential
    # throws a hard error on a machine that is not an Azure VM - it probes the
    # metadata endpoint at 169.254.169.254, which is unreachable, and that
    # aborts the chain before it ever reaches the Azure CLI login. Naming the
    # credential explicitly skips all of that.
    #
    # Allowed: azure-cli, azure-powershell, managed-identity, workload-identity
    [ValidateSet('azure-cli','azure-powershell','managed-identity','workload-identity')]
    [string]$AzureCredentialType = 'azure-cli',

    # Also sign the .ps1 files, so people can run SecretBeans under a
    # RemoteSigned or AllSigned execution policy without unblocking anything.
    # Off by default because it needs a second tool (Sign CLI) and because
    # signtool's support for .ps1 with Trusted Signing is undocumented.
    [switch]$SignScripts,

    # Passed through to the build. Don't.
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root   = Split-Path -Parent $PSScriptRoot
$outDir = Join-Path $root 'release'
$stage  = Join-Path $outDir "SecretBeans-$Version"
$catFile = Join-Path $outDir "SecretBeans-$Version.cat"
$sumFile = Join-Path $outDir "SecretBeans-$Version.sha256"
$zipFile = Join-Path $outDir "SecretBeans-$Version.zip"

function Write-Step {
    param([string]$Text)
    Write-Host ""
    Write-Host ("=== {0}" -f $Text) -ForegroundColor Cyan
}

function Write-Ok   { param([string]$T) Write-Host ("  ok    {0}" -f $T) -ForegroundColor Green }
function Write-Info { param([string]$T) Write-Host ("        {0}" -f $T) }

# Native tools report failure through the exit code, not through PowerShell's
# error stream. With $ErrorActionPreference = 'Stop' a single line on stderr
# would otherwise become a terminating error and truncate the real message.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& $Exe @Arguments 2>&1 | Out-String)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ Text = $text.TrimEnd(); ExitCode = $code }
}

function Find-SignTool {
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # The Windows SDK installs a copy per architecture per SDK version. Prefer
    # the newest, matching this process's architecture - an x86 dlib loaded by
    # an x64 signtool fails with an error that does not say so.
    $arch = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
    $roots = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\bin",
        "$env:ProgramFiles\Windows Kits\10\bin"
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }

    $found = foreach ($r in $roots) {
        Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object {
                $p = Join-Path $_.FullName "$arch\signtool.exe"
                if (Test-Path -LiteralPath $p) { $p }
            }
    }
    if ($found) { return @($found)[0] }
    return $null
}

function Get-PeMachine {
    # Read the architecture out of the file itself rather than inferring it
    # from the folder name. The MSI installs everything into one flat folder
    # with no x64/x86 in the path, so there is nothing to infer from.
    #
    # PE layout: offset 0x3C holds the offset of the PE header; the PE header
    # is "PE\0\0" followed by a 2-byte machine type.
    #
    # 'unknown' is a perfectly ordinary answer, not a failure. Managed
    # assemblies built for AnyCPU report machine types that are not CPU
    # architectures at all, so the caller treats unknown as "carry on, but do
    # not claim to have checked" rather than as a mismatch.
    param([Parameter(Mandatory)][string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'Read')
        try {
            $br = New-Object System.IO.BinaryReader($fs)
            if ($fs.Length -lt 0x40) { return 'unknown' }
            $fs.Position = 0x3C
            $peOffset = $br.ReadInt32()
            if ($peOffset -le 0 -or ($peOffset + 6) -gt $fs.Length) { return 'unknown' }
            $fs.Position = $peOffset
            if ($br.ReadUInt32() -ne 0x00004550) { return 'unknown' }   # 'PE\0\0'
            switch ($br.ReadUInt16()) {
                0x8664  { return 'x64' }
                0x014c  { return 'x86' }
                0xAA64  { return 'arm64' }
                default { return 'unknown' }
            }
        } finally { $fs.Dispose() }
    } catch { return 'unknown' }
}

function Find-Dlib {
    # Azure.CodeSigning.Dlib.dll arrives by one of two routes:
    #
    #   the ArtifactSigningClientTools MSI, which installs one flat folder
    #     under %LocalAppData%\Microsoft\ - named MicrosoftArtifactSigningClientTools
    #     as of v1.0.4, though the product has been renamed once already, so
    #     the folder is matched by pattern rather than by exact name
    #   the Microsoft.ArtifactSigning.Client NuGet package unzipped by hand,
    #     which does have bin\x64\ and bin\x86\ subfolders
    #
    # Architecture has to match signtool. Mixing them fails with an error that
    # never mentions architecture, so the PE header is read directly.
    $arch = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }

    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($fixed in 'C:\tools', (Join-Path $root 'tools')) {
        if (Test-Path -LiteralPath $fixed) { $roots.Add($fixed) }
    }
    foreach ($parent in $env:LOCALAPPDATA, "${env:ProgramFiles}", "${env:ProgramFiles(x86)}") {
        if (-not $parent) { continue }
        foreach ($sub in $parent, (Join-Path $parent 'Microsoft')) {
            if (-not (Test-Path -LiteralPath $sub)) { continue }
            Get-ChildItem -LiteralPath $sub -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match 'ArtifactSigning|TrustedSigning' } |
                ForEach-Object { $roots.Add($_.FullName) }
        }
    }
    if ($roots.Count -eq 0) { return $null }

    $hits = foreach ($r in $roots) {
        Get-ChildItem -LiteralPath $r -Recurse -File -Filter 'Azure.CodeSigning.Dlib.dll' -ErrorAction SilentlyContinue
    }
    $hits = @($hits)
    if ($hits.Count -eq 0) { return $null }

    $scored = foreach ($h in $hits) {
        [pscustomobject]@{ Path = $h.FullName; Machine = (Get-PeMachine -Path $h.FullName) }
    }

    $match = $scored | Where-Object { $_.Machine -eq $arch } | Select-Object -First 1
    if ($match) { return [pscustomobject]@{ Path = $match.Path; Machine = $match.Machine; ArchOk = $true } }

    $any = @($scored)[0]
    return [pscustomobject]@{
        Path    = $any.Path
        Machine = $any.Machine
        ArchOk  = $(if ($any.Machine -eq 'unknown') { $null } else { $false })
    }
}

# ---------------------------------------------------------------------------
#  0. Preflight - fail before building, not after
# ---------------------------------------------------------------------------
Write-Step "Checking what signing needs"

$signtool = Find-SignTool
if (-not $signtool) {
    throw @"
signtool.exe was not found, on PATH or under Windows Kits\10\bin.

It ships with the Windows SDK. Install "Windows SDK Signing Tools for Desktop
Apps" from the Visual Studio Installer, or the standalone Windows SDK.
"@
}
Write-Ok ("signtool         {0}" -f $signtool)

if (-not (Test-Path -LiteralPath $MetadataFile)) {
    throw @"
No metadata file at $MetadataFile

Create it with the three values from your signing account in the Azure portal
(docs\SIGNING.md says where each one is), or point -MetadataFile at it.
"@
}

try {
    $meta = Get-Content -LiteralPath $MetadataFile -Raw | ConvertFrom-Json
} catch {
    throw "$MetadataFile is not valid JSON: $($_.Exception.Message)"
}

foreach ($key in 'Endpoint','CodeSigningAccountName','CertificateProfileName') {
    if (-not ($meta.PSObject.Properties.Name -contains $key) -or
        [string]::IsNullOrWhiteSpace([string]$meta.$key)) {
        throw "$MetadataFile has no value for `"$key`". All three are required."
    }
}
Write-Ok ("metadata         {0}" -f $MetadataFile)
Write-Info ("account   {0}" -f $meta.CodeSigningAccountName)
Write-Info ("profile   {0}" -f $meta.CertificateProfileName)
Write-Info ("endpoint  {0}" -f $meta.Endpoint)

$arch = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
if ($Dlib) {
    if (-not (Test-Path -LiteralPath $Dlib)) {
        throw "No signing dlib at $Dlib (given with -Dlib)."
    }
    Write-Ok ("dlib             {0}" -f $Dlib)
} else {
    $found = Find-Dlib
    if (-not $found) {
        throw @"
Azure.CodeSigning.Dlib.dll was not found.

The simplest way to get it is the Artifact Signing client tools installer, which
also brings signtool and the .NET runtime it needs:

    https://github.com/Azure/artifact-signing-clienttools/releases

Download ArtifactSigningClientTools.msi and run it. It installs to
%LocalAppData%\Microsoft\ArtifactSigningTools, which this script searches.

Or, by hand: get the Microsoft.ArtifactSigning.Client package from nuget.org,
rename the .nupkg to .zip, unzip it, and take bin\$arch\Azure.CodeSigning.Dlib.dll.

Then either put it somewhere searched, or pass -Dlib with its full path.
"@
    }
    $Dlib = $found.Path
    if ($found.ArchOk -eq $false) {
        throw @"
The dlib found is the wrong architecture for signtool.

    signtool is  : $arch
    dlib is      : $($found.Machine)
    dlib path    : $Dlib

Mixing them fails with an error that never mentions architecture, so this stops
here instead. Use the $arch copy, or pass -Dlib explicitly.
"@
    }
    Write-Ok ("dlib             {0}" -f $Dlib)
    if ($null -eq $found.ArchOk) {
        Write-Info "could not read the architecture out of that file - if signing fails oddly, check it is $arch"
    } else {
        Write-Info ("architecture {0}, matching signtool" -f $found.Machine)
    }
}

if ([string]::IsNullOrWhiteSpace($TimestampUrl)) {
    throw "A timestamp URL is required. Trusted Signing certificates last 72 hours; an untimestamped signature stops verifying when the certificate behind it expires."
}
Write-Ok ("timestamp        {0}" -f $TimestampUrl)

$signCli = $null
if ($SignScripts) {
    # C:\tools first, deliberately. Sign CLI unpacks itself and its
    # dependencies into whatever --tool-path is given, so installing it inside
    # the repository would scatter a third-party tool through the source tree.
    $candidates = @(
        'C:\tools\sign.exe',
        (Join-Path $PSScriptRoot 'sign.exe'),
        (Join-Path $root 'sign.exe')
    )
    $signCli = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $signCli) {
        $cmd = Get-Command sign.exe -ErrorAction SilentlyContinue
        if ($cmd) { $signCli = $cmd.Source }
    }
    if (-not $signCli) {
        $sdk = $null
        try { $sdk = (& dotnet --list-sdks 2>&1 | Out-String).Trim() } catch { }
        $sdkNote = if ([string]::IsNullOrWhiteSpace($sdk) -or $sdk -match 'not recognized|command not found') {
@"

You will need the .NET SDK first - the Artifact Signing installer brings the
RUNTIME, which is not enough to install a dotnet tool:

    winget install --id Microsoft.DotNet.SDK.8 -e

Then reopen PowerShell so PATH picks it up.
"@
        } else { '' }

        throw @"
-SignScripts was given but Sign CLI was not found.

Install it into C:\tools, not into the repository - it unpacks a whole tree of
files and none of them belong in source control:

    dotnet tool install --tool-path C:\tools --prerelease sign
$sdkNote
Sign CLI is what documents .ps1 and .psm1 support; signtool does not.

None of this is required. Without -SignScripts you still get a signed catalogue
covering every file in the release.
"@
    }
    Write-Ok ("sign cli         {0}" -f $signCli)
    Write-Info ("credential  {0}" -f $AzureCredentialType)
    if ($AzureCredentialType -eq 'azure-cli') {
        $az = Get-Command az -ErrorAction SilentlyContinue
        if (-not $az) {
            throw @"
-AzureCredentialType is azure-cli but the Azure CLI is not on PATH.

    winget install --id Microsoft.AzureCLI -e

then reopen PowerShell and run

    az login --tenant <your-tenant>.onmicrosoft.com

Or pass -AzureCredentialType with one of azure-powershell, managed-identity or
workload-identity.
"@
        }
    }
} else {
    Write-Info "scripts          not signing .ps1 files (pass -SignScripts to)"
}

# ---------------------------------------------------------------------------
#  1. Build
# ---------------------------------------------------------------------------
Write-Step "1 of 5  Building"

$buildArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',
               (Join-Path $PSScriptRoot 'Build-Release.ps1'),
               '-Version', $Version)
$buildArgs += '-Quiet'
if ($SkipTests) { $buildArgs += '-SkipTests' }

& powershell @buildArgs
if ($LASTEXITCODE -ne 0) { throw "The build failed. Nothing was signed." }

foreach ($required in $stage, $catFile) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "The build did not produce $required. Nothing was signed."
    }
}

# ---------------------------------------------------------------------------
#  2. Sign the scripts
# ---------------------------------------------------------------------------
$scriptsSigned = 0
if ($SignScripts) {
    Write-Step "2 of 5  Signing the scripts"

    # .ps1 and .psm1 only. Sign CLI's supported list does not include .psd1,
    # so templates\config.psd1 is deliberately left alone - the catalogue
    # covers it either way.
    # Filter on .Extension, NOT with -Include. -Include is silently ignored
    # when the path is given as -LiteralPath, which selects every file in the
    # release instead of just the scripts - and the first thing you learn about
    # it is the signing service rejecting a .md file.
    $scripts = @(Get-ChildItem -LiteralPath $stage -Recurse -File |
                 Where-Object { $_.Extension -in '.ps1','.psm1' } |
                 Sort-Object FullName)
    if ($scripts.Count -eq 0) { throw "No scripts found under $stage." }

    Write-Info ("{0} files to sign" -f $scripts.Count)

    # Sign the first one alone and check it before doing the rest. If the
    # service does not handle .ps1, this says so after one call rather than
    # after forty.
    $first = $scripts[0]
    $signArgs = @(
        '--artifact-signing-account',             [string]$meta.CodeSigningAccountName,
        '--artifact-signing-certificate-profile', [string]$meta.CertificateProfileName,
        '--artifact-signing-endpoint',            [string]$meta.Endpoint,
        '--azure-credential-type',                $AzureCredentialType,
        '--timestamp-url',                        $TimestampUrl,
        '--verbosity','information'
    )

    $r = Invoke-Native -Exe $signCli -Arguments (@('code','artifact-signing', $first.FullName) + $signArgs)
    if ($r.ExitCode -ne 0) {
        Write-Host $r.Text
        throw @"
Signing $($first.Name) failed (exit $($r.ExitCode)).

If your account does not support .ps1, that is not fatal - drop -SignScripts and
release with a signed catalogue only. The catalogue covers every file on its own;
what you lose is being able to run the scripts under AllSigned without unblocking.
"@
    }

    $sig = Get-AuthenticodeSignature -LiteralPath $first.FullName
    if ($sig.Status -ne 'Valid') {
        throw @"
$($first.Name) was signed but Windows does not accept the signature:

    Status : $($sig.Status)
    $($sig.StatusMessage)

Stopping here rather than signing the rest.
"@
    }
    if (-not $sig.TimeStamperCertificate) {
        throw @"
$($first.Name) is signed but carries no timestamp countersignature.

Artifact Signing certificates are valid for 72 hours. Without a countersignature
this signature stops verifying in three days, so it is not worth shipping.

--timestamp-url was passed as $TimestampUrl, so this should not happen. Check

    "$signCli" code artifact-signing --help

in case the option has been renamed again. Nothing has been published.
"@
    }
    Write-Ok ("{0}  ({1})" -f $first.Name, $sig.SignerCertificate.Subject)
    Write-Info ("timestamped by {0}" -f $sig.TimeStamperCertificate.Subject)

    foreach ($f in $scripts | Select-Object -Skip 1) {
        $r = Invoke-Native -Exe $signCli -Arguments (@('code','artifact-signing', $f.FullName) + $signArgs)
        if ($r.ExitCode -ne 0) {
            Write-Host $r.Text
            throw "Signing $($f.Name) failed (exit $($r.ExitCode)). The release is now half signed - re-run from the start."
        }
        Write-Ok $f.Name
    }
    $scriptsSigned = $scripts.Count

    # ---- 3. repackage, so the catalogue hashes the signed files -----------
    Write-Step "3 of 5  Repackaging so the catalogue covers the signed files"

    & powershell -NoProfile -ExecutionPolicy Bypass `
        -File (Join-Path $PSScriptRoot 'Build-Release.ps1') `
        -Version $Version -SkipStage -Quiet
    if ($LASTEXITCODE -ne 0) { throw "Repackaging failed. The catalogue does not match the signed files - do not publish this." }

    # Prove it, rather than trusting the ordering.
    $check = Test-FileCatalog -CatalogFilePath $catFile -Path $stage -Detailed
    if ($check.Status -ne 'Valid') {
        throw "The rebuilt catalogue does not match the staged files (status: $($check.Status)). Do not publish this."
    }
    Write-Ok "the catalogue matches the signed files on disk"

} else {
    Write-Step "2 of 5  Signing the scripts - skipped"
    Write-Info "The catalogue below still covers every file in the release."
    Write-Step "3 of 5  Repackaging - not needed, nothing changed"
}

# ---------------------------------------------------------------------------
#  4. Sign the catalogue
# ---------------------------------------------------------------------------
Write-Step "4 of 5  Signing the catalogue"

$r = Invoke-Native -Exe $signtool -Arguments @(
    'sign','/v','/debug','/fd','SHA256',
    '/tr', $TimestampUrl, '/td','SHA256',
    '/dlib', $Dlib,
    '/dmdf', $MetadataFile,
    $catFile
)
if ($r.ExitCode -ne 0) {
    Write-Host $r.Text
    $hint = ''
    if ($r.Text -match '403|Forbidden') {
        $hint = @"

403 usually means one of two things:

  - the Endpoint region in $MetadataFile does not match the region the signing
    account was created in, or
  - the account you are logged in as does not hold the Code Signing Certificate
    Profile Signer role on that account.

It rarely means the file or the dlib is wrong.
"@
    }
    throw "signtool failed (exit $($r.ExitCode)).$hint"
}
Write-Ok "catalogue signed"

# ---------------------------------------------------------------------------
#  5. Verify
# ---------------------------------------------------------------------------
Write-Step "5 of 5  Verifying"

$r = Invoke-Native -Exe $signtool -Arguments @('verify','/pa','/v', $catFile)
if ($r.ExitCode -ne 0) {
    Write-Host $r.Text
    throw "The catalogue does not verify. Do not publish it."
}
if ($r.Text -notmatch 'Timestamp|timestamp') {
    throw "The catalogue verifies but has no timestamp countersignature. It will stop verifying within 72 hours. Do not publish it."
}
Write-Ok "signature and timestamp both check out"

$catCheck = Test-FileCatalog -CatalogFilePath $catFile -Path $stage -Detailed
if ($catCheck.Status -ne 'Valid') {
    throw "The signed catalogue does not match the staged files (status: $($catCheck.Status)). Do not publish it."
}
Write-Ok ("the catalogue matches all {0} staged files" -f $catCheck.CatalogItems.Count)

# The .sha256 is the fallback for anyone without signing tools. If it drifted
# from the files, that is worse than not shipping it.
$bad = New-Object System.Collections.Generic.List[string]
foreach ($line in (Get-Content -LiteralPath $sumFile)) {
    if ($line -notmatch '^([0-9a-f]{64})\s\s(.+)$') { continue }
    $want = $matches[1]
    $rel  = $matches[2]
    $path = Join-Path $stage $rel
    if (-not (Test-Path -LiteralPath $path)) { $bad.Add("missing: $rel"); continue }
    $got = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower()
    if ($got -ne $want) { $bad.Add("changed: $rel") }
}
if ($bad.Count -gt 0) {
    $bad | ForEach-Object { Write-Host ("  BAD   {0}" -f $_) -ForegroundColor Red }
    throw "The .sha256 file does not describe the staged files. Do not publish it."
}
Write-Ok "the .sha256 file matches the staged files"

if ($scriptsSigned -gt 0) {
    $unsigned = @(Get-ChildItem -LiteralPath $stage -Recurse -File |
                  Where-Object { $_.Extension -in '.ps1','.psm1' } |
                  Where-Object {
                      $s = Get-AuthenticodeSignature -LiteralPath $_.FullName
                      $s.Status -ne 'Valid' -or -not $s.TimeStamperCertificate
                  })
    if ($unsigned.Count -gt 0) {
        $unsigned | ForEach-Object { Write-Host ("  BAD   not validly signed or not timestamped: {0}" -f $_.Name) -ForegroundColor Red }
        throw "Some scripts are not validly signed. Do not publish this."
    }
    Write-Ok ("all {0} scripts carry a valid signature" -f $scriptsSigned)
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ""
Write-Host "Publish these three, and nothing else from release\:"
foreach ($f in $zipFile, $catFile, $sumFile) {
    if (Test-Path -LiteralPath $f) {
        $i = Get-Item -LiteralPath $f
        Write-Host ("  {0,-32} {1,9:N0} bytes" -f $i.Name, $i.Length)
    }
}
Write-Host ""
Write-Host "A signature says the release came from you, unchanged. It says nothing"
Write-Host "about whether the code is correct - docs\VERIFYING.md makes that"
Write-Host "distinction to whoever downloads it, and it is worth not blurring."
Write-Host ""
