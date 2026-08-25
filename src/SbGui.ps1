# ---------------------------------------------------------------------------
#  SecretBeans - the step-by-step window
#
#  Written by Claude (Anthropic) in a Claude Code session with Edwin West,
#  August 2026. Not an Anthropic product and not reviewed by Anthropic.
#
#  See PROVENANCE.md for what was tested and what was not.
#
#  Note on how this is built: New-SbWizardForm constructs the whole window and
#  returns it WITHOUT showing it, and Show-SbWizard is the thin wrapper that
#  displays it. That split exists so the self-check can build the entire UI,
#  inspect it and dispose it without a human watching - the only automated
#  coverage a GUI can realistically have.
# ---------------------------------------------------------------------------

Set-StrictMode -Version 2.0

function Initialize-SbWinForms {
    <#  Load WinForms. Fails clearly rather than mysteriously on a machine without it.  #>
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    } catch {
        throw "Windows Forms is not available on this machine, so the window cannot open. Underlying error: $($_.Exception.Message)"
    }
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { }
}

function New-SbLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 400, [switch]$Bold, [switch]$Dim, [int]$Size = 9)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Left = $X; $l.Top = $Y; $l.Width = $W; $l.AutoSize = $false; $l.Height = 20
    $style = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $style)
    if ($Dim) { $l.ForeColor = [System.Drawing.Color]::DimGray }
    return $l
}

function New-SbButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 90, [int]$H = 28)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Left = $X; $b.Top = $Y; $b.Width = $W; $b.Height = $H
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    return $b
}

function New-SbGrid {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Left = $X; $g.Top = $Y; $g.Width = $W; $g.Height = $H
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.RowHeadersVisible = $false
    $g.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $g.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
    $g.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $g.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Left,Right,Bottom'
    return $g
}

