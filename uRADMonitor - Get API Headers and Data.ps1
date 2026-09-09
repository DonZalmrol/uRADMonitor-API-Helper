<#
.SYNOPSIS
    Builds the uRADMonitor REST API authentication headers (X-User-id / X-User-hash) and, optionally,
    queries the API with them.

.DESCRIPTION
    The uRADMonitor REST API authenticates every request with two custom HTTP headers:
        X-User-id   : your uRADMonitor account user id (numeric)
        X-User-hash : your Dashboard User Key

    This script constructs those headers and returns them, so you can inspect the exact values or reuse
    them elsewhere. When -Path is supplied it also calls the API and returns the parsed response.

    Credential handling:
    - For authenticated calls set -UserId to your account User ID and -UserHash to your account
      User Key (both shown on the uRADMonitor Dashboard -> API tab). The User Key IS the value the
      API expects for X-User-hash; this is the reliable method for reading data and registering
      devices.

    Common API paths (relative to https://data.uradmonitor.com/api/v1/):
        devices                         -> list devices visible to the account
        devices/<deviceId>              -> latest reading for a device
        devices/<deviceId>/all/<span>   -> historical data (span e.g. 3600 for the last hour)

    Creating a device:
    - Use -CreateDevice to register a new sensor via DIDAP (Dynamic ID Allocation Protocol). The
      script POSTs to /api/v1/upload/exp/01/<epoch>/<measurement> with the placeholder X-Device-id
      (-DeviceId, default 13000000); the server allocates and returns a unique Device ID (setid,
      format 13xxxxxx). EXP values travel as URL path segments (ID/value), like the device firmware
      sends them. Field 01 (local time) is mandatory and at least one real measurement must be
      present (see -InitialValues).
        - This requires Dashboard API credentials (your User ID and User Key).
    - Store the returned Device ID - all future data uploads for this sensor must use it.
    - The registration upload also carries a set of zeroed sensor values (-InitialValues) and the
      result includes a DeviceUrl to view the device on the map. The values travel with the
      registration on purpose: a second upload immediately afterwards is refused with
      "Too many reports".

.PARAMETER UserId
    uRADMonitor account user id from the Dashboard API tab. Required for command-line API actions.

.PARAMETER UserHash
    X-User-hash value. Use your User Key from the Dashboard API tab. Required for command-line API actions.

.PARAMETER Path
    API path relative to the base URI (e.g. 'devices'). When omitted the script only returns the headers.

.PARAMETER BaseUri
    API base URI. Defaults to https://data.uradmonitor.com/api/v1.

.PARAMETER TimeoutSeconds
    Maximum seconds to wait for each API request. Defaults to 30. GET requests retry transient failures
    up to two times; uploads and device registration are never retried automatically.

.PARAMETER ShowHeaders
    Also write the resolved headers to the log/host (the hash is masked).

.PARAMETER Gui
    Opens the Windows Forms interface. The GUI is also opened when the script is run without parameters.

.PARAMETER CreateDevice
    Register a new device via DIDAP and return the server-assigned Device ID. Requires
    authenticated credentials.

.PARAMETER DeviceId
    Placeholder X-Device-id sent with a -CreateDevice registration request. Defaults to 13000000,
    which signals the server to allocate a new ID. Values such as FFFFFFFF or 00000000 are rejected
    with "Invalid Device ID".

.PARAMETER InitialValues
    EXP fields sent with the registration upload as 'ID/value' pairs, so the new device starts with
    initialised readings. Defaults to temperature, pressure, humidity, CO2, PM2.5 and radiation all
    set to 0. At least one measurement is required: a timestamp-only payload is rejected with
    "EXP payload has no valid measurement". Examples: '02/21.5' temperature, '0B/12' radiation CPM.

.EXAMPLE
    .\uRADMonitor - Get API Headers and Data.ps1 -UserId 12345 -UserHash '<userKey>' -ShowHeaders
    Shows the authenticated API headers without calling the API.

.EXAMPLE
    .\uRADMonitor - Get API Headers and Data.ps1 -UserId 12345 -UserHash '<userKey>' -Path 'devices'
    Builds authenticated headers and lists the account's devices.

.EXAMPLE
    .\uRADMonitor - Get API Headers and Data.ps1 -UserId 12345 -UserHash <userKey> -CreateDevice
    Registers a new sensor and returns its assigned Device ID (13xxxxxx).

.NOTES
    Author      : DonZalmrol
    Script ID   : URADMONITOR_GET_API_HEADERS
    Created     : 2026

    Version History:
    1.0.0 - Initial version: build X-User-id / X-User-hash headers and optionally query the API
    1.1.0 - Added -CreateDevice: register a new sensor via DIDAP (POST /api/v1/upload/exp/ with a
            placeholder X-Device-id) and return the server-assigned Device ID (setid)
    1.1.1 - Registration now sends the mandatory EXP local-time field (01) in the POST body; without
            it the server responds "EXP payload missing timelocal" and returns no Device ID
    1.1.2 - Send the registration payload as raw text/plain (not form-urlencoded) so the server's EXP
            parser actually reads the timelocal field from the request body
    1.1.3 - Trigger DIDAP with an invalid Device ID (default FFFFFFFF) instead of the valid open-data
            ID 13000000; a 13xxxxxx ID is treated as a data upload and rejected with "EXP payload
            missing timelocal"
    1.1.4 - Reverted to Device ID 13000000 (FFFFFFFF/00000000 return "Invalid Device ID") and now
            send the EXP payload as URL path segments (/upload/exp/01/<epoch>) like the firmware,
            which the server parses instead of a request body
    1.1.5 - Registration payload now includes a measurement field (-RegistrationMeasurement, default
            02/0); a timestamp-only payload is rejected with "EXP payload has no valid measurement"
    1.2.0 - After registration the new device is seeded with zeroed sensor values (-SeedFields /
            -NoSeed) and the result now includes a DeviceUrl to view the device on the map
    1.2.1 - Added -UseBasicParsing to the upload request (avoids the IE-engine script execution
            prompt that could interrupt the seed upload) and report the seed upload outcome
        1.3.0 - Zeroed sensor values are now sent with the registration upload itself (-InitialValues,
            replaces -RegistrationMeasurement/-SeedFields/-NoSeed); the previous second upload was
            rejected by the server with "Too many reports"
        1.3.1 - Clarified uRADMonitor Shield validation behavior
        1.3.2 - Added dashboard visibility guidance after successful device registration
    1.3.3 - Added manual dummy data uploads (-SendDummyData)
        1.3.4 - Removed automatic post-registration activation uploads
    1.4.0 - Combined the GUI and API helper into one script; added improved error messages and GUI actions
    1.4.1 - Added DIDAP input validation, firmware handoff, GUI startup guide, and footer hyperlinks
    1.4.2 - Removed the unsupported public credential fallback
    1.4.3 - Documented the default initial EXP values in the GUI startup guide
    1.4.4 - Added input validation, request timeouts, and transient GET retries
    1.4.5 - Kept the GUI responsive while API requests are in progress
#>

[CmdletBinding()]
param()

function Test-uRADMonitorInitialValues {
    param([Parameter(Mandatory)] [string] $Values)

    $segments = $Values.Trim('/').Split('/')
    $supportedSensorIds = @('02', '03', '04', '05', '06', '07', '08', '09', '0A', '0B', '0C', '0D', '0E', '0F', '10', '11', '12', '13', '14')
    if ($segments.Count -lt 2 -or $segments.Count % 2 -ne 0) {
        throw "Initial values must contain one or more EXP ID/value pairs, for example '02/21.5/04/55'."
    }

    for ($index = 0; $index -lt $segments.Count; $index += 2) {
        $sensorId = $segments[$index].ToUpperInvariant()
        [double]$value = 0
        if ($sensorId -notin $supportedSensorIds) {
            throw "Unsupported EXP sensor ID '$sensorId'. Use an ID from 02 through 14, excluding 01 which is added automatically."
        }
        if (-not [double]::TryParse($segments[$index + 1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or [double]::IsNaN($value) -or [double]::IsInfinity($value)) {
            throw "EXP value for sensor ID '$sensorId' must be a finite number using a decimal point."
        }
    }
}

function Test-uRADMonitorDeviceId {
    param(
        [Parameter(Mandatory)] [string] $Value,
        [switch] $Registration
    )

    if ($Registration) {
        if ($Value -ne '13000000') { throw 'DIDAP registration requires the 13000000 placeholder Device ID.' }
        return
    }
    if ($Value -notmatch '^13[0-9A-Fa-f]{6}$') {
        throw 'Device ID must be an eight-character hexadecimal value beginning with 13.'
    }
}

function Test-uRADMonitorTransientError {
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) { return $true }
    $statusCode = [int]$response.StatusCode
    return $statusCode -eq 408 -or $statusCode -eq 429 -or $statusCode -ge 500
}

function Invoke-uRADMonitorGetRequest {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [hashtable] $Headers,
        [int] $TimeoutSeconds = 30
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        }
        catch {
            if ($attempt -eq 3 -or -not (Test-uRADMonitorTransientError -ErrorRecord $_)) { throw }
            Start-Sleep -Seconds $attempt
        }
    }
}

