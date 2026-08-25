# ---------------------------------------------------------------------------
#  SecretBeans - creating a period folder and rebuilding its journal
#
#  Written by Claude (Anthropic) in a Claude Code session with Edwin West,
#  August 2026. Not an Anthropic product and not reviewed by Anthropic.
#
#  See PROVENANCE.md for what was tested and what was not. In particular this
#  code has not yet been run on Windows PowerShell 5.1, which is its target.
# ---------------------------------------------------------------------------

<#
    SbBuild.ps1 - creating a period folder and rebuilding the journal inside it.

    Every run produces a complete, self-contained snapshot: the CSVs as downloaded,
    the rules that were used on them, and the journal they produced. Nothing is
    edited in place and nothing carries over invisibly, so a rebuild is always
    reproducible from what is sitting in the folder.
#>

Set-StrictMode -Version 2.0

function Get-SbHledger {
    <#  Locate hledger, preferring PATH, then the usual Windows install locations.  #>
    param([string]$Explicit)

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return $Explicit }
        throw "hledger not found at $Explicit"
    }
    $cmd = Get-Command hledger -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    foreach ($p in @(
        "$env:LOCALAPPDATA\Programs\hledger\hledger.exe",
        "$env:ProgramFiles\hledger\hledger.exe",
        "$env:USERPROFILE\.local\bin\hledger.exe",
        "$env:APPDATA\local\bin\hledger.exe"
    )) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    throw "hledger was not found. Install it from https://hledger.org/install.html, or set HledgerPath in the configuration."
}