function New-SbWizardForm {
    <#
        Build the window and hand it back, unshown.

        Everything the wizard needs lives in one $state hashtable captured by the
        event handlers. Hashtables are reference types, so a handler that writes to
        it is seen by every other handler - which is what makes the build-and-review
        loop in step 4 work.
    #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$DownloadFolder,
        [string]$TemplateRoot,
        [string]$HledgerPath
    )

    Initialize-SbWinForms

    $state = @{
        ConfigPath     = $ConfigPath
        DownloadFolder = $DownloadFolder
        TemplateRoot   = $TemplateRoot
        HledgerPath    = $HledgerPath
        Config         = $null
        Matches        = $null
        Period         = $null
        Build          = $null
        Step           = 0
        Panels         = @()
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'SecretBeans'
    $form.Width = 940
    $form.Height = 700
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.MinimumSize = New-Object System.Drawing.Size(820, 600)

    $title = New-SbLabel -Text '' -X 20 -Y 16 -W 880 -Bold -Size 13
    $title.Height = 26
    $form.Controls.Add($title)

    $subtitle = New-SbLabel -Text '' -X 20 -Y 44 -W 880 -Dim
    $subtitle.Height = 34
    $form.Controls.Add($subtitle)

    $content = New-Object System.Windows.Forms.Panel
    $content.Left = 20; $content.Top = 84; $content.Width = 880; $content.Height = 500
    $content.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Left,Right,Bottom'
    $form.Controls.Add($content)

    $btnBack   = New-SbButton -Text '< Back'  -X 620 -Y 605
    $btnNext   = New-SbButton -Text 'Next >'  -X 716 -Y 605
    $btnCancel = New-SbButton -Text 'Close'   -X 812 -Y 605
    foreach ($b in $btnBack,$btnNext,$btnCancel) {
        $b.Anchor = [System.Windows.Forms.AnchorStyles]'Bottom,Right'
        $form.Controls.Add($b)
    }
    $status = New-SbLabel -Text '' -X 20 -Y 610 -W 580 -Dim
    $status.Anchor = [System.Windows.Forms.AnchorStyles]'Bottom,Left'
    $form.Controls.Add($status)

    # ---- panels -------------------------------------------------------------
    $panels = @()
    foreach ($n in 1..5) {
        $p = New-Object System.Windows.Forms.Panel
        # Sized to match $content BEFORE anything is added. A new Panel is 200x100
        # until it is laid out, and an anchored child added while it is that size
        # gets a huge negative right margin - so when the panel grows to its real
        # width the child balloons past the edge of the window. Setting the size
        # first makes every anchor offset correct from the start.
        $p.Size = New-Object System.Drawing.Size($content.Width, $content.Height)
        $p.Dock = [System.Windows.Forms.DockStyle]::Fill
        $p.Visible = $false
        $content.Controls.Add($p)
        $panels += $p
    }
    $state.Panels = $panels

    # ---- step 1: where things are ------------------------------------------
    $p1 = $panels[0]
    $p1.Controls.Add((New-SbLabel -Text 'Configuration file' -X 0 -Y 6 -Bold))
    $txtConfig = New-Object System.Windows.Forms.TextBox
    $txtConfig.Left = 0; $txtConfig.Top = 28; $txtConfig.Width = 700
    $txtConfig.Text = [string]$ConfigPath
    $p1.Controls.Add($txtConfig)
    $btnConfigBrowse = New-SbButton -Text 'Browse...' -X 710 -Y 26 -W 90 -H 25
    $p1.Controls.Add($btnConfigBrowse)
    $p1.Controls.Add((New-SbLabel -Text 'Maps each downloaded file to a ledger account. One per ledger.' -X 0 -Y 54 -W 700 -Dim))

    $p1.Controls.Add((New-SbLabel -Text 'Ledger root - where period folders are created' -X 0 -Y 92 -Bold))
    $txtRoot = New-Object System.Windows.Forms.TextBox
    $txtRoot.Left = 0; $txtRoot.Top = 114; $txtRoot.Width = 700
    $p1.Controls.Add($txtRoot)
    $btnRootBrowse = New-SbButton -Text 'Browse...' -X 710 -Y 112 -W 90 -H 25
    $p1.Controls.Add($btnRootBrowse)
    $lblRootNote = New-SbLabel -Text "This is the LedgerRoot setting inside the configuration file above - it is not an environment variable and not a Windows setting. Editing it here writes it back to that file when you press Next. The folder is created if it does not exist." -X 0 -Y 140 -W 800 -Dim
    $lblRootNote.Height = 34
    $p1.Controls.Add($lblRootNote)

    $p1.Controls.Add((New-SbLabel -Text 'Folder your downloads landed in' -X 0 -Y 190 -Bold))
    $txtDl = New-Object System.Windows.Forms.TextBox
    $txtDl.Left = 0; $txtDl.Top = 212; $txtDl.Width = 700
    $txtDl.Text = [string]$DownloadFolder
    $p1.Controls.Add($txtDl)
    $btnDlBrowse = New-SbButton -Text 'Browse...' -X 710 -Y 210 -W 90 -H 25
    $p1.Controls.Add($btnDlBrowse)
    $p1.Controls.Add((New-SbLabel -Text 'Nothing in it is modified. Files are copied into the new period folder.' -X 0 -Y 238 -W 700 -Dim))

    $lblCfgInfo = New-SbLabel -Text '' -X 0 -Y 286 -W 820 -Dim
    $lblCfgInfo.Height = 90
    $p1.Controls.Add($lblCfgInfo)

    $p1.Controls.Add((New-SbLabel -Text 'Note: pressing Next rewrites the configuration file, which does not preserve comments you have added to it.' -X 0 -Y 386 -W 820 -Dim))

    # ---- step 2: which file is which ---------------------------------------
    $p2 = $panels[1]
    $gridMatch = New-SbGrid -X 0 -Y 6 -W 860 -H 400
    [void]$gridMatch.Columns.Add('Name','Account name')
    [void]$gridMatch.Columns.Add('Ledger','Ledger account')
    [void]$gridMatch.Columns.Add('File','Matched file')
    [void]$gridMatch.Columns.Add('Status','Status')
    $gridMatch.Columns['Name'].FillWeight   = 18
    $gridMatch.Columns['Ledger'].FillWeight = 34
    $gridMatch.Columns['File'].FillWeight   = 34
    $gridMatch.Columns['Status'].FillWeight = 14
    $gridMatch.Columns['Name'].ReadOnly = $true
    $gridMatch.Columns['Ledger'].ReadOnly = $true
    $gridMatch.Columns['Status'].ReadOnly = $true
    $p2.Controls.Add($gridMatch)
    $lblMatch = New-SbLabel -Text '' -X 0 -Y 414 -W 860 -Dim
    $lblMatch.Height = 40
    $lblMatch.Anchor = [System.Windows.Forms.AnchorStyles]'Bottom,Left,Right'
    $p2.Controls.Add($lblMatch)

    # ---- step 3: opening balances ------------------------------------------
    $p3 = $panels[2]
    $p3.Controls.Add((New-SbLabel -Text 'Opening balances, from your statements' -X 0 -Y 6 -Bold))
    $p3.Controls.Add((New-SbLabel -Text 'Your bank only lets you download so far back, so the first transaction in the file is not where the account began. Without a figure here every balance is wrong by whatever the account held on day one. Enter what the statement says just before the earliest transaction. A card balance you owe is negative.' -X 0 -Y 28 -W 860 -Dim))
    $gridOpen = New-SbGrid -X 0 -Y 92 -W 860 -H 320
    [void]$gridOpen.Columns.Add('Name','Account name')
    [void]$gridOpen.Columns.Add('Ledger','Ledger account')
    [void]$gridOpen.Columns.Add('Opening','Opening balance')
    $gridOpen.Columns['Name'].FillWeight    = 22
    $gridOpen.Columns['Ledger'].FillWeight  = 48
    $gridOpen.Columns['Opening'].FillWeight = 30
    $gridOpen.Columns['Name'].ReadOnly = $true
    $gridOpen.Columns['Ledger'].ReadOnly = $true
    $p3.Controls.Add($gridOpen)
    $lblOpen = New-SbLabel -Text 'Leave a cell empty to record no opening balance for that account.' -X 0 -Y 420 -W 860 -Dim
    $lblOpen.Anchor = [System.Windows.Forms.AnchorStyles]'Bottom,Left,Right'
    $p3.Controls.Add($lblOpen)

    # ---- step 4: build and review ------------------------------------------
    $p4 = $panels[3]
    $p4.Controls.Add((New-SbLabel -Text 'Period folder name' -X 0 -Y 6 -Bold))
    $txtPeriod = New-Object System.Windows.Forms.TextBox
    $txtPeriod.Left = 0; $txtPeriod.Top = 28; $txtPeriod.Width = 300
    $p4.Controls.Add($txtPeriod)

    $btnBuild = New-SbButton -Text 'Build' -X 320 -Y 26 -W 100 -H 26
    $p4.Controls.Add($btnBuild)
    $btnRules = New-SbButton -Text 'Edit rules...' -X 430 -Y 26 -W 110 -H 26
    $btnRules.Enabled = $false
    $p4.Controls.Add($btnRules)
    $btnFolder = New-SbButton -Text 'Open folder' -X 550 -Y 26 -W 110 -H 26
    $btnFolder.Enabled = $false
    $p4.Controls.Add($btnFolder)

    $lblResult = New-SbLabel -Text 'Nothing built yet.' -X 0 -Y 64 -W 860 -Bold
    $lblResult.Height = 22
    $p4.Controls.Add($lblResult)

    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Left = 0; $txtLog.Top = 92; $txtLog.Width = 860; $txtLog.Height = 186
    $txtLog.Multiline = $true
    $txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $txtLog.ReadOnly = $true
    $txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
    $txtLog.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Left,Right'
    $p4.Controls.Add($txtLog)

    $lblAssign = New-SbLabel -Text 'Anything the rules could not identify. Type a ledger account beside it and press Save - the rule is written to that account''s rules file and kept for next period.' -X 0 -Y 286 -W 860 -Dim
    $lblAssign.Height = 18
    $lblAssign.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Left,Right'
    $p4.Controls.Add($lblAssign)

    $gridAssign = New-SbGrid -X 0 -Y 308 -W 860 -H 132
    [void]$gridAssign.Columns.Add('Source','From')
    [void]$gridAssign.Columns.Add('Date','Date')
    [void]$gridAssign.Columns.Add('Amount','Amount')
    [void]$gridAssign.Columns.Add('Desc','Description')
    [void]$gridAssign.Columns.Add('Assign','Assign to account')
    foreach ($cn in 'Source','Date','Amount','Desc') { $gridAssign.Columns[$cn].ReadOnly = $true }
    $gridAssign.Columns['Source'].FillWeight = 10
    $gridAssign.Columns['Date'].FillWeight   = 11
    $gridAssign.Columns['Amount'].FillWeight = 11
    $gridAssign.Columns['Desc'].FillWeight   = 42
    $gridAssign.Columns['Assign'].FillWeight = 26
    $gridAssign.Columns['Amount'].DefaultCellStyle.Alignment = [System.Windows.Forms.DataGridViewContentAlignment]::MiddleRight
    $gridAssign.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Left,Right,Bottom'
    $p4.Controls.Add($gridAssign)

    $btnAssign = New-SbButton -Text 'Save assignments and build again' -X 0 -Y 448 -W 250 -H 28
    $btnAssign.Enabled = $false
    $btnAssign.Anchor = [System.Windows.Forms.AnchorStyles]'Bottom,Left'
    $p4.Controls.Add($btnAssign)

    $lblAssignNote = New-SbLabel -Text '' -X 260 -Y 454 -W 600 -Dim
    $lblAssignNote.Anchor = [System.Windows.Forms.AnchorStyles]'Bottom,Left,Right'
    $p4.Controls.Add($lblAssignNote)

    # ---- step 5: done -------------------------------------------------------
    $p5 = $panels[4]
    $lblDone = New-SbLabel -Text '' -X 0 -Y 6 -W 860 -Bold -Size 11
    $lblDone.Height = 26
    $p5.Controls.Add($lblDone)
    $txtDone = New-Object System.Windows.Forms.TextBox
    $txtDone.Left = 0; $txtDone.Top = 40; $txtDone.Width = 860; $txtDone.Height = 400
    $txtDone.Multiline = $true
    $txtDone.ReadOnly = $true
    $txtDone.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $txtDone.Font = New-Object System.Drawing.Font('Consolas', 9)
    $txtDone.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Left,Right,Bottom'
    $p5.Controls.Add($txtDone)

    # keep everything the handlers need
    $state.Controls = @{
        Title=$title; Subtitle=$subtitle; Status=$status
        Back=$btnBack; Next=$btnNext; Cancel=$btnCancel
        Config=$txtConfig; Downloads=$txtDl; CfgInfo=$lblCfgInfo
        ConfigBrowse=$btnConfigBrowse; DownloadsBrowse=$btnDlBrowse
        LedgerRoot=$txtRoot; LedgerRootBrowse=$btnRootBrowse
        GridMatch=$gridMatch; MatchNote=$lblMatch
        GridOpen=$gridOpen
        Period=$txtPeriod; Build=$btnBuild; Rules=$btnRules; Folder=$btnFolder
        Result=$lblResult; Log=$txtLog
        GridAssign=$gridAssign; SaveAssign=$btnAssign; AssignNote=$lblAssignNote
        DoneLabel=$lblDone; DoneText=$txtDone
    }
    $form.Tag = $state

    Register-SbWizardHandlers -Form $form
    Set-SbWizardStep -Form $form -Step 1
    return $form
}