# Sends an EXP payload for a device. EXP values travel as URL path segments (ID/value) exactly like
# the device firmware sends them; field 01 (local time) is always prepended here.
function Send-uRADMonitorExp {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $BaseUri,
        [Parameter(Mandatory)] [string]    $DeviceId,
        [string] $Fields,
        [int] $TimeoutSeconds = 30
    )

    $expHeaders = @{} + $Headers
    $expHeaders['X-Device-id'] = $DeviceId

    $payload = '01/{0}' -f [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (-not [string]::IsNullOrWhiteSpace($Fields)) {
        $payload = '{0}/{1}' -f $payload, $Fields.Trim('/')
    }
    $uri = "{0}/upload/exp/{1}" -f $BaseUri.TrimEnd('/'), $payload

    return (Invoke-WebRequest -Uri $uri -Headers $expHeaders -Method Post -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop).Content
}

# Sends a single dummy value to keep the device active after registration. The SHIELD layer is rate
# sensitive, so this intentionally uses a single EXP upload with a small value ramp and no burst.
function Send-uRADMonitorDummyData {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $BaseUri,
        [Parameter(Mandatory)] [string]    $DeviceId,
        [int] $Value = 0,
        [int] $TimeoutSeconds = 30
    )

    $expHeaders = @{} + $Headers
    $expHeaders['X-Device-id'] = $DeviceId
    $payload = '01/{0}/02/{1}' -f [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), $Value
    $uri = '{0}/upload/exp/{1}' -f $BaseUri.TrimEnd('/'), $payload

    return (Invoke-WebRequest -Uri $uri -Headers $expHeaders -Method Post -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop).Content
}

