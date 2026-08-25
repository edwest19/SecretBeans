# ---------------------------------------------------------------------------
#  SecretBeans - matching downloaded files to configured accounts
#
#  Written by Claude (Anthropic) in a Claude Code session with Edwin West,
#  August 2026. Not an Anthropic product and not reviewed by Anthropic.
#
#  See PROVENANCE.md for what was tested and what was not. In particular this
#  code has not yet been run on Windows PowerShell 5.1, which is its target.
# ---------------------------------------------------------------------------

<#
    SbAccounts.ps1 - matching downloaded files to the accounts in the configuration.

    Institutions name their exports unhelpfully and inconsistently
    (Chase1234_Activity_20260821.csv), and the name changes with every download.
    The configuration turns that into a stable short name, which is what the rest
    of the tool - and the .rules file beside it - relies on.
#>

Set-StrictMode -Version 2.0

function Get-SbDownloadMatches {
    <#
        Given a folder of freshly downloaded files and a configuration, work out which
        file belongs to which account.

        Returns one object per configured account (Matched files, or none), plus one
        per file that matched nothing. Nothing is copied or changed here - this exists
        so the GUI can show the user what it is about to do and let them correct it.
    #>
    param(
        [Parameter(Mandatory)][string]$DownloadFolder,
        [Parameter(Mandatory)]$Config
    )

    if (-not (Test-Path -LiteralPath $DownloadFolder)) {
        throw "Download folder not found: $DownloadFolder"
    }

    $files = @(Get-ChildItem -LiteralPath $DownloadFolder -File |
               Where-Object { $_.Extension -match '^\.(csv|CSV|txt|qfx|ofx)$' -and $_.Name -notlike '.latest.*' })

    $claimed = @{}
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($acct in $Config.Accounts) {
        $hits = @($files | Where-Object { $_.Name -like $acct.Match })
        foreach ($h in $hits) { $claimed[$h.FullName] = $true }

        # More than one match means the folder holds several downloads for the same
        # account. The newest is almost always the one wanted, but say so rather than
        # choosing silently.
        $chosen = $null
        if ($hits.Count -gt 0) {
            $chosen = ($hits | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        }

        $status = 'Ok'
        if     ($hits.Count -eq 0) { $status = 'Missing' }
        elseif ($hits.Count -gt 1) { $status = 'Ambiguous' }

        $results.Add([pscustomobject]@{
            Kind        = 'Account'
            Name        = $acct.Name
            Account     = $acct.Account
            Type        = $acct.Type
            Match       = $acct.Match
            File        = $chosen
            Ambiguous   = ($hits.Count -gt 1)
            AllMatches  = $hits
            Status      = $status
        })
    }

    foreach ($f in $files) {
        if (-not $claimed.ContainsKey($f.FullName)) {
            $results.Add([pscustomobject]@{
                Kind       = 'Unmatched'
                Name       = ''
                Account    = ''
                Type       = ''
                Match      = ''
                File       = $f
                Ambiguous  = $false
                AllMatches = @($f)
                Status     = 'Unmatched'
            })
        }
    }

    return $results
}

function Get-SbRulesFileName {
    <#  A rules file always sits beside its CSV and shares its stem: freedom.csv -> freedom.csv.rules  #>
    param([Parameter(Mandatory)][string]$Name)
    return "$Name.csv.rules"
}

function New-SbPeriodName {
    <#
        The folder name for a run: "2026-09 September".

        Sortable first, readable second - a plain month name alone would order
        April before January in Explorer.
    #>
    param([datetime]$Date = (Get-Date))
    return ('{0:yyyy-MM} {1}' -f $Date, [System.Globalization.CultureInfo]::CurrentCulture.DateTimeFormat.GetMonthName($Date.Month))
}
