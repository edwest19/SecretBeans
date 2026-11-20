# ---------------------------------------------------------------------------
#  SecretBeans - self-check
#
#  Written by Claude (Anthropic) in a Claude Code session with Edwin West,
#  August 2026. Not an Anthropic product and not reviewed by Anthropic.
#
#  Run this on Windows PowerShell 5.1 to find out whether SecretBeans works
#  there. It builds a small synthetic ledger in a temporary folder and throws
#  it away afterwards. It never touches your real data.
#
#      powershell -ExecutionPolicy Bypass -File tests\Test-SecretBeans.ps1
# ---------------------------------------------------------------------------

$ErrorActionPreference = 'Stop'

$script:Pass = 0
$script:Fail = 0

function Skip {
    param([string]$Name, [string]$Why)
    Write-Host ("  [skip] {0}" -f $Name) -ForegroundColor DarkYellow
    Write-Host ("         {0}" -f $Why) -ForegroundColor DarkGray
}

function Step {
    param([string]$Name, [scriptblock]$Body)
    try {
        $result = & $Body
        Write-Host ("  [ ok ] {0}" -f $Name) -ForegroundColor Green
        if ($result) { Write-Host ("         {0}" -f $result) -ForegroundColor DarkGray }
        $script:Pass++
    } catch {
        Write-Host ("  [FAIL] {0}" -f $Name) -ForegroundColor Red
        Write-Host ("         {0}" -f $_.Exception.Message) -ForegroundColor Red
        $script:Fail++
    }
}

# Where each description's other posting goes, from hledger's own CSV output for
# one CSV and its rules file. The account1 side, under liabilities:, is left out.
function Get-TestCategories {
    param([string]$Csv, [string]$Rules)
    $res = Invoke-SbHledger -Hledger (Get-SbHledger) -Arguments @('print','-f',$Csv,'--rules',$Rules,'-O','csv')
    if ($res.ExitCode -ne 0) { throw "hledger failed: $($res.Text)" }
    $map = @{}
    foreach ($row in (($res.Text -split "\r?\n") | ConvertFrom-Csv)) {
        if ($row.account -notlike 'liabilities:*') { $map[$row.description] = $row.account }
    }
    return $map
}