function Set-SbWizardStep {
    <#  Show one step, set its wording, and put the buttons in the right state.  #>
    param(
        [Parameter(Mandatory)]$Form,
        [Parameter(Mandatory)][int]$Step
    )
    $s = $Form.Tag
    $c = $s.Controls
    $s.Step = $Step

    for ($i = 0; $i -lt $s.Panels.Count; $i++) { $s.Panels[$i].Visible = ($i -eq ($Step - 1)) }

    # Recorded separately because Control.Visible is a getter for *effective*
    # visibility: until the form has actually been shown it returns false for every
    # child no matter what was assigned. Anything wanting to know which step is
    # showing - the self-check included - has to read this instead.
    $s.ActivePanel = $Step - 1

    switch ($Step) {
        1 {
            $c.Title.Text    = 'Step 1 of 5  -  Where things are'
            $c.Subtitle.Text = 'Point SecretBeans at your configuration and at the folder your downloads landed in.'
            $c.Back.Enabled = $false; $c.Next.Enabled = $true; $c.Next.Text = 'Next >'
        }
        2 {
            $c.Title.Text    = 'Step 2 of 5  -  Which file is which'
            $c.Subtitle.Text = 'Downloads are named differently every month, so check the tool matched them to the right accounts before it copies anything.'
            $c.Back.Enabled = $true; $c.Next.Enabled = $true; $c.Next.Text = 'Next >'
        }
        3 {
            $c.Title.Text    = 'Step 3 of 5  -  Opening balances'
            $c.Subtitle.Text = 'Type what each account held just before its earliest transaction. These are saved back to your configuration.'
            $c.Back.Enabled = $true; $c.Next.Enabled = $true; $c.Next.Text = 'Next >'
        }
        4 {
            $c.Title.Text    = 'Step 4 of 5  -  Build, look, fix, build again'
            $c.Subtitle.Text = 'Build the journal, read what it reports, correct the rules, and build again. Nothing is final until you move on.'
            $c.Back.Enabled = $true
            $c.Next.Enabled = ($null -ne $s.Build)
            $c.Next.Text = 'Next >'
        }
        5 {
            $c.Title.Text    = 'Step 5 of 5  -  Done'
            $c.Subtitle.Text = 'The period folder holds the downloads, the rules used on them, and the journal they produced.'
            $c.Back.Enabled = $true; $c.Next.Enabled = $true; $c.Next.Text = 'Finish'
        }
    }
}