# Registers a new device via DIDAP by POSTing to the upload endpoint with a placeholder Device ID;
# the server allocates a real id and returns it as { "setid": "13xxxxxx" }.
function New-uRADMonitorDevice {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $BaseUri,
        [string] $RegistrationId = '13000000',
        [string] $InitialValues  = '02/0/03/0/04/0/07/0/09/0/0B/0',
        [int] $TimeoutSeconds = 30
    )

    Test-uRADMonitorDeviceId -Value $RegistrationId -Registration
    Test-uRADMonitorInitialValues -Values $InitialValues

    # The initial values ride along with the registration: the server rejects a timestamp-only
    # payload, and a second upload straight after would be refused with "Too many reports".
    $content = Send-uRADMonitorExp -Headers $Headers -BaseUri $BaseUri -DeviceId $RegistrationId -Fields $InitialValues -TimeoutSeconds $TimeoutSeconds

    $match       = [regex]::Match($content, '"setid"\s*:\s*"?([0-9A-Fa-f]{6,8})"?')
    $newDeviceId = if ($match.Success) { $match.Groups[1].Value.ToUpper() } else { $null }

    return [pscustomobject]@{
        NewDeviceId      = $newDeviceId
        DeviceUrl        = if ($newDeviceId) { "https://www.uradmonitor.com/tools/dashboard-09/?open=$newDeviceId" } else { $null }
        InitialValues     = $InitialValues
        DashboardNotice  = 'The device may take some time to appear in your dashboard. If it does not appear after waiting, contact uRADMonitor support to have it added to your dashboard.'
        RawResponse       = $content
    }
}

