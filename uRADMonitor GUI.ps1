<#
.SYNOPSIS
    uRADMonitor API Helper - minimal Windows Forms GUI for 'uRADMonitor - Get API Headers and Data.ps1'.

.DESCRIPTION
    Provides a small window to enter the uRADMonitor User ID and User Key, run an API query for a
    given path, register a new device (DIDAP), or preview the request headers. It simply calls the
    core script located next to it and shows the result as formatted JSON.

    Windows Forms requires an STA thread; if launched under an MTA host (e.g. pwsh), the script
    relaunches itself with Windows PowerShell in STA mode.

    Branding assets (optional, loaded from the script folder if present):
    - uradmonitor-logo-2026.png : header logo
    - uradmonitor-logo-2026.ico : window/taskbar icon

.NOTES
    Author      : Don Zalmrol
    Script ID   : URADMONITOR_GUI
    Created     : 2026

    Version History:
    1.0.0 - Initial GUI: User ID / User Key inputs, path query, create device, show headers
    1.1.0 - Added path preset dropdown with {id} substitution, a device-id picker with 'Refresh
            list', and a 'Delete Device' button (opens the Dashboard; the API has no delete endpoint)
    1.2.0 - Removed the 'Delete Device' button (the public API has no delete endpoint)
    1.3.0 - Renamed to 'uRADMonitor API Helper', added logo header and window icon
    1.3.1 - Added window icon branding, footer version/copyright text, and Don Zalmrol attribution
    1.3.2 - Moved the device-list refresh action beside Get Data
    1.3.3 - Used ASCII footer separators and placed Refresh list before Get Data
    1.3.4 - Fixed footer hyperlinks to use the clicked link URL
    1.3.5 - Updated the header logo asset
    1.3.6 - Updated the window and taskbar icon to use the new uRADMonitor logo
#>

# Windows Forms needs a single-threaded apartment; relaunch in STA if necessary.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptVersion = '1.3.6'
$createdYear = 2026
$currentYear = (Get-Date).Year

$corePath = Join-Path -Path $PSScriptRoot -ChildPath 'uRADMonitor - Get API Headers and Data.ps1'
if (-not (Test-Path -LiteralPath $corePath)) {
    [System.Windows.Forms.MessageBox]::Show(
        "Core script not found:`n$corePath",
        'uRADMonitor API Helper', 'OK', 'Error') | Out-Null
    return
}

# Runs the core script with the supplied parameters and returns output as a display string.
function Invoke-Core {
    param([hashtable] $Params)

    try {
        $output = & $corePath @Params 2>&1

        if ($null -eq $output) { return '(no output)' }

        # Error records: show the message only.
        if ($output -is [System.Management.Automation.ErrorRecord]) {
            return "ERROR: $($output.Exception.Message)"
        }

        # Objects/collections: render as JSON; fall back to plain string.
        try   { return ($output | ConvertTo-Json -Depth 8) }
        catch { return ($output | Out-String) }
    }
    catch {
        return "ERROR: $($_.Exception.Message)"
    }
}

# -----------------------------
# Build the form
# -----------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text          = "uRADMonitor API Helper v$scriptVersion"
$form.Size          = New-Object System.Drawing.Size(560, 620)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(560, 620)
$form.ShowIcon      = $true

# Optional branding assets sitting next to the script.
$iconPath = Join-Path $PSScriptRoot 'uradmonitor-logo-2026.ico'
if (Test-Path -LiteralPath $iconPath) {
    try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { }
}

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size     = New-Object System.Drawing.Size(560, 60)
$header.Dock     = 'Top'
$form.Controls.Add($header)

$logoPath = Join-Path $PSScriptRoot 'uradmonitor-logo-2026.png'
if (Test-Path -LiteralPath $logoPath) {
    $logo = New-Object System.Windows.Forms.PictureBox
    $logo.Location = New-Object System.Drawing.Point(12, 6)
    $logo.Size     = New-Object System.Drawing.Size(48, 48)
    $logo.SizeMode = 'Zoom'
    try { $logo.Image = [System.Drawing.Image]::FromFile($logoPath) } catch { }
    $header.Controls.Add($logo)
}

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text     = 'uRADMonitor API Helper'
$lblTitle.Location = New-Object System.Drawing.Point(70, 18)
$lblTitle.AutoSize = $true
$lblTitle.Font     = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
$header.Controls.Add($lblTitle)