function Format-SbDiagnostics {
    <#  The build report, as text. Kept separate from the window so it can be tested.  #>
    param([Parameter(Mandatory)]$Build)

    $d   = $Build.Diagnostics
    $nl  = [Environment]::NewLine
    $out = New-Object System.Collections.Generic.List[string]

    $out.Add('PER FILE')
    foreach ($f in $Build.PerFile) {
        if ($f.Ok) { $out.Add(('  {0,-14} {1,6} transactions' -f $f.Name, $f.Transactions)) }
        else       { $out.Add(('  {0,-14} FAILED: {1}' -f $f.Name, $f.Error)) }
    }
    $out.Add('')
    $out.Add('SUMMARY')
    $out.Add(('  transactions        {0}' -f $d.Transactions))
    if ($d.FirstDate) { $out.Add(('  covering            {0:yyyy-MM-dd} to {1:yyyy-MM-dd}' -f $d.FirstDate, $d.LastDate)) }
    if ($d.CheckPassed) { $out.Add('  hledger check       passed') }
    else { $out.Add('  hledger check       FAILED'); $out.Add('    ' + $d.CheckOutput) }

    $out.Add('')
    if ($d.UnknownCount -eq 0) {
        $out.Add('UNCATEGORISED       none')
    } else {
        $out.Add(('UNCATEGORISED       {0} - add a rule for each, then build again' -f $d.UnknownCount))
        foreach ($u in ($d.Unknown | Select-Object -First 40)) {
            $out.Add(('  {0:yyyy-MM-dd}  {1,10:N2}  {2}' -f $u.Date, $u.Amount, $u.Description))
        }
        if ($d.UnknownCount -gt 40) { $out.Add(('  ... and {0} more' -f ($d.UnknownCount - 40))) }
    }

    $out.Add('')
    if ($d.ReviewCount -eq 0) {
        $out.Add('AWAITING REVIEW     none')
    } else {
        $out.Add(('AWAITING REVIEW     {0} - cheques and the like, which no description can identify' -f $d.ReviewCount))
        foreach ($r in ($d.Review | Select-Object -First 40)) {
            $out.Add(('  {0:yyyy-MM-dd}  {1,10:N2}  {2}' -f $r.Date, $r.Amount, $r.Description))
        }
        if ($d.ReviewCount -gt 40) { $out.Add(('  ... and {0} more' -f ($d.ReviewCount - 40))) }
    }

    $out.Add('')
    $cross = 0
    if ($d.PSObject.Properties.Name -contains 'CrossSourceDupes') { $cross = $d.CrossSourceDupes }
    if ($d.DupeCount -eq 0) {
        $out.Add('POSSIBLE DUPLICATES none')
    } else {
        $out.Add(('POSSIBLE DUPLICATES {0} flagged, {1} of them across two statements' -f $d.DupeCount, $cross))
        $out.Add('  A transfer between two accounts you own appears on BOTH statements. If both')
        $out.Add('  sides record it, it is counted twice and every expense figure still looks')
        $out.Add('  correct. Cross-statement pairs are the ones to worry about; see docs/TRANSFERS.md.')
        $out.Add('')
        foreach ($p in ($d.PossibleDupes | Select-Object -First 25)) {
            $sev = 'Review'
            if ($p.PSObject.Properties.Name -contains 'Severity') { $sev = $p.Severity }
            $out.Add(('  [{0,-16}] {1,10:N2}  {2} day(s) apart' -f $sev, $p.Amount, $p.DaysApart))
            $out.Add(('       {0}' -f $p.A))
            $out.Add(('       {0}' -f $p.B))
        }
        if ($d.DupeCount -gt 25) { $out.Add(('  ... and {0} more' -f ($d.DupeCount - 25))) }
    }

    return ($out -join $nl)
}