function Get-uRADMonitorErrorDetail {
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)

    $message = $ErrorRecord.Exception.Message
    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) { return $message }

    try {
        $status = '{0} {1}' -f [int]$response.StatusCode, $response.StatusDescription
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream())
        try { $body = $reader.ReadToEnd().Trim() }
        finally { $reader.Dispose() }
        if ($body) { return "$message`r`nHTTP $status`r`n$body" }
        return "$message`r`nHTTP $status"
    }
    catch {
        return $message
    }
}

function Show-uRADMonitorGui {
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Gui')
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $scriptVersion = '1.4.5'
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "uRADMonitor API Helper v$scriptVersion"
    $form.Size = New-Object System.Drawing.Size(560, 710)
    $form.MinimumSize = New-Object System.Drawing.Size(560, 710)
    $form.StartPosition = 'CenterScreen'

    $iconPath = Join-Path $PSScriptRoot 'uradmonitor-logo-2026.ico'
    if (Test-Path -LiteralPath $iconPath) {
        try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch { }
    }

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 60
    $form.Controls.Add($header)

    $logoPath = Join-Path $PSScriptRoot 'uradmonitor-logo-2026.png'
    if (Test-Path -LiteralPath $logoPath) {
        $logo = New-Object System.Windows.Forms.PictureBox
        $logo.Location = New-Object System.Drawing.Point(12, 6)
        $logo.Size = New-Object System.Drawing.Size(48, 48)
        $logo.SizeMode = 'Zoom'
        try { $logo.Image = [System.Drawing.Image]::FromFile($logoPath) } catch { }
        $header.Controls.Add($logo)
    }

    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'uRADMonitor API Helper'
    $title.Location = New-Object System.Drawing.Point(70, 18)
    $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
    $header.Controls.Add($title)

    $btnDashboard = New-Object System.Windows.Forms.Button
    $btnDashboard.Text = 'Dashboard Online'
    $btnDashboard.Location = New-Object System.Drawing.Point(395, 15)
    $btnDashboard.Size = New-Object System.Drawing.Size(130, 30)
    $btnDashboard.Anchor = 'Top,Right'
    $btnDashboard.Add_Click({ Start-Process -FilePath 'https://www.uradmonitor.com/dashboard/' })
    $header.Controls.Add($btnDashboard)

    function Add-GuiLabel([string] $Text, [int] $X, [int] $Y) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text; $label.Location = New-Object System.Drawing.Point($X, $Y); $label.AutoSize = $true
        $form.Controls.Add($label)
    }

    Add-GuiLabel 'User ID:' 15 78
    $txtUserId = New-Object System.Windows.Forms.TextBox
    $txtUserId.Location = New-Object System.Drawing.Point(120, 75); $txtUserId.Size = New-Object System.Drawing.Size(180, 23)
    $form.Controls.Add($txtUserId)

    Add-GuiLabel 'User Key:' 15 110
    $txtUserKey = New-Object System.Windows.Forms.TextBox
    $txtUserKey.Location = New-Object System.Drawing.Point(120, 107); $txtUserKey.Size = New-Object System.Drawing.Size(300, 23)
    $txtUserKey.Anchor = 'Top,Left,Right'; $txtUserKey.UseSystemPasswordChar = $true
    $form.Controls.Add($txtUserKey)

    $chkShowKey = New-Object System.Windows.Forms.CheckBox
    $chkShowKey.Text = 'Show'; $chkShowKey.Location = New-Object System.Drawing.Point(430, 109); $chkShowKey.AutoSize = $true
    $chkShowKey.Anchor = 'Top,Right'
    $chkShowKey.Add_CheckedChanged({ $txtUserKey.UseSystemPasswordChar = -not $chkShowKey.Checked })
    $form.Controls.Add($chkShowKey)

    Add-GuiLabel 'Path:' 15 142
    $cmbPath = New-Object System.Windows.Forms.ComboBox
    $cmbPath.Location = New-Object System.Drawing.Point(120, 139); $cmbPath.Size = New-Object System.Drawing.Size(405, 23)
    $cmbPath.Anchor = 'Top,Left,Right'; $cmbPath.DropDownStyle = 'DropDown'
    [void]$cmbPath.Items.AddRange(@('devices', 'devices/{id}', 'devices/{id}/all/3600', 'devices/{id}/all/86400', 'devices/{id}/all/604800'))
    $cmbPath.Text = 'devices'; $form.Controls.Add($cmbPath)

    Add-GuiLabel 'Device ID:' 15 174
    $cmbDevice = New-Object System.Windows.Forms.ComboBox
    $cmbDevice.Location = New-Object System.Drawing.Point(120, 171); $cmbDevice.Size = New-Object System.Drawing.Size(200, 23)
    $cmbDevice.DropDownStyle = 'DropDown'; $form.Controls.Add($cmbDevice)

    $setupBox = New-Object System.Windows.Forms.GroupBox
    $setupBox.Text = 'New Device Setup'
    $setupBox.Location = New-Object System.Drawing.Point(15, 202); $setupBox.Size = New-Object System.Drawing.Size(510, 92)
    $setupBox.Anchor = 'Top,Left,Right'; $form.Controls.Add($setupBox)

    $lblRegistrationId = New-Object System.Windows.Forms.Label
    $lblRegistrationId.Text = 'DIDAP ID:'; $lblRegistrationId.Location = New-Object System.Drawing.Point(10, 24); $lblRegistrationId.AutoSize = $true
    $setupBox.Controls.Add($lblRegistrationId)
    $lblRegistrationValue = New-Object System.Windows.Forms.Label
    $lblRegistrationValue.Text = '13000000'; $lblRegistrationValue.Location = New-Object System.Drawing.Point(78, 24); $lblRegistrationValue.AutoSize = $true
    $setupBox.Controls.Add($lblRegistrationValue)

    $lblInitialValues = New-Object System.Windows.Forms.Label
    $lblInitialValues.Text = 'Initial EXP:'; $lblInitialValues.Location = New-Object System.Drawing.Point(10, 57); $lblInitialValues.AutoSize = $true
    $setupBox.Controls.Add($lblInitialValues)
    $txtInitialValues = New-Object System.Windows.Forms.TextBox
    $txtInitialValues.Text = '02/0/03/0/04/0/07/0/09/0/0B/0'
    $txtInitialValues.Location = New-Object System.Drawing.Point(78, 54); $txtInitialValues.Size = New-Object System.Drawing.Size(422, 23)
    $txtInitialValues.Anchor = 'Top,Left,Right'; $setupBox.Controls.Add($txtInitialValues)

    $buttons = @(
        @{ Text = 'Refresh'; X = 15; Width = 95 }, @{ Text = 'Get Data'; X = 117; Width = 95 },
        @{ Text = 'Create'; X = 219; Width = 95 }, @{ Text = 'Headers'; X = 321; Width = 95 },
        @{ Text = 'Clear'; X = 423; Width = 102 }
    )
    $guiButtons = @{}
    foreach ($button in $buttons) {
        $control = New-Object System.Windows.Forms.Button
        $control.Text = $button.Text; $control.Location = New-Object System.Drawing.Point($button.X, 301)
        $control.Size = New-Object System.Drawing.Size($button.Width, 30)
        $form.Controls.Add($control); $guiButtons[$button.Text] = $control
    }

    $txtOutput = New-Object System.Windows.Forms.TextBox
    $txtOutput.Location = New-Object System.Drawing.Point(15, 343); $txtOutput.Size = New-Object System.Drawing.Size(510, 285)
    $txtOutput.Multiline = $true; $txtOutput.ScrollBars = 'Both'; $txtOutput.ReadOnly = $true; $txtOutput.WordWrap = $false
    $txtOutput.Font = New-Object System.Drawing.Font('Consolas', 9); $txtOutput.Anchor = 'Top,Bottom,Left,Right'
    $form.Controls.Add($txtOutput)
    $introductionText = @'
