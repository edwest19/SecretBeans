# ---------------------------------------------------------------------------
#  SecretBeans - launcher
#
#  Written by Claude (Anthropic) in a Claude Code session with Edwin West,
#  August 2026. Not an Anthropic product and not reviewed by Anthropic.
#
#      powershell -ExecutionPolicy Bypass -File SecretBeans.ps1
#
#  See PROVENANCE.md for what was tested and what was not.
# ---------------------------------------------------------------------------

[CmdletBinding()]
param(
    # Defaults to config.psd1 beside this script, or in the ledger you used last.
    [string]$ConfigPath,

    # The folder your downloads landed in.
    [string]$DownloadFolder,

    # Only needed if hledger is not on PATH.
    [string]$HledgerPath
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

foreach ($m in 'SbConfig','SbAccounts','SbJournal','SbBuild','SbGui') {
    . (Join-Path (Join-Path $root 'src') "$m.ps1")
}

if (-not $ConfigPath) {
    $candidate = Join-Path $root 'config.psd1'
    if (Test-Path -LiteralPath $candidate) { $ConfigPath = $candidate }
}
if (-not $DownloadFolder) {
    $dl = Join-Path $env:USERPROFILE 'Downloads'
    if (Test-Path -LiteralPath $dl) { $DownloadFolder = $dl }
}

try {
    $null = Get-SbHledger -Explicit $HledgerPath
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show(
        ($_.Exception.Message + [Environment]::NewLine + [Environment]::NewLine +
         'SecretBeans needs hledger to build a journal. Install it from https://hledger.org/install.html'),
        'SecretBeans', [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error)
    exit 1
}

Show-SbWizard -ConfigPath $ConfigPath -DownloadFolder $DownloadFolder `
              -TemplateRoot (Join-Path $root 'templates') -HledgerPath $HledgerPath