Write-Host ""
Write-Host "SecretBeans self-check" -ForegroundColor Cyan
Write-Host "---------------------"
Write-Host ("  PowerShell : {0}  ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
Write-Host ("  OS         : {0}" -f [System.Environment]::OSVersion.VersionString)
Write-Host ""

$root = Split-Path -Parent $PSScriptRoot
$tmp  = Join-Path ([System.IO.Path]::GetTempPath()) ("SecretBeans-selfcheck-" + [guid]::NewGuid().ToString('N').Substring(0,8))

try {
    # Dot-sourced here, at script scope. Doing this inside a Step scriptblock would
    # load the functions into that block's scope and lose them on return.
    foreach ($m in 'SbConfig','SbAccounts','SbJournal','SbBuild','SbGui') {
        . (Join-Path (Join-Path $root 'src') "$m.ps1")
    }
    Step "modules load" {
        foreach ($fn in 'Import-SbConfig','Get-SbDownloadMatches','Invoke-SbRebuild','Get-SbDiagnostics',
                        'New-SbWizardForm','Show-SbWizard','Format-SbDiagnostics') {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw "$fn did not load" }
        }
        "SbConfig, SbAccounts, SbJournal, SbBuild, SbGui"
    }

    Step "hledger is installed" {
        $h = Get-SbHledger
        (& $h --version) | Select-Object -First 1
    }

    $dl = Join-Path $tmp 'downloads'
    $lg = Join-Path $tmp 'ledger'
    Step "temporary workspace" {
        New-Item -ItemType Directory -Path $dl -Force | Out-Null
        New-Item -ItemType Directory -Path $lg -Force | Out-Null
        $tmp
    }

    Step "synthetic download and rules" {
        $csv = @(
            'Details,Posting Date,Description,Amount,Type,Balance,Check or Slip #'
            'DEBIT,7/03/2026,ACME GROCERY 123,-52.40,DEBIT_CARD,1947.60,'
            'DEBIT,7/05/2026,NORTHERN GAS CO,-88.10,ACH_DEBIT,1859.50,'
            'CREDIT,7/15/2026,PAYROLL DEPOSIT,1500.00,ACH_CREDIT,3359.50,'
            'DEBIT,7/20/2026,CHECK 501,-75.00,CHECK_PAID,3284.50,501'
        ) -join [Environment]::NewLine
        Write-SbTextFile -Path (Join-Path $dl 'Bank1234_Activity_20260731.csv') -Text $csv

        $rules = @(
            'skip 1'
            'fields details, date, description, amount, type, balance, checknumber'
            'date-format %-m/%-d/%Y'
            'currency $'
            'account1 assets:bank:test'
            ''
            'if %description ACME GROCERY'
            '  account2 expenses:food:groceries'
            ''
            'if %description NORTHERN GAS'
            '  account2 expenses:utilities:gas'
            ''
            'if %description PAYROLL DEPOSIT'
            '  account2 income:salary'
            ''
            'if %type CHECK_PAID'
            '  account2 expenses:review:check'
        ) -join [Environment]::NewLine
        New-Item -ItemType Directory -Path (Join-Path $tmp 'prev\rules') -Force | Out-Null
        Write-SbTextFile -Path (Join-Path $tmp 'prev\rules\test.csv.rules') -Text $rules
        "4 transactions, 4 rules"
    }

    $cfgPath = Join-Path $tmp 'config.psd1'
    Step "config saves and reloads" {
        $cfg = New-SbDefaultConfig
        $cfg.LedgerRoot = $lg
        $cfg.Accounts = @(
            @{ Name='test'; Match='Bank1234*'; Account='assets:bank:test'; Type='bank'; OpeningBalance=2000.00 }
        )
        Export-SbConfig -Config $cfg -Path $cfgPath
        $back = Import-SbConfig -Path $cfgPath
        if ($back.Accounts.Count -ne 1) { throw "expected 1 account, got $($back.Accounts.Count)" }
        "round-tripped 1 account"
    }

    Step "bad config is rejected" {
        $broken = @{ Accounts = @( @{ Name='x' } ) }
        $issues = @(Test-SbConfig -Config $broken)
        if ($issues.Count -lt 1) { throw "a config missing Match/Account/Type was accepted" }
        "$($issues.Count) problems reported, as expected"
    }

    $cfg = Import-SbConfig -Path $cfgPath
    $script:matches = $null
    Step "download matched to account" {
        $script:matches = @(Get-SbDownloadMatches -DownloadFolder $dl -Config $cfg)
        $ok = @($script:matches | Where-Object { $_.Status -eq 'Ok' })
        if ($ok.Count -ne 1) { throw "expected 1 match, got $($ok.Count)" }
        "Bank1234_Activity_20260731.csv -> test"
    }

    $script:period = $null
    Step "period folder created" {
        $name = New-SbPeriodName -Date ([datetime]'2026-08-15')
        $script:period = New-SbPeriodFolder -LedgerRoot $lg -PeriodName $name -Matches $script:matches -Config $cfg `
                                     -TemplateRoot (Join-Path $root 'templates')
        Get-ChildItem (Join-Path $tmp 'prev\rules') -Filter *.rules | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $script:period.RulesDir 'test.csv.rules') -Force
        }
        $name
    }

    $script:build = $null
    Step "journal rebuilt" {
        $script:build = Invoke-SbRebuild -Period $script:period -Config $cfg
        if (-not $script:build.Ok) { throw "rebuild reported a failure" }
        "{0} transactions" -f $script:build.Diagnostics.Transactions
    }

    Step "hledger check passes on the result" {
        if (-not $script:build.Diagnostics.CheckPassed) { throw $script:build.Diagnostics.CheckOutput }
        "balanced"
    }

    Step "diagnostics look right" {
        $d = $script:build.Diagnostics
        if ($d.Transactions -ne 5) { throw "expected 5 transactions (4 + opening balance), got $($d.Transactions)" }
        if ($d.UnknownCount -ne 0) { throw "expected nothing uncategorised, got $($d.UnknownCount)" }
        if ($d.ReviewCount -ne 1)  { throw "expected the check to need review, got $($d.ReviewCount)" }
        "5 transactions, 0 uncategorised, 1 awaiting review"
    }

    Step "opening balance written" {
        $op = Get-Content (Join-Path $script:period.JournalDir 'opening.journal') -Raw
        $flat = $op -replace ',', ''
        if ($flat -notmatch '2000\.00') { throw "opening balance of 2000.00 is not in opening.journal" }
        if ($op -notmatch '2026-07-02 opening balances') { throw "opening balance is not dated the day before the first transaction" }
        "assets:bank:test opened at 2,000.00, dated 2026-07-02"
    }

    Step "build report reads correctly" {
        $text = Format-SbDiagnostics -Build $script:build
        foreach ($needle in 'PER FILE','SUMMARY','UNCATEGORISED','AWAITING REVIEW','POSSIBLE DUPLICATES') {
            if ($text -notmatch [regex]::Escape($needle)) { throw "the report is missing its '$needle' section" }
        }
        if ($text -notmatch 'hledger check       passed') { throw "the report does not say the check passed" }
        "{0} lines, all five sections present" -f ($text -split "`n").Count
    }

    # The window is built and thrown away without being shown. It is the only
    # automated coverage a GUI can have, and it catches the failures that matter:
    # a control referenced before it exists, a typo in a property name, a handler
    # that cannot be attached.
    if ($env:OS -eq 'Windows_NT') {
        Step "window builds and disposes" {
            $f = New-SbWizardForm -ConfigPath $cfgPath -DownloadFolder $dl `
                                  -TemplateRoot (Join-Path $root 'templates')
            try {
                if ($f -isnot [System.Windows.Forms.Form]) { throw "expected a Form, got $($f.GetType().Name)" }
                $st = $f.Tag
                if ($st.Panels.Count -ne 5) { throw "expected 5 wizard steps, found $($st.Panels.Count)" }
                if ($st.Step -ne 1) { throw "the window did not open on step 1" }
                foreach ($k in 'Title','Next','Back','GridMatch','GridOpen','Build','Log','Period','LedgerRoot','LedgerRootBrowse') {
                    if (-not $st.Controls.ContainsKey($k)) { throw "the window has no '$k' control" }
                }
                if ($st.Controls.Title.Text -notmatch 'Step 1 of 5') { throw "step 1 has the wrong heading" }

                # Control.Visible reports *effective* visibility, so on a form that has
                # never been shown every panel reads false. Set-SbWizardStep records the
                # active one separately; that is what can honestly be asserted here.
                if ($st.ActivePanel -ne 0) { throw "the window did not open showing step 1's panel (ActivePanel = $($st.ActivePanel))" }

                for ($i = 0; $i -lt 5; $i++) {
                    if ($st.Panels[$i].Controls.Count -lt 1) { throw "step $($i+1)'s panel has no controls on it" }
                }
                if (-not [object]::ReferenceEquals($st.Controls.Config.Parent, $st.Panels[0])) {
                    throw "the configuration box is not on step 1's panel"
                }
                if (-not [object]::ReferenceEquals($st.Controls.LedgerRoot.Parent, $st.Panels[0])) {
                    throw "the ledger root box is not on step 1's panel"
                }
                if (-not [object]::ReferenceEquals($st.Controls.GridOpen.Parent, $st.Panels[2])) {
                    throw "the opening-balances grid is not on step 3's panel"
                }
                if (-not [object]::ReferenceEquals($st.Controls.Log.Parent, $st.Panels[3])) {
                    throw "the build log is not on step 4's panel"
                }
                "5 steps populated, controls on the right panels, opens on step 1"
            } finally { $f.Dispose() }
        }
    } else {
        Skip "window builds and disposes" "Windows Forms is only available on Windows; run this on Windows to cover the GUI."
    }

    # The whole point of step 4 is edit-rules-then-build-again. If a rebuild copied
    # the template back over the rules, every correction would vanish and the second
    # build would look identical to the first for no visible reason.
    Step "edited rules survive a rebuild" {
        $rf = Join-Path $script:period.RulesDir 'test.csv.rules'
        Add-Content -LiteralPath $rf -Value "`nif %description NORTHERN GAS`n  account2 expenses:utilities:heating"
        $again = New-SbPeriodFolder -LedgerRoot $lg -PeriodName $script:period.PeriodName `
                                    -Matches $script:matches -Config $cfg `
                                    -TemplateRoot (Join-Path $root 'templates')
        $after = Get-Content -LiteralPath $rf -Raw
        if ($after -notmatch 'expenses:utilities:heating') { throw 'the rules file was overwritten, so the edit was lost' }
        $b2 = Invoke-SbRebuild -Period $again -Config $cfg
        if (-not $b2.Diagnostics.CheckPassed) { throw 'the journal no longer balances after the second build' }
        'edit kept, second build still balances'
    }

    # Step 4 lets you type a category beside anything the rules could not identify and
    # have the rule written for you. Assigning twice must replace, not stack - two
    # contradictory rules for one description would be decided silently by file order.
    # The rule is anchored (^...$), so it is counted in that form.
    Step "assigning a category writes a working rule" {
        $rf = Join-Path $script:period.RulesDir 'test.csv.rules'
        $b  = Invoke-SbRebuild -Period $script:period -Config $cfg
        $item = $b.Diagnostics.Review | Select-Object -First 1
        if (-not $item) { throw 'expected the cheque to be awaiting review' }

        $r1 = Add-SbRule -RulesFile $rf -Description $item.Description -Account 'expenses:taxes:prep'
        if ($r1 -ne 'added') { throw "expected 'added', got '$r1'" }
        $after = Invoke-SbRebuild -Period $script:period -Config $cfg
        if ($after.Diagnostics.ReviewCount -ne 0) { throw 'the cheque is still awaiting review after being assigned' }
        if (-not $after.Diagnostics.CheckPassed) { throw 'the journal stopped balancing' }

        $r2 = Add-SbRule -RulesFile $rf -Description $item.Description -Account 'expenses:house:misc'
        if ($r2 -ne 'updated') { throw "assigning a second time should replace the rule, but returned '$r2'" }
        $text = Get-Content -LiteralPath $rf -Raw
        $rx = '(?m)^if %description \^' + [regex]::Escape($item.Description.Trim()) + '\$\s*$'
        $count = ([regex]::Matches($text, $rx)).Count
        if ($count -ne 1) { throw "expected exactly one rule for that description, found $count" }

        $final = Invoke-SbRebuild -Period $script:period -Config $cfg
        if (-not $final.Diagnostics.CheckPassed) { throw 'the journal stopped balancing after reassignment' }
        'rule added, then replaced rather than stacked'
    }

    # A rule written in step 4 must claim only the transaction it was written for.
    # Found in November 2026: a card purchase described only as 'PAYPAL' was given a
    # category, and the rule written for it, unanchored, claimed every PayPal purchase
    # on the card. These rules go at the end of the file, where they win, so it
    # overrode the card's own rule for each of them.
    Step "an assigned rule claims only its own description" {
        $dir = Join-Path $tmp 'assigned-anchor'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $csv = Join-Path $dir 'card.csv'
        $rf  = Join-Path $dir 'card.csv.rules'
        Write-SbTextFile -Path $csv -Text (@(
            'Transaction Date,Post Date,Description,Category,Type,Amount,Memo'
            '7/10/2026,7/11/2026,PAYPAL *ACME PETS,Shopping,Sale,-25.00,'
            '7/12/2026,7/13/2026,PAYPAL,Shopping,Sale,-40.00,'
        ) -join [Environment]::NewLine)
        Write-SbTextFile -Path $rf -Text (@(
            'skip 1'
            'fields date, postdate, description, category, type, amount, memo'
            'date-format %-m/%-d/%Y'
            'currency $'
            'account1 liabilities:creditcard:test'
            ''
            'if %description PAYPAL \*ACME PETS'
            '  account2 expenses:pets:food'
        ) -join [Environment]::NewLine)

        $null = Add-SbRule -RulesFile $rf -Description 'PAYPAL' -Account 'expenses:clothes'
        $to = Get-TestCategories -Csv $csv -Rules $rf
        if ($to['PAYPAL'] -ne 'expenses:clothes') {
            throw "the purchase described 'PAYPAL' went to '$($to['PAYPAL'])', not expenses:clothes"
        }
        if ($to['PAYPAL *ACME PETS'] -ne 'expenses:pets:food') {
            throw "the rule written for 'PAYPAL' also claimed 'PAYPAL *ACME PETS', which went to '$($to['PAYPAL *ACME PETS'])'"
        }
        "'PAYPAL' to expenses:clothes; 'PAYPAL *ACME PETS' keeps its own rule"
    }

    # The window shows a description as the rules left it, but hledger matches rules
    # against the CSV's own text. Chase writes '&' as '&amp;' and a rule restores it,
    # so a rule written from the window for 'A&B ...' never matched the CSV's
    # 'A&amp;B ...'. Found in November 2026.
    Step "an assigned rule matches a description restored from &amp;" {
        $dir = Join-Path $tmp 'assigned-amp'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $csv = Join-Path $dir 'card.csv'
        $rf  = Join-Path $dir 'card.csv.rules'
        Write-SbTextFile -Path $csv -Text (@(
            'Transaction Date,Post Date,Description,Category,Type,Amount,Memo'
            '7/15/2026,7/16/2026,A&amp;B CAMERA 555-0100,Shopping,Sale,-12.34,'
        ) -join [Environment]::NewLine)
        Write-SbTextFile -Path $rf -Text (@(
            'skip 1'
            'fields date, postdate, description, category, type, amount, memo'
            'date-format %-m/%-d/%Y'
            'currency $'
            'account1 liabilities:creditcard:test'
            ''
            'if %description A&amp;B CAMERA 555-0100'
            '  description A&B CAMERA 555-0100'
        ) -join [Environment]::NewLine)

        $shown = 'A&B CAMERA 555-0100'
        $before = Get-TestCategories -Csv $csv -Rules $rf
        if ($before[$shown] -notlike '*unknown*') {
            throw "expected '$shown' to be uncategorised before a category was chosen, but it went to '$($before[$shown])'"
        }
        $null = Add-SbRule -RulesFile $rf -Description $shown -Account 'expenses:house'
        $to = Get-TestCategories -Csv $csv -Rules $rf
        if ($to[$shown] -ne 'expenses:house') {
            throw "the rule written for '$shown' did not match the CSV's 'A&amp;B': it went to '$($to[$shown])'"
        }
        "'A&amp;B' in the CSV matched the rule written for '$shown'"
    }

    Step "rebuild is reproducible" {
        $first = Get-Content (Join-Path $script:period.JournalDir 'generated.journal') -Raw
        $null   = Invoke-SbRebuild -Period $script:period -Config $cfg
        $second = Get-Content (Join-Path $script:period.JournalDir 'generated.journal') -Raw
        if ($first -ne $second) { throw "rebuilding the same inputs produced a different journal" }
        "same inputs, identical journal"
    }
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ""
if ($script:Fail -eq 0) {
    Write-Host ("  {0} checks passed, 0 failed" -f $script:Pass) -ForegroundColor Green
    Write-Host "  SecretBeans works on this machine." -ForegroundColor Green
    exit 0
} else {
    Write-Host ("  {0} passed, {1} FAILED" -f $script:Pass, $script:Fail) -ForegroundColor Red
    Write-Host "  Please paste the output above into the session so it can be fixed." -ForegroundColor Yellow
    exit 1
}