function New-Label {
    param([string] $Text, [int] $X, [int] $Y)
    $l = New-Object System.Windows.Forms.Label
    $l.Text     = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.AutoSize = $true
    return $l
}

$form.Controls.Add((New-Label 'User ID:'  15 78))
$txtUserId = New-Object System.Windows.Forms.TextBox
$txtUserId.Location = New-Object System.Drawing.Point(120, 75)
$txtUserId.Size     = New-Object System.Drawing.Size(180, 23)
$form.Controls.Add($txtUserId)

$form.Controls.Add((New-Label 'User Key:' 15 110))
$txtUserKey = New-Object System.Windows.Forms.TextBox
$txtUserKey.Location             = New-Object System.Drawing.Point(120, 107)
$txtUserKey.Size                 = New-Object System.Drawing.Size(300, 23)
$txtUserKey.UseSystemPasswordChar = $true
$form.Controls.Add($txtUserKey)

$chkShowKey = New-Object System.Windows.Forms.CheckBox
$chkShowKey.Text     = 'Show'
$chkShowKey.Location = New-Object System.Drawing.Point(430, 109)
$chkShowKey.AutoSize = $true
$chkShowKey.Add_CheckedChanged({ $txtUserKey.UseSystemPasswordChar = -not $chkShowKey.Checked })
$form.Controls.Add($chkShowKey)

$form.Controls.Add((New-Label 'Path:' 15 142))
$cmbPath = New-Object System.Windows.Forms.ComboBox
$cmbPath.Location      = New-Object System.Drawing.Point(120, 139)
$cmbPath.Size          = New-Object System.Drawing.Size(405, 23)
$cmbPath.DropDownStyle = 'DropDown'
# {id} is replaced with the selected Device ID when the request runs.
[void]$cmbPath.Items.AddRange(@(
    'devices',
    'devices/{id}',
    'devices/{id}/all/3600',
    'devices/{id}/all/86400',
    'devices/{id}/all/604800'
))
$cmbPath.Text = 'devices'
$form.Controls.Add($cmbPath)

$form.Controls.Add((New-Label 'Device ID:' 15 174))
$cmbDevice = New-Object System.Windows.Forms.ComboBox
$cmbDevice.Location     = New-Object System.Drawing.Point(120, 171)
$cmbDevice.Size         = New-Object System.Drawing.Size(200, 23)
$cmbDevice.DropDownStyle = 'DropDown'
$form.Controls.Add($cmbDevice)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text     = 'Refresh list'
$btnRefresh.Location = New-Object System.Drawing.Point(15, 208)
$btnRefresh.Size     = New-Object System.Drawing.Size(118, 30)

# Action buttons
$btnGet = New-Object System.Windows.Forms.Button
$btnGet.Text     = 'Get Data'
$btnGet.Location = New-Object System.Drawing.Point(140, 208)
$btnGet.Size     = New-Object System.Drawing.Size(118, 30)
$form.Controls.Add($btnGet)
$form.Controls.Add($btnRefresh)

$btnCreate = New-Object System.Windows.Forms.Button
$btnCreate.Text     = 'Create Device'
$btnCreate.Location = New-Object System.Drawing.Point(265, 208)
$btnCreate.Size     = New-Object System.Drawing.Size(118, 30)
$form.Controls.Add($btnCreate)

$btnHeaders = New-Object System.Windows.Forms.Button
$btnHeaders.Text     = 'Show Headers'
$btnHeaders.Location = New-Object System.Drawing.Point(390, 208)
$btnHeaders.Size     = New-Object System.Drawing.Size(135, 30)
$form.Controls.Add($btnHeaders)

# Output box
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15, 245)
$progressBar.Size     = New-Object System.Drawing.Size(510, 18)
$progressBar.Style    = 'Continuous'
$progressBar.Visible  = $false
$form.Controls.Add($progressBar)

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Location   = New-Object System.Drawing.Point(15, 270)
$txtOutput.Size       = New-Object System.Drawing.Size(510, 265)
$txtOutput.Multiline  = $true
$txtOutput.ScrollBars = 'Both'
$txtOutput.ReadOnly   = $true
$txtOutput.WordWrap   = $false
$txtOutput.Font       = New-Object System.Drawing.Font('Consolas', 9)
$txtOutput.Anchor     = 'Top,Bottom,Left,Right'
$form.Controls.Add($txtOutput)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(15, 542)
$lblStatus.Size     = New-Object System.Drawing.Size(510, 20)
$lblStatus.Anchor   = 'Bottom,Left,Right'
$form.Controls.Add($lblStatus)