function Invoke-SbHledger {
    <#
        Run hledger and hand back everything it said, plus its exit code.

        Deliberately forces ErrorActionPreference to Continue for the call. With it
        set to Stop - which the launcher does, correctly - anything a native command
        writes to stderr becomes a terminating error, and the caller sees only the
        first line of what can be a ten-line explanation. hledger says useful things
        on stderr, so all of it has to survive.
    #>
    param(
        [Parameter(Mandatory)][string]$Hledger,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $ErrorActionPreference = 'Continue'
    $text = (& $Hledger @Arguments 2>&1 | Out-String)
    return [pscustomobject]@{ Text = $text.TrimEnd(); ExitCode = $LASTEXITCODE }
}

function New-SbPeriodFolder {
    <#
        Build the folder skeleton for one run and populate it with the downloads
        (renamed to their stable short names) and the rules that go with them.

        Rules come from the previous period when one exists, so corrections you make
        this month are the starting point next month. Otherwise they come from the
        tool's templates, chosen by account Type.
    #>
    param(
        [Parameter(Mandatory)][string]$LedgerRoot,
        [Parameter(Mandatory)][string]$PeriodName,
        [Parameter(Mandatory)]$Matches,
        [Parameter(Mandatory)]$Config,
        [string]$TemplateRoot,
        [string]$PreviousPeriod
    )

    $root    = Join-Path $LedgerRoot $PeriodName
    $csvDir  = Join-Path $root 'csv'
    $rulesDir= Join-Path $root 'rules'
    $jrnDir  = Join-Path $root 'journal'
    foreach ($d in $root,$csvDir,$rulesDir,$jrnDir,(Join-Path $root 'reports')) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    $review = 'expenses:review'
    if ($Config.ContainsKey('ReviewAccount') -and $Config.ReviewAccount) { $review = $Config.ReviewAccount }

    $copied = New-Object System.Collections.Generic.List[object]
    foreach ($m in $Matches) {
        if ($m.Kind -ne 'Account' -or -not $m.File) { continue }

        $csvName  = "$($m.Name).csv"
        $destCsv  = Join-Path $csvDir $csvName
        Copy-Item -LiteralPath $m.File.FullName -Destination $destCsv -Force

        $rulesName = Get-SbRulesFileName -Name $m.Name
        $destRules = Join-Path $rulesDir $rulesName
        $source    = $null
        $fromTemplate = $false
        $rulesKept = $false
        if ($PreviousPeriod) {
            $prev = Join-Path (Join-Path (Join-Path $LedgerRoot $PreviousPeriod) 'rules') $rulesName
            if (Test-Path -LiteralPath $prev) { $source = $prev }
        }
        if (-not $source -and $TemplateRoot) {
            $tpl = Join-Path (Join-Path $TemplateRoot 'rules') ("{0}.csv.rules" -f $m.Type)
            if (Test-Path -LiteralPath $tpl) { $source = $tpl; $fromTemplate = $true }
        }
        # Never overwrite rules already in this period folder. Step 4 exists so you can
        # edit them and build again; copying the source over them each time would throw
        # away the correction you just made, and the second build would look identical
        # to the first for no visible reason.
        if (Test-Path -LiteralPath $destRules) {
            $source = $null
            $rulesKept = $true
        }

        if ($source) {
            if ($fromTemplate) {
                # A template is generic and says CHANGEME. Copying it verbatim produces a
                # journal where every account collapses into one, which fails in a way that
                # is hard to read. Substituting the real account here means a first run
                # produces something sensible, and the rules file is ready to edit.
                Write-SbTextFile -Path $destRules -Text (
                    Convert-SbTemplateRules -Text ([System.IO.File]::ReadAllText($source)) `
                                            -Account $m.Account -ReviewAccount $review)
            } else {
                Copy-Item -LiteralPath $source -Destination $destRules -Force
            }
        } elseif (-not (Test-Path -LiteralPath $destRules)) {
            Write-SbTextFile -Path $destRules -Text (New-SbStubRules -Account $m.Account -Currency $Config.Currency)
        }

        $rulesFrom = '(new stub)'
        if ($source) { $rulesFrom = $source }
        if ($rulesKept) { $rulesFrom = '(already in this folder - left alone)' }

        $copied.Add([pscustomobject]@{
            Name = $m.Name; Csv = $destCsv; Rules = $destRules
            Account = $m.Account; Type = $m.Type
            RulesFrom = $rulesFrom
        })
    }

    return [pscustomobject]@{
        Root = $root; CsvDir = $csvDir; RulesDir = $rulesDir; JournalDir = $jrnDir
        PeriodName = $PeriodName; Files = $copied
    }
}

function Convert-SbTemplateRules {
    <#
        Turn a generic template into rules for one real account.

        'account1 ...CHANGEME' becomes the account itself. Any other CHANGEME - a card
        template pointing its payments at a bank account we cannot know yet - goes to the
        review account, so it shows up in the build report instead of silently landing
        somewhere plausible-looking.
    #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Account,
        [string]$ReviewAccount = 'expenses:review'
    )
    $nl = [Environment]::NewLine
    $out = $Text -replace '(?m)^(account1\s+).*CHANGEME.*$', ('${1}' + $Account)
    $out = $out -replace '(?m)^(\s*account2\s+).*CHANGEME.*$', ('${1}' + $ReviewAccount)
    $out = $out -replace 'CHANGEME', $Account
    $banner = @(
        '# --------------------------------------------------------------------',
        '#  Created by SecretBeans from a template, for:',
        ("#      $Account"),
        '#',
        '#  Check the fields line matches your CSV, then add categories. Anything',
        ("#  it could not work out points at $ReviewAccount so it shows up in the"),
        '#  build report rather than disappearing somewhere plausible.',
        '# --------------------------------------------------------------------',
        ''
    ) -join $nl
    return $banner + $out
}

function New-SbStubRules {
    <#  A minimal rules file for an account we have no template for, so a build still runs.  #>
    param([Parameter(Mandatory)][string]$Account, [string]$Currency = '$')
    $nl = [Environment]::NewLine
    return @(
        "# Rules for $Account",
        "#",
        "# SecretBeans had no template for this account type, so this is a starting point.",
        "# Set 'fields' to match the CSV's own column order, then add 'if' blocks to",
        "# categorise. Anything uncategorised lands in expenses:unknown, which the build",
        "# reports so you can see what still needs a rule.",
        "",
        "skip 1",
        "fields date, description, amount",
        "date-format %-m/%-d/%Y",
        "currency $Currency",
        "account1 $Account",
        ""
    ) -join $nl
}

function ConvertTo-SbPattern {
    <#
        Escape a description for use as a rules-file pattern.

        Only true regex metacharacters are escaped. [regex]::Escape would also turn a
        space into '\ ', which .NET accepts but hledger's engine need not - and a rules
        file full of backslashed spaces is unreadable besides.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $meta = '.^$*+?()[]{}|\'
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        if ($meta.IndexOf($ch) -ge 0) { [void]$sb.Append('\') }
        [void]$sb.Append($ch)
    }
    return $sb.ToString()
}

function Add-SbRule {
    <#
        Append one categorisation rule to a rules file.

        Matching is on the description, escaped and anchored, because that is the one
        field every CSV has. Anchoring matters: an unanchored 'CHECK 11' would also
        claim cheque 110 and 119.

        Rules go at the END of the file, which is where they win - hledger applies every
        matching block in order and the last assignment stands.
    #>
    param(
        [Parameter(Mandatory)][string]$RulesFile,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string]$Account,
        [string]$Comment
    )

    if ($Account -notmatch ':') {
        throw "'$Account' does not look like a ledger account - expected something like expenses:food:groceries"
    }

    $nl      = [Environment]::NewLine
    $pattern = ConvertTo-SbPattern -Text $Description.Trim()
    $header  = '# --- assigned in the SecretBeans window ---'

    $existing = ''
    if (Test-Path -LiteralPath $RulesFile) { $existing = [System.IO.File]::ReadAllText($RulesFile) }

    # Already assigned? Replace the account rather than stacking a second rule on top,
    # so changing your mind twice does not leave three contradictory blocks behind.
    $escapedPattern = [regex]::Escape($pattern)
    $rx = "(?m)^if %description $escapedPattern\r?\n\s+account2 .*$"
    if ($existing -match $rx) {
        $updated = [regex]::Replace($existing, $rx, "if %description $pattern$nl  account2 $Account")
        Write-SbTextFile -Path $RulesFile -Text $updated
        return 'updated'
    }

    $block = New-Object System.Collections.Generic.List[string]
    if ($existing -notmatch [regex]::Escape($header)) {
        $block.Add('')
        $block.Add($header)
        $block.Add('# Written by the window when a category was chosen for a transaction it could')
        $block.Add('# not identify. Ordinary rules - edit or delete them like any other.')
    }
    $block.Add('')
    if ($Comment) { $block.Add("# $Comment") }
    $block.Add("if %description $pattern")
    $block.Add("  account2 $Account")

    $text = $existing.TrimEnd() + $nl + ($block -join $nl) + $nl
    Write-SbTextFile -Path $RulesFile -Text $text
    return 'added'
}

function Invoke-SbRebuild {
    <#
        Rebuild every journal file in a period folder from the CSVs it contains.

        This is destructive by design: the journal directory is regenerated in full,
        so a rules change is always reflected and there is never a stale transaction
        left behind from an earlier run.
    #>
    param(
        [Parameter(Mandatory)]$Period,
        [Parameter(Mandatory)]$Config,
        [string]$HledgerPath
    )

    $hledger = Get-SbHledger -Explicit $HledgerPath
    $nl      = [Environment]::NewLine
    $log     = New-Object System.Collections.Generic.List[string]
    $perFile = New-Object System.Collections.Generic.List[object]
    $body    = New-Object System.Text.StringBuilder

    foreach ($f in $Period.Files) {
        $res  = Invoke-SbHledger -Hledger $hledger -Arguments @('print','-f',$f.Csv,'--rules',$f.Rules)
        $text = $res.Text

        if ($res.ExitCode -ne 0) {
            $log.Add("FAILED  $($f.Name): hledger exited $($res.ExitCode)")
            $log.Add($text)
            $perFile.Add([pscustomobject]@{ Name=$f.Name; Ok=$false; Transactions=0; Error=$text })
            continue
        }

        $count = ([regex]::Matches($text, '(?m)^\d{4}-\d{2}-\d{2}')).Count
        $log.Add(("  {0,-14} {1,6} transactions" -f $f.Name, $count))
        $perFile.Add([pscustomobject]@{ Name=$f.Name; Ok=$true; Transactions=$count; Error='' })

        [void]$body.Append("; ---- $($f.Name) ($($f.Account)) ----$nl$nl")
        [void]$body.Append($text.TrimEnd())
        [void]$body.Append("$nl$nl")
    }

    $generated = Join-Path $Period.JournalDir 'generated.journal'
    Write-SbTextFile -Path $generated -Text ("; Generated by SecretBeans - do not edit.$nl; Rebuilt from the CSVs in ..\csv using the rules in ..\rules.$nl; Any change you make here is lost on the next rebuild; change the rules instead.$nl$nl" + $body.ToString())

    $opening = Join-Path $Period.JournalDir 'opening.journal'
    Write-SbTextFile -Path $opening -Text (New-SbOpeningJournal -Config $Config -Period $Period -Generated $generated)

    $accounts = Join-Path $Period.JournalDir 'accounts.journal'
    Write-SbTextFile -Path $accounts -Text (New-SbAccountsJournal -Generated $generated -Opening $opening)

    $main = Join-Path $Period.JournalDir 'main.journal'
    Write-SbTextFile -Path $main -Text (@(
        "; $($Period.PeriodName)",
        "; Entry point for this period. Point hledger at this file.",
        "",
        "include accounts.journal",
        "include opening.journal",
        "include generated.journal",
        ""
    ) -join $nl)

    $diag = Get-SbDiagnostics -MainJournal $main -Hledger $hledger -Config $Config

    return [pscustomobject]@{
        MainJournal = $main
        Generated   = $generated
        PerFile     = $perFile
        Log         = $log
        Diagnostics = $diag
        Ok          = -not ($perFile | Where-Object { -not $_.Ok })
    }
}