Enter your User ID and User Key from the Dashboard API tab.

Refresh    Loads device IDs associated with your account.
Get Data   Retrieves the selected API path; {id} uses the selected Device ID.
Create     Registers a new DIDAP device and copies its assigned ID to the clipboard.
Headers    Displays the resolved API headers with the User Key masked.
Clear      Clears this log.

Initial EXP: 02/0 = temperature, 03/0 = pressure, 04/0 = humidity,
             07/0 = CO2, 09/0 = PM2.5, 0B/0 = radiation.
             These values are recorded as the device's first readings.

Dashboard Online opens uRADMonitor in your default browser.
'@.Trim()
    $txtOutput.Text = $introductionText

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15, 635); $lblStatus.Size = New-Object System.Drawing.Size(510, 20)
    $lblStatus.Anchor = 'Bottom,Left,Right'; $form.Controls.Add($lblStatus)

    $footer = New-Object System.Windows.Forms.LinkLabel
    $footer.Text = "Version $scriptVersion - Copyright 2026 Don Zalmrol - GitHub"
    $footer.Location = New-Object System.Drawing.Point(15, 653); $footer.Size = New-Object System.Drawing.Size(510, 18)
    $footer.TextAlign = 'MiddleCenter'; $footer.Anchor = 'Bottom,Left,Right'
    $footer.Font = New-Object System.Drawing.Font('Segoe UI', 8); $form.Controls.Add($footer)
    $footer.LinkColor = [System.Drawing.Color]::FromArgb(26, 92, 165)
    $footer.ActiveLinkColor = [System.Drawing.Color]::FromArgb(18, 68, 120)
    $footer.VisitedLinkColor = [System.Drawing.Color]::FromArgb(26, 92, 165)
    $footer.LinkBehavior = [System.Windows.Forms.LinkBehavior]::AlwaysUnderline
    $footer.Links.Add($footer.Text.IndexOf('Don Zalmrol'), 'Don Zalmrol'.Length, 'https://www.don-zalmrol.be') | Out-Null
    $footer.Links.Add($footer.Text.IndexOf('GitHub'), 'GitHub'.Length, 'https://github.com/DonZalmrol') | Out-Null
    $footer.Add_LinkClicked({
        param($linkSender, $linkEventArgs)
        $linkUrl = [string]$linkEventArgs.Link.LinkData
        if (-not [string]::IsNullOrWhiteSpace($linkUrl)) { Start-Process -FilePath $linkUrl }
    })

    $scriptPath = $PSCommandPath
    function Invoke-GuiScript {
        param([Parameter(Mandatory)] [hashtable] $Parameters)

        foreach ($button in $guiButtons.Values) { $button.Enabled = $false }
        $job = Start-Job -ScriptBlock {
            param($ChildScriptPath, $ChildParameters)
            & $ChildScriptPath @ChildParameters 2>&1
        } -ArgumentList $scriptPath, $Parameters
        try {
            while ($job.State -in @('NotStarted', 'Running')) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 50
            }
            return @(Receive-Job -Job $job -ErrorAction SilentlyContinue)
        }
        finally {
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
            foreach ($button in $guiButtons.Values) { $button.Enabled = $true }
        }
    }

    function Invoke-GuiRequest([hashtable] $Parameters) {
        $items = @(Invoke-GuiScript -Parameters $Parameters)
        $errorItem = @($items | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Select-Object -First 1)
        if ($errorItem.Count -gt 0) { return "ERROR: $(Get-uRADMonitorErrorDetail -ErrorRecord $errorItem[0])" }
        if ($items.Count -eq 0) { return '(no output)' }
        try { return ($items | ConvertTo-Json -Depth 8) } catch { return ($items | Out-String) }
    }

    function Test-GuiCredentials {
        if ([string]::IsNullOrWhiteSpace($txtUserId.Text) -or [string]::IsNullOrWhiteSpace($txtUserKey.Text)) {
            $txtOutput.Text = 'Please enter both a User ID and a User Key.'; return $false
        }
        if ($txtUserId.Text.Trim() -notmatch '^\d+$') {
            $txtOutput.Text = 'User ID must contain digits only.'; return $false
        }
        return $true
    }

    function Invoke-GuiAction([string] $Status, [scriptblock] $Action) {
        $lblStatus.Text = $Status; $form.Cursor = 'WaitCursor'; $form.Refresh()
        try { $txtOutput.Text = & $Action } finally { $form.Cursor = 'Default'; $lblStatus.Text = 'Done.' }
    }

    foreach ($guiButton in $guiButtons.Values) {
        $guiButton.Add_Click({
            if ($txtOutput.Text -eq $introductionText) { $txtOutput.Clear() }
        })
    }

    $guiButtons['Get Data'].Add_Click({
        if (-not (Test-GuiCredentials)) { return }
        $path = $cmbPath.Text -replace '\{id\}', $cmbDevice.Text.Trim()
        if ($path -match '\{id\}' -or [string]::IsNullOrWhiteSpace($path)) { $txtOutput.Text = 'Select or enter a Device ID for this path.'; return }
        if ($cmbPath.Text -match '\{id\}') {
            try { Test-uRADMonitorDeviceId -Value $cmbDevice.Text.Trim() } catch { $txtOutput.Text = "ERROR: $($_.Exception.Message)"; return }
        }
        Invoke-GuiAction 'Querying API...' { Invoke-GuiRequest @{ UserId = $txtUserId.Text; UserHash = $txtUserKey.Text; Path = $path } }
    })
    $guiButtons['Refresh'].Add_Click({
        if (-not (Test-GuiCredentials)) { return }
        $lblStatus.Text = 'Loading devices...'; $form.Cursor = 'WaitCursor'; $form.Refresh()
        try {
            $devices = @(Invoke-GuiScript -Parameters @{ UserId = $txtUserId.Text; UserHash = $txtUserKey.Text; Path = 'devices' })
            $errorItem = @($devices | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Select-Object -First 1)
            if ($errorItem.Count -gt 0) { $txtOutput.Text = "ERROR: $(Get-uRADMonitorErrorDetail -ErrorRecord $errorItem[0])"; return }
            $ids = @($devices | Where-Object { $_.PSObject.Properties.Name -contains 'id' } | ForEach-Object { [string]$_.id })
            $cmbDevice.Items.Clear()
            if ($ids.Count -gt 0) { [void]$cmbDevice.Items.AddRange($ids); $cmbDevice.SelectedIndex = 0; $txtOutput.Text = "Loaded $($ids.Count) device id(s)." }
            else { $txtOutput.Text = 'No device IDs found.' }
        } finally { $form.Cursor = 'Default'; $lblStatus.Text = 'Done.' }
    })
    $guiButtons['Create'].Add_Click({
        if (-not (Test-GuiCredentials)) { return }
        if ([System.Windows.Forms.MessageBox]::Show('Register a new device on your uRADMonitor account?', 'Create Device', 'YesNo', 'Question') -ne 'Yes') { return }
        $lblStatus.Text = 'Registering device...'; $form.Cursor = 'WaitCursor'; $form.Refresh()
        try {
            try {
                Test-uRADMonitorInitialValues -Values $txtInitialValues.Text
            } catch { $txtOutput.Text = "ERROR: $($_.Exception.Message)"; return }
            $result = @(Invoke-GuiScript -Parameters @{ UserId = $txtUserId.Text; UserHash = $txtUserKey.Text; CreateDevice = $true; DeviceId = '13000000'; InitialValues = $txtInitialValues.Text })
            $errorItem = @($result | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | Select-Object -First 1)
            if ($errorItem.Count -gt 0) { $txtOutput.Text = "ERROR: $(Get-uRADMonitorErrorDetail -ErrorRecord $errorItem[0])"; return }
            $device = $result | Where-Object { $_.PSObject.Properties.Name -contains 'NewDeviceId' } | Select-Object -Last 1
            if ($device -and $device.NewDeviceId) {
                if (-not $cmbDevice.Items.Contains($device.NewDeviceId)) { [void]$cmbDevice.Items.Add($device.NewDeviceId) }
                $cmbDevice.SelectedItem = $device.NewDeviceId
                [System.Windows.Forms.Clipboard]::SetText($device.NewDeviceId)
                $handoff = "Device ID copied to the clipboard: $($device.NewDeviceId)`r`n`r`nFirmware handoff:`r`n#define URADMONITOR_DEVICE_ID 0x$($device.NewDeviceId)`r`n`r`nStore this ID in non-volatile memory and use it in X-Device-id for every future upload. Configure location and installation details in the uRADMonitor Dashboard."
                $txtOutput.Text = "$handoff`r`n`r`n$($result | ConvertTo-Json -Depth 8)"
                return
            }
            $txtOutput.Text = $result | ConvertTo-Json -Depth 8
        } finally { $form.Cursor = 'Default'; $lblStatus.Text = 'Done.' }
    })
    $guiButtons['Headers'].Add_Click({ if (Test-GuiCredentials) { Invoke-GuiAction 'Building headers...' { Invoke-GuiRequest @{ UserId = $txtUserId.Text; UserHash = $txtUserKey.Text; ShowHeaders = $true } } } })
    $guiButtons['Clear'].Add_Click({ $txtOutput.Clear(); $lblStatus.Text = '' })

    [void]$form.ShowDialog()
    $form.Dispose()
}