$lblFooter = New-Object System.Windows.Forms.LinkLabel
$lblFooter.Location = New-Object System.Drawing.Point(15, 560)
$lblFooter.Size     = New-Object System.Drawing.Size(510, 18)
$lblFooter.Text     = "Version $scriptVersion - Copyright $createdYear - $currentYear Don Zalmrol - GitHub"
$lblFooter.LinkColor = [System.Drawing.Color]::FromArgb(26, 92, 165)
$lblFooter.ActiveLinkColor = [System.Drawing.Color]::FromArgb(18, 68, 120)
$lblFooter.VisitedLinkColor = [System.Drawing.Color]::FromArgb(26, 92, 165)
$lblFooter.LinkBehavior = [System.Windows.Forms.LinkBehavior]::AlwaysUnderline
$lblFooter.TextAlign = 'MiddleCenter'
$lblFooter.Anchor   = 'Bottom,Left,Right'
$lblFooter.Font = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Regular)
$lblFooter.Links.Clear()
$lblFooter.Links.Add($lblFooter.Text.IndexOf('Don Zalmrol'), 'Don Zalmrol'.Length, 'https://www.don-zalmrol.be') | Out-Null
$lblFooter.Links.Add($lblFooter.Text.IndexOf('GitHub'), 'GitHub'.Length, 'https://github.com/DonZalmrol') | Out-Null
$lblFooter.Add_LinkClicked({
    param($sender, $eventArgs)
    $link = [string]$eventArgs.Link.LinkData
    if (-not [string]::IsNullOrWhiteSpace($link)) {
        Start-Process -FilePath $link
    }
})
$form.Controls.Add($lblFooter)

# Validates required credentials for authenticated actions.
function Test-Credentials {
    if ([string]::IsNullOrWhiteSpace($txtUserId.Text) -or [string]::IsNullOrWhiteSpace($txtUserKey.Text)) {
        $txtOutput.Text = 'Please enter both a User ID and a User Key.'
        return $false
    }
    return $true
}

# Runs an action with a wait cursor and status update.
function Invoke-Action {
    param([string] $Status, [scriptblock] $Action)

    $lblStatus.Text  = $Status
    $form.Cursor     = 'WaitCursor'
    $form.Refresh()
    try   { $txtOutput.Text = (& $Action) }
    finally {
        $form.Cursor    = 'Default'
        $lblStatus.Text = 'Done.'
    }
}

# Sends a short activation ramp after device registration. Values rise from 0 to 5 over 5 one-minute
# uploads to confirm the device settles and is ready for normal uploads while avoiding SHIELD rate spikes.
function Invoke-ActivationSequence {
    param(
        [string] $UserId,
        [string] $UserHash,
        [string] $DeviceId,
        [int] $SyncCount = 5,
        [int] $IntervalSeconds = 60
    )

    $progressBar.Minimum = 0
    $progressBar.Maximum = $SyncCount
    $progressBar.Value = 0
    $progressBar.Visible = $true

    $values = @()
    if ($SyncCount -eq 1) {
        $values = @(5)
    }
    else {
        for ($i = 0; $i -lt $SyncCount - 1; $i++) {
            $values += [Math]::Floor(($i / [double]([Math]::Max(1, $SyncCount - 1))) * 5)
        }
        $values += 5
    }

    for ($index = 0; $index -lt $values.Count; $index++) {
        $value = [int]$values[$index]
        $txtOutput.Text = "Activation sync $($index + 1)/$($values.Count): sending dummy value $value..."
        $lblStatus.Text = "Sync $($index + 1)/$($values.Count): $value"
        $progressBar.Value = $index + 1
        $form.Refresh()

        $output = & $corePath -UserId $UserId -UserHash $UserHash -DeviceId $DeviceId -SendDummyData -DummyDataValue $value 2>&1
        if ($output -is [System.Management.Automation.ErrorRecord]) {
            $txtOutput.Text = "ERROR: $($output.Exception.Message)"
            break
        }

        if ($index -lt ($values.Count - 1) -and $IntervalSeconds -gt 0) {
            for ($wait = 0; $wait -lt $IntervalSeconds; $wait++) {
                $remaining = $IntervalSeconds - $wait
                $lblStatus.Text = "Waiting $remaining s before next activation sync..."
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Seconds 1
            }
        }
    }

    $lblStatus.Text = 'Done.'
    $progressBar.Visible = $false
}