function Register-SbWizardHandlers {
    param([Parameter(Mandatory)]$Form)

    $s = $Form.Tag
    $c = $s.Controls

    $browseFolder = {
        param($current)
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($current -and (Test-Path -LiteralPath $current)) { $dlg.SelectedPath = $current }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
        return $null
    }

    $c.Config.Add_TextChanged({
        $st = $Form.Tag
        $p = $st.Controls.Config.Text
        if ($p -and (Test-Path -LiteralPath $p)) {
            try {
                $cfg = Import-SbConfig -Path $p
                $st.Controls.CfgInfo.ForeColor = [System.Drawing.Color]::DimGray
                $st.Controls.CfgInfo.Text = ("Loaded {0} account(s): {1}" -f $cfg.Accounts.Count,
                    (($cfg.Accounts | ForEach-Object { $_.Name }) -join ', '))
                if (-not $st.Controls.LedgerRoot.Text) { $st.Controls.LedgerRoot.Text = [string]$cfg.LedgerRoot }
            } catch {
                $st.Controls.CfgInfo.ForeColor = [System.Drawing.Color]::Firebrick
                $st.Controls.CfgInfo.Text = $_.Exception.Message
            }
        } else {
            $st.Controls.CfgInfo.ForeColor = [System.Drawing.Color]::DimGray
            $st.Controls.CfgInfo.Text = 'No configuration at that path yet. templates\config.psd1 is a starting point to copy.'
        }
    }.GetNewClosure())

    $c.ConfigBrowse.Add_Click({
        $st = $Form.Tag
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'PowerShell data file (*.psd1)|*.psd1|All files (*.*)|*.*'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $st.Controls.Config.Text = $dlg.FileName }
    }.GetNewClosure())

    $c.LedgerRootBrowse.Add_Click({
        $st = $Form.Tag
        $r = & $browseFolder $st.Controls.LedgerRoot.Text
        if ($r) { $st.Controls.LedgerRoot.Text = $r }
    }.GetNewClosure())

    $c.DownloadsBrowse.Add_Click({
        $st = $Form.Tag
        $r = & $browseFolder $st.Controls.Downloads.Text
        if ($r) { $st.Controls.Downloads.Text = $r }
    }.GetNewClosure())

    $c.Build.Add_Click({
        $st = $Form.Tag
        $cc = $st.Controls
        $cc.Log.Text = 'Building...'
        $cc.Result.Text = 'Building...'
        $Form.Refresh()
        try {
            $name = $cc.Period.Text.Trim()
            if (-not $name) { throw 'Give the period folder a name.' }
            $prev = $null
            $existing = @(Get-ChildItem -LiteralPath $st.Config.LedgerRoot -Directory -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -ne $name } | Sort-Object Name)
            if ($existing.Count -gt 0) { $prev = $existing[$existing.Count-1].Name }

            $st.Period = New-SbPeriodFolder -LedgerRoot $st.Config.LedgerRoot -PeriodName $name `
                            -Matches $st.Matches -Config $st.Config `
                            -TemplateRoot $st.TemplateRoot -PreviousPeriod $prev
            $st.Build = Invoke-SbRebuild -Period $st.Period -Config $st.Config -HledgerPath $st.HledgerPath

            $d = $st.Build.Diagnostics
            $cross = 0
            if ($d.PSObject.Properties.Name -contains 'CrossSourceDupes') { $cross = $d.CrossSourceDupes }
            $ok = $d.CheckPassed -and $d.UnknownCount -eq 0 -and $cross -eq 0
            if ($ok) {
                $cc.Result.ForeColor = [System.Drawing.Color]::ForestGreen
                $cc.Result.Text = ('Built {0} transactions. Nothing uncategorised, no cross-statement duplicates.' -f $d.Transactions)
            } else {
                $cc.Result.ForeColor = [System.Drawing.Color]::DarkOrange
                $cc.Result.Text = ('Built {0} transactions - {1} uncategorised, {2} cross-statement duplicate(s). Worth a look below.' -f $d.Transactions, $d.UnknownCount, $cross)
            }
            $cc.Log.Text = (Format-SbDiagnostics -Build $st.Build) -replace "`r`n", "`n" -replace "`n", "`r`n"

            $cc.GridAssign.Rows.Clear()
            # Enumerated one collection at a time on purpose - see the note in
            # Get-SbDiagnostics about @() over a List.
            $toAssign = New-Object System.Collections.Generic.List[object]
            foreach ($u in $d.Unknown) { $toAssign.Add($u) }
            foreach ($u in $d.Review)  { $toAssign.Add($u) }
            foreach ($u in $toAssign) {
                $amt = ''
                if ($null -ne $u.Amount) { $amt = '{0:N2}' -f $u.Amount }
                [void]$cc.GridAssign.Rows.Add($u.Source, ('{0:yyyy-MM-dd}' -f $u.Date), $amt, $u.Description, '')
            }
            $cc.SaveAssign.Enabled = ($cc.GridAssign.Rows.Count -gt 0)
            if ($cc.GridAssign.Rows.Count -eq 0) { $cc.AssignNote.Text = 'Nothing left to assign.' }
            else { $cc.AssignNote.Text = ('{0} item(s) waiting for a category.' -f $cc.GridAssign.Rows.Count) }

            $cc.Rules.Enabled = $true
            $cc.Folder.Enabled = $true
            $cc.Build.Text = 'Build again'
            $cc.Next.Enabled = $true
        } catch {
            $cc.Result.ForeColor = [System.Drawing.Color]::Firebrick
            $cc.Result.Text = 'Build failed.'
            $detail = $_.Exception.Message
            if ($_.ScriptStackTrace) { $detail = $detail + [Environment]::NewLine + [Environment]::NewLine + $_.ScriptStackTrace }
            $cc.Log.Text = ($detail -replace "`r`n", "`n" -replace "`n", "`r`n")
            $cc.Next.Enabled = $false
        }
    }.GetNewClosure())

    $c.SaveAssign.Add_Click({
        $st = $Form.Tag
        $cc = $st.Controls
        try {
            $written = 0
            $skipped = 0
            foreach ($row in $cc.GridAssign.Rows) {
                $acct = [string]$row.Cells['Assign'].Value
                if ([string]::IsNullOrWhiteSpace($acct)) { $skipped++; continue }
                $acct = $acct.Trim()
                $src  = [string]$row.Cells['Source'].Value
                $desc = [string]$row.Cells['Desc'].Value

                $file = $st.Period.Files | Where-Object { $_.Name -eq $src } | Select-Object -First 1
                if (-not $file) { throw "Cannot tell which rules file '$desc' came from (source '$src')." }

                [void](Add-SbRule -RulesFile $file.Rules -Description $desc -Account $acct `
                                  -Comment ('{0}  {1}' -f $row.Cells['Date'].Value, $row.Cells['Amount'].Value))
                $written++
            }
            if ($written -eq 0) {
                $cc.AssignNote.Text = 'Nothing typed in the Assign column yet.'
                return
            }
            $cc.AssignNote.Text = ('{0} rule(s) written. Rebuilding...' -f $written)
            $Form.Refresh()
            $cc.Build.PerformClick()
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'SecretBeans',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    }.GetNewClosure())

    $c.Rules.Add_Click({
        $st = $Form.Tag
        if ($st.Period) { Start-Process explorer.exe $st.Period.RulesDir }
    }.GetNewClosure())

    $c.Folder.Add_Click({
        $st = $Form.Tag
        if ($st.Period) { Start-Process explorer.exe $st.Period.Root }
    }.GetNewClosure())

    $c.Back.Add_Click({
        $st = $Form.Tag
        if ($st.Step -gt 1) { Set-SbWizardStep -Form $Form -Step ($st.Step - 1) }
    }.GetNewClosure())

    $c.Next.Add_Click({
        $st = $Form.Tag
        $cc = $st.Controls
        try {
            switch ($st.Step) {
                1 {
                    $st.ConfigPath = $cc.Config.Text.Trim()
                    $st.DownloadFolder = $cc.Downloads.Text.Trim()
                    $st.Config = Import-SbConfig -Path $st.ConfigPath
                    if (-not (Test-Path -LiteralPath $st.DownloadFolder)) { throw "That downloads folder does not exist: $($st.DownloadFolder)" }

                    $rootTyped = $cc.LedgerRoot.Text.Trim()
                    if (-not $rootTyped) { throw 'Give a ledger root - the folder where period folders are created.' }
                    if ($rootTyped -ne [string]$st.Config.LedgerRoot) {
                        # Written straight back to the config file, so the box and the file
                        # never disagree about where the ledger lives.
                        $st.Config.LedgerRoot = $rootTyped
                        Export-SbConfig -Config $st.Config -Path $st.ConfigPath
                    }
                    if (-not (Test-Path -LiteralPath $st.Config.LedgerRoot)) {
                        New-Item -ItemType Directory -Path $st.Config.LedgerRoot -Force | Out-Null
                    }

                    $st.Matches = @(Get-SbDownloadMatches -DownloadFolder $st.DownloadFolder -Config $st.Config)
                    $cc.GridMatch.Rows.Clear()
                    foreach ($m in $st.Matches) {
                        $fn = ''
                        if ($m.File) { $fn = $m.File.Name }
                        $i = $cc.GridMatch.Rows.Add($m.Name, $m.Account, $fn, $m.Status)
                        $row = $cc.GridMatch.Rows[$i]
                        if ($m.Status -eq 'Missing')      { $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose }
                        elseif ($m.Status -eq 'Ambiguous'){ $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightGoldenrodYellow }
                        elseif ($m.Status -eq 'Unmatched'){ $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::Gainsboro }
                    }
                    $miss = @($st.Matches | Where-Object { $_.Status -eq 'Missing' }).Count
                    $extra= @($st.Matches | Where-Object { $_.Status -eq 'Unmatched' }).Count
                    $amb  = @($st.Matches | Where-Object { $_.Status -eq 'Ambiguous' }).Count
                    $cc.MatchNote.Text = ("{0} matched. {1} account(s) with no download, {2} ambiguous, {3} file(s) matching no account. You can carry on regardless - accounts with no download are simply skipped." -f
                        @($st.Matches | Where-Object { $_.Status -eq 'Ok' }).Count, $miss, $amb, $extra)
                    Set-SbWizardStep -Form $Form -Step 2
                }
                2 {
                    $cc.GridOpen.Rows.Clear()
                    foreach ($a in $st.Config.Accounts) {
                        $ob = ''
                        if ($a.ContainsKey('OpeningBalance') -and $null -ne $a.OpeningBalance) { $ob = [string]$a.OpeningBalance }
                        [void]$cc.GridOpen.Rows.Add($a.Name, $a.Account, $ob)
                    }
                    Set-SbWizardStep -Form $Form -Step 3
                }
                3 {
                    foreach ($row in $cc.GridOpen.Rows) {
                        $name = [string]$row.Cells['Name'].Value
                        $val  = [string]$row.Cells['Opening'].Value
                        foreach ($a in $st.Config.Accounts) {
                            if ($a.Name -ne $name) { continue }
                            if ([string]::IsNullOrWhiteSpace($val)) { $a['OpeningBalance'] = $null }
                            else {
                                $parsed = 0.0
                                if (-not [double]::TryParse($val, [ref]$parsed)) { throw "'$val' for $name is not a number." }
                                $a['OpeningBalance'] = $parsed
                            }
                        }
                    }
                    Export-SbConfig -Config $st.Config -Path $st.ConfigPath
                    if (-not $cc.Period.Text) { $cc.Period.Text = New-SbPeriodName }
                    Set-SbWizardStep -Form $Form -Step 4
                }
                4 {
                    if (-not $st.Build) { throw 'Build once before moving on.' }
                    $d = $st.Build.Diagnostics
                    $cc.DoneLabel.Text = ('{0} - {1} transactions' -f $st.Period.PeriodName, $d.Transactions)
                    $lines = @(
                        ('Period folder : {0}' -f $st.Period.Root),
                        ('Journal       : {0}' -f $st.Build.MainJournal),
                        '',
                        'Report on it with:',
                        ('  hledger -f "{0}" bal -M -p {1} -T -A' -f $st.Build.MainJournal, (Get-Date).Year),
                        '',
                        'Still to do by hand:',
                        ('  {0} awaiting review   hledger -f "{1}" bal {2}' -f $d.ReviewCount, $st.Build.MainJournal, $st.Config.ReviewAccount),
                        '',
                        'The folder holds the downloads, the rules used on them and the journal they',
                        'produced. Delete the journal folder, run this again on the same folder, and you',
                        'should get the same journal back. If you do not, something is wrong.'
                    )
                    $cc.DoneText.Text = ($lines -join [Environment]::NewLine)
                    Set-SbWizardStep -Form $Form -Step 5
                }
                5 { $Form.Close() }
            }
        } catch {
            [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'SecretBeans',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    }.GetNewClosure())

    $c.Cancel.Add_Click({ $Form.Close() }.GetNewClosure())
}

function Show-SbWizard {
    <#  Build the window and show it. The thin wrapper - all the work is in New-SbWizardForm.  #>
    [CmdletBinding()]
    param(
        [string]$ConfigPath,
        [string]$DownloadFolder,
        [string]$TemplateRoot,
        [string]$HledgerPath
    )
    $form = New-SbWizardForm -ConfigPath $ConfigPath -DownloadFolder $DownloadFolder `
                             -TemplateRoot $TemplateRoot -HledgerPath $HledgerPath
    try { [void]$form.ShowDialog() } finally { $form.Dispose() }
}