# GUI-first behavior: the desktop interface is the intended user experience.
Show-uRADMonitorGui
return

# Resolve the X- authentication headers
# -----------------------------
if ([string]::IsNullOrWhiteSpace($UserId) -or [string]::IsNullOrWhiteSpace($UserHash)) {
    Write-Error 'A User ID and User Key are required. Find both values in the uRADMonitor Dashboard API tab.'
    return
}
if ($UserId.Trim() -notmatch '^\d+$') {
    Write-Error 'User ID must contain digits only.'
    return
}

$headers = @{
    'X-User-id'   = $UserId
    'X-User-hash' = $UserHash
}

if ($ShowHeaders) {
    $masked = $UserHash.Substring(0, [Math]::Min(6, $UserHash.Length)) + '...'
    Write-Host "X-User-id   : $UserId"
    Write-Host "X-User-hash : $masked"
}

# -----------------------------
# Send a single dummy data upload for the chosen device
# -----------------------------
if ($SendDummyData) {
    if ([string]::IsNullOrWhiteSpace($DeviceId)) {
        Write-Error "A Device ID is required for dummy data uploads."
        return
    }

    try {
        Test-uRADMonitorDeviceId -Value $DeviceId
        $response = Send-uRADMonitorDummyData -Headers $headers -BaseUri $BaseUri -DeviceId $DeviceId -Value $DummyDataValue -TimeoutSeconds $TimeoutSeconds
        $result = [pscustomobject]@{
            DeviceId     = $DeviceId
            DummyValue  = $DummyDataValue
            RawResponse = $response
        }
        Write-Host "Dummy sync sent for device $DeviceId with value $DummyDataValue"
        return $result
    }
    catch {
        Write-Error "uRADMonitor dummy upload failed: $(Get-uRADMonitorErrorDetail -ErrorRecord $_)"
        return
    }
}