# Builds the effective API path, substituting {id} with the selected Device ID.
function Get-EffectivePath {
    $p = $cmbPath.Text
    if ($p -match '\{id\}') {
        $id = $cmbDevice.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($id)) { return $null }
        $p = $p -replace '\{id\}', $id
    }
    return $p
}

$btnGet.Add_Click({
    if (-not (Test-Credentials)) { return }
    $path = Get-EffectivePath
    if ($null -eq $path) {
        $txtOutput.Text = "This path needs a Device ID. Select or type one in the 'Device ID' box (use 'Refresh list' to load your devices)."
        return
    }
    Invoke-Action 'Querying API...' {
        Invoke-Core @{ UserId = $txtUserId.Text; UserHash = $txtUserKey.Text; Path = $path }
    }
})

$btnRefresh.Add_Click({
    if (-not (Test-Credentials)) { return }
    $lblStatus.Text = 'Loading devices...'
    $form.Cursor = 'WaitCursor'; $form.Refresh()
    try {
        $devices = & $corePath -UserId $txtUserId.Text -UserHash $txtUserKey.Text -Path 'devices' 2>&1
        $cmbDevice.Items.Clear()
        $ids = @()
        foreach ($d in $devices) {
            if (($d.PSObject.Properties.Name -contains 'id') -and $d.id) { $ids += [string]$d.id }
        }
        if ($ids.Count -gt 0) {
            [void]$cmbDevice.Items.AddRange($ids)
            $cmbDevice.SelectedIndex = 0
            $txtOutput.Text = "Loaded $($ids.Count) device id(s)."
        }
        else {
            $txtOutput.Text = "No device ids found. Response:`r`n" + ($devices | Out-String)
        }
    }
    catch { $txtOutput.Text = "ERROR: $($_.Exception.Message)" }
    finally { $form.Cursor = 'Default'; $lblStatus.Text = 'Done.' }
})

$btnCreate.Add_Click({
    if (-not (Test-Credentials)) { return }
    $confirm = [System.Windows.Forms.MessageBox]::Show(
        'Register a new device on your uRADMonitor account and send a 5-minute dummy activation ramp?',
        'Create Device', 'YesNo', 'Question')
    if ($confirm -ne 'Yes') { return }

    $lblStatus.Text = 'Registering device...'
    $form.Cursor = 'WaitCursor'; $form.Refresh()
    try {
        $result = & $corePath -UserId $txtUserId.Text -UserHash $txtUserKey.Text -CreateDevice -ActivationSyncs 0 2>&1
        if ($result -is [System.Management.Automation.ErrorRecord]) {
            $txtOutput.Text = "ERROR: $($result.Exception.Message)"
            return
        }

        $json = $result | ConvertTo-Json -Depth 8

        if ($null -ne $result -and $result.NewDeviceId) {
            $txtOutput.Text = "Registered device: $($result.NewDeviceId)`r`n`r`n$json"
            Invoke-ActivationSequence -UserId $txtUserId.Text -UserHash $txtUserKey.Text -DeviceId $result.NewDeviceId -SyncCount 5 -IntervalSeconds 60
            $txtOutput.Text = "Registered device: $($result.NewDeviceId)`r`nActivation sequence complete.`r`n`r`n$json"
        }
        else {
            $txtOutput.Text = $json
        }
    }
    catch {
        $txtOutput.Text = "ERROR: $($_.Exception.Message)"
    }
    finally {
        $form.Cursor = 'Default'
        $lblStatus.Text = 'Done.'
    }
})

$btnHeaders.Add_Click({
    if (-not (Test-Credentials)) { return }
    Invoke-Action 'Building headers...' {
        Invoke-Core @{ UserId = $txtUserId.Text; UserHash = $txtUserKey.Text }
    }
})

[void] $form.ShowDialog()
$form.Dispose()
