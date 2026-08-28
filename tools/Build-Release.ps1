# ---------------------------------------------------------------------------
#  SecretBeans - build a release
#
#  Written by Claude (Anthropic) in a Claude Code session with Edwin West,
#  August 2026. Not an Anthropic product and not reviewed by Anthropic.
#
#  Produces, in .\release\:
#
#      SecretBeans-<version>.zip        the files a user downloads
#      SecretBeans-<version>.cat        a catalogue of every file and its hash
#      SecretBeans-<version>.sha256     checksums, readable without any tooling
#
#  The catalogue is the part worth signing. A .cat is a standard signable format,
#  so it works whatever your signing service supports - unlike .ps1, whose
#  signing goes through a different Windows mechanism that not every service
#  handles. Signing the catalogue proves every file in the release at once.
#
#  Signing is NOT done here. This script leaves the catalogue unsigned and tells
#  you what to run, because signing needs credentials that should not be baked
#  into a build script.
#
#      powershell -ExecutionPolicy Bypass -File tools\Build-Release.ps1 -Version 0.1.0
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,

    # Skip the self-check. Don't - a release that fails its own tests is worse
    # than no release.
    [switch]$SkipTests,

    # Repackage the staged folder that is already in .\release\ instead of
    # copying fresh files out of the repository.
    #
    # This exists for one reason. Once you have signed the .ps1 files in the
    # staged folder, the catalogue has to be rebuilt so that it hashes the
    # SIGNED files. A normal run would delete the staged folder and copy the
    # unsigned originals back over the top, silently throwing the signatures
    # away and producing a catalogue of unsigned files that still verifies.
    # -SkipStage rebuilds the checksums, catalogue and zip from what is
    # already there, and touches nothing else.
    [switch]$SkipStage,

    # Leave out the "now go and sign it" instructions at the end. Sign-Release.ps1
    # passes this, because printing a page of manual steps in the middle of a run
    # that is about to perform them is just noise.
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$root    = Split-Path -Parent $PSScriptRoot
$outDir  = Join-Path $root 'release'
$stage   = Join-Path $outDir "SecretBeans-$Version"

Write-Host ""
if ($SkipStage) {
    Write-Host "Repackaging SecretBeans $Version" -ForegroundColor Cyan
} else {
    Write-Host "Building SecretBeans $Version" -ForegroundColor Cyan
}
Write-Host "-----------------------------"

if ($SkipStage) {

    if (-not (Test-Path -LiteralPath $stage)) {
        throw "-SkipStage was given but there is nothing staged at $stage. Run this script without -SkipStage first."
    }
    Write-Host "Reusing the staged folder as it stands. No files copied from the repository."

} else {

    if (-not $SkipTests) {
        Write-Host "Running the self-check first..."
        $test = Join-Path $root 'tests\Test-SecretBeans.ps1'
        & powershell -NoProfile -ExecutionPolicy Bypass -File $test
        if ($LASTEXITCODE -ne 0) {
            throw "The self-check failed. Fix it before releasing - see the output above."
        }
        Write-Host ""
    }

    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    # what a user actually needs - no release folder, no git, no scratch
    $include = @('SecretBeans.ps1','README.md','PROVENANCE.md','LICENSE','src','templates','docs','tests')
    foreach ($item in $include) {
        $src = Join-Path $root $item
        if (-not (Test-Path -LiteralPath $src)) { Write-Warning "missing: $item"; continue }
        Copy-Item -LiteralPath $src -Destination $stage -Recurse -Force
    }
}

$files = Get-ChildItem -LiteralPath $stage -Recurse -File
Write-Host ("Staged {0} files" -f $files.Count)

# ---- checksums: verifiable with nothing but a hash tool -------------------
$sumFile = Join-Path $outDir "SecretBeans-$Version.sha256"
$lines = New-Object System.Collections.Generic.List[string]
foreach ($f in ($files | Sort-Object FullName)) {
    $rel = $f.FullName.Substring($stage.Length).TrimStart('\','/')
    $lines.Add(('{0}  {1}' -f (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower(), $rel))
}
[System.IO.File]::WriteAllLines($sumFile, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Host ("Checksums  -> {0}" -f (Split-Path -Leaf $sumFile))

# ---- catalogue: one signable file covering the whole release -------------
$catFile = Join-Path $outDir "SecretBeans-$Version.cat"
if (Test-Path -LiteralPath $catFile) { Remove-Item -LiteralPath $catFile -Force }
if (Get-Command New-FileCatalog -ErrorAction SilentlyContinue) {
    New-FileCatalog -Path $stage -CatalogFilePath $catFile -CatalogVersion 2 | Out-Null
    Write-Host ("Catalogue  -> {0}  (UNSIGNED)" -f (Split-Path -Leaf $catFile))
} else {
    Write-Warning "New-FileCatalog is unavailable, so no catalogue was produced. It ships with PowerShell 5.1 on Windows."
}

# ---- zip -----------------------------------------------------------------
$zipFile = Join-Path $outDir "SecretBeans-$Version.zip"
if (Test-Path -LiteralPath $zipFile) { Remove-Item -LiteralPath $zipFile -Force }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipFile
Write-Host ("Archive    -> {0}" -f (Split-Path -Leaf $zipFile))

if (-not $Quiet) {
    Write-Host ""
    Write-Host "Now sign it - see docs\SIGNING.md for where each value comes from." -ForegroundColor Yellow
    Write-Host @"
  tools\Sign-Release.ps1 does all of this in the right order, and checks its own
  work. Prefer it. What follows is what it runs, for anyone driving it by hand.

  1. Sign the scripts. This is what lets people run SecretBeans under a
     RemoteSigned or AllSigned execution policy without unblocking anything.

      dotnet tool install --tool-path C:\tools --prerelease sign
      az login --tenant <your-tenant>.onmicrosoft.com

      C:\tools\sign.exe code artifact-signing "$stage\SecretBeans.ps1" ``
          --artifact-signing-account <account> ``
          --artifact-signing-certificate-profile <profile> ``
          --artifact-signing-endpoint <account-uri> ``
          --azure-credential-type azure-cli ``
          --timestamp-url "http://timestamp.acs.microsoft.com"

      Get-AuthenticodeSignature "$stage\SecretBeans.ps1"

     Without --azure-credential-type it runs the full credential chain, and the
     managed-identity probe fails hard on a machine that is not an Azure VM.

  2. Repackage, so the catalogue hashes the SIGNED scripts:

      tools\Build-Release.ps1 -Version $Version -SkipStage

     -SkipStage matters. Without it the staged folder is deleted and recopied
     from the repository, which throws the signatures away and leaves you with a
     catalogue of unsigned files that still verifies perfectly.

  3. Sign the catalogue:

      signtool sign /v /debug /fd SHA256 ``
          /tr "http://timestamp.acs.microsoft.com" /td SHA256 ``
          /dlib "<path to Azure.CodeSigning.Dlib.dll>" ``
          /dmdf "C:\tools\metadata.json" ``
          "$catFile"

  4. Verify, then publish the .zip, the .cat and the .sha256:

      signtool verify /pa /v "$catFile"
"@
    Write-Host ""
}
Write-Host "Release folder: $outDir"