# -----------------------------
# Optionally create (register) a new device via DIDAP
# -----------------------------
if ($CreateDevice) {
    try {
        $result = New-uRADMonitorDevice -Headers $headers -BaseUri $BaseUri -RegistrationId $DeviceId -InitialValues $InitialValues -TimeoutSeconds $TimeoutSeconds

        if ($result.NewDeviceId) {
            Write-Host "New device registered. Device ID: $($result.NewDeviceId)"
            Write-Host "Initial values sent: $($result.InitialValues)"
            Write-Host "View it here: $($result.DeviceUrl)"
            Write-Host "Dashboard: $($result.DashboardNotice)"
        }
        else {
            Write-Warning "Registration request sent but no Device ID was returned. Server response: $($result.RawResponse)"
        }
        return $result
    }
    catch {
        Write-Error "uRADMonitor device registration failed: $(Get-uRADMonitorErrorDetail -ErrorRecord $_)"
        return
    }
}

# -----------------------------
# Optionally query the API
# -----------------------------
if ($Path) {
    $uri = "{0}/{1}" -f $BaseUri.TrimEnd('/'), $Path.TrimStart('/')
    try {
        $response = Invoke-uRADMonitorGetRequest -Uri $uri -Headers $headers -TimeoutSeconds $TimeoutSeconds
        return $response
    }
    catch {
        Write-Error "uRADMonitor API request to '$uri' failed: $(Get-uRADMonitorErrorDetail -ErrorRecord $_)"
        return
    }
}

# When no path is requested, hand back the headers for reuse.
return $headers
