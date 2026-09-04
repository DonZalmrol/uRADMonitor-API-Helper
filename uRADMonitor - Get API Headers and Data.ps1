<#
.SYNOPSIS
    Builds the uRADMonitor REST API authentication headers (X-User-id / X-User-hash) and, optionally,
    queries the API with them.

.DESCRIPTION
    The uRADMonitor REST API authenticates every request with two custom HTTP headers:
        X-User-id   : your uRADMonitor account user id (numeric), or 'www' for public read-only access
        X-User-hash : the lowercase MD5 hash of your account password, or 'global' for public access

    This script constructs those headers and returns them, so you can inspect the exact values or reuse
    them elsewhere. When -Path is supplied it also calls the API and returns the parsed response.

    Credential handling:
    - For authenticated calls set -UserId to your account User ID and -UserHash to your account
      User Key (both shown on the uRADMonitor Dashboard -> API tab). The User Key IS the value the
      API expects for X-User-hash; this is the reliable method for reading data and registering
      devices.
    - -Password is a convenience that computes MD5(password) for X-User-hash. It only works if your
      account's User Key equals the MD5 of your password; otherwise authentication fails, so prefer
      -UserHash with the Dashboard User Key.
        - With no credentials the script falls back to the public guest identity (www / global). Public API
            calls may require server-side validation under the uRADMonitor Shield; use dashboard credentials
            for reliable API access.

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
    - This requires authenticated credentials (the X-User-hash is your account User Key); the
      public guest identity cannot register devices.
    - Store the returned Device ID - all future data uploads for this sensor must use it.
    - The registration upload also carries a set of zeroed sensor values (-InitialValues) and the
      result includes a DeviceUrl to view the device on the map. The values travel with the
      registration on purpose: a second upload immediately afterwards is refused with
      "Too many reports".

.PARAMETER UserId
    uRADMonitor account user id. Defaults to 'www' (public read-only guest).

.PARAMETER Password
    Convenience alternative to -UserHash that derives X-User-hash as MD5(password). Accepts a plain
    string, a SecureString, or a PSCredential. Only works if your account User Key equals the MD5 of
    your password; otherwise use -UserHash. Ignored when -UserHash is supplied.

.PARAMETER UserHash
    Pre-computed X-User-hash value. Use this to skip password hashing. Defaults to 'global' when no
    credentials are provided.

.PARAMETER Path
    API path relative to the base URI (e.g. 'devices'). When omitted the script only returns the headers.

.PARAMETER BaseUri
    API base URI. Defaults to https://data.uradmonitor.com/api/v1.

.PARAMETER ShowHeaders
    Also write the resolved headers to the log/host (the hash is masked).

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
    .\uRADMonitor - Get API Headers and Data.ps1 -ShowHeaders
    Shows the public guest headers without calling the API.

.EXAMPLE
    .\uRADMonitor - Get API Headers and Data.ps1 -UserId 12345 -Password (Read-Host -AsSecureString) -Path 'devices'
    Builds authenticated headers and lists the account's devices.

.EXAMPLE
    .\uRADMonitor - Get API Headers and Data.ps1 -UserId 12345 -UserHash <userKey> -CreateDevice
    Registers a new sensor and returns its assigned Device ID (13xxxxxx).

.NOTES
    Author      : DonZalmrol
    Script ID   : URADMONITOR_GET_API_HEADERS
    Created     : 2026

    Version History:
    1.0.0 - Initial version: build X-User-id / X-User-hash headers (password -> MD5), public guest
            fallback, optional API call via Invoke-RestMethod
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
        1.3.1 - Clarified that public www/global API calls may require uRADMonitor Shield validation
        1.3.2 - Added dashboard visibility guidance after successful device registration
        1.3.3 - Added controlled activation dummy uploads (-ActivationSyncs, -ActivationIntervalSeconds,
            -SendDummyData) to seed a newly created device with a 5-minute ramp while respecting
            uRADMonitor SHIELD rate limits and avoiding DIDAP/IP flagging
#>

[CmdletBinding()]
param(
    [string] $UserId = 'www',

    [object] $Password,

    [string] $UserHash,

    [string] $Path,

    [string] $BaseUri = 'https://data.uradmonitor.com/api/v1',

    [switch] $ShowHeaders,

    [switch] $SendDummyData,

    [int] $DummyDataValue = 0,

    [int] $ActivationSyncs = 5,

    [int] $ActivationIntervalSeconds = 60,

    [switch] $CreateDevice,

    [string] $DeviceId = '13000000',

    [string] $InitialValues = '02/0/03/0/04/0/07/0/09/0/0B/0'
)

# Converts a password (String / SecureString / PSCredential) to its lowercase MD5 hex hash.
function Get-PasswordHash {
    param([Parameter(Mandatory)] [object] $Password)

    if ($Password -is [System.Management.Automation.PSCredential]) {
        $plain = $Password.GetNetworkCredential().Password
    }
    elseif ($Password -is [System.Security.SecureString]) {
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        try   { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    else {
        $plain = [string]$Password
    }

    $md5   = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($plain))
    }
    finally {
        $md5.Dispose()
    }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

# Sends an EXP payload for a device. EXP values travel as URL path segments (ID/value) exactly like
# the device firmware sends them; field 01 (local time) is always prepended here.
function Send-uRADMonitorExp {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $BaseUri,
        [Parameter(Mandatory)] [string]    $DeviceId,
        [string] $Fields
    )

    $expHeaders = @{} + $Headers
    $expHeaders['X-Device-id'] = $DeviceId

    $payload = '01/{0}' -f [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if (-not [string]::IsNullOrWhiteSpace($Fields)) {
        $payload = '{0}/{1}' -f $payload, $Fields.Trim('/')
    }
    $uri = "{0}/upload/exp/{1}" -f $BaseUri.TrimEnd('/'), $payload

    return (Invoke-WebRequest -Uri $uri -Headers $expHeaders -Method Post -UseBasicParsing -ErrorAction Stop).Content
}

# Sends a single dummy value to keep the device active after registration. The SHIELD layer is rate
# sensitive, so this intentionally uses a single EXP upload with a small value ramp and no burst.
function Send-uRADMonitorDummyData {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $BaseUri,
        [Parameter(Mandatory)] [string]    $DeviceId,
        [int] $Value = 0
    )

    $expHeaders = @{} + $Headers
    $expHeaders['X-Device-id'] = $DeviceId
    $payload = '01/{0}/02/{1}' -f [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(), $Value
    $uri = '{0}/upload/exp/{1}' -f $BaseUri.TrimEnd('/'), $payload

    return (Invoke-WebRequest -Uri $uri -Headers $expHeaders -Method Post -UseBasicParsing -ErrorAction Stop).Content
}

# Sends a small 5-minute activation sequence with a gentle upward ramp (0..5) to make sure the
# newly created device is visible and accepted by the platform without triggering SHIELD rate limits.
function Invoke-uRADMonitorActivationSequence {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $BaseUri,
        [Parameter(Mandatory)] [string]    $DeviceId,
        [int] $SyncCount = 5,
        [int] $IntervalSeconds = 60
    )

    if ($SyncCount -le 0) {
        return @()
    }

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

    $result = @()
    for ($index = 0; $index -lt $values.Count; $index++) {
        $value = [int]$values[$index]
        $progress = [Math]::Round((($index + 1) / $values.Count) * 100)
        Write-Progress -Activity 'Activating new uRADMonitor device' -Status "Minute $($index + 1) of $($values.Count): sending dummy value $value" -PercentComplete $progress

        $response = Send-uRADMonitorDummyData -Headers $Headers -BaseUri $BaseUri -DeviceId $DeviceId -Value $value
        $result += [pscustomobject]@{
            Minute       = $index + 1
            Value        = $value
            Response     = $response
            SentAtUtc    = [DateTimeOffset]::UtcNow
        }

        if ($index -lt ($values.Count - 1) -and $IntervalSeconds -gt 0) {
            Start-Sleep -Seconds $IntervalSeconds
        }
    }

    return $result
}

# Registers a new device via DIDAP by POSTing to the upload endpoint with a placeholder Device ID;
# the server allocates a real id and returns it as { "setid": "13xxxxxx" }.
function New-uRADMonitorDevice {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $BaseUri,
        [string] $RegistrationId = '13000000',
        [string] $InitialValues  = '02/0/03/0/04/0/07/0/09/0/0B/0'
    )

    # The initial values ride along with the registration: the server rejects a timestamp-only
    # payload, and a second upload straight after would be refused with "Too many reports".
    $content = Send-uRADMonitorExp -Headers $Headers -BaseUri $BaseUri -DeviceId $RegistrationId -Fields $InitialValues

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

# -----------------------------
# Resolve the X- authentication headers
# -----------------------------
if (-not $UserHash) {
    if ($PSBoundParameters.ContainsKey('Password') -and $Password) {
        $UserHash = Get-PasswordHash -Password $Password
    }
    else {
        # No credentials supplied: fall back to the public read-only guest identity.
        $UserHash = 'global'
    }
}

$headers = @{
    'X-User-id'   = $UserId
    'X-User-hash' = $UserHash
}

if ($ShowHeaders) {
    $masked = if ($UserHash -eq 'global') { $UserHash } else { $UserHash.Substring(0, [Math]::Min(6, $UserHash.Length)) + '...' }
    Write-Host "X-User-id   : $UserId"
    Write-Host "X-User-hash : $masked"
}

# -----------------------------
# Send a single dummy data upload for the chosen device
# -----------------------------
if ($SendDummyData) {
    if ($UserId -eq 'www' -or $UserHash -eq 'global') {
        Write-Error "Sending dummy data requires authenticated credentials (-UserId with -Password or -UserHash); the public guest identity cannot write to the device endpoint."
        return
    }

    if ([string]::IsNullOrWhiteSpace($DeviceId)) {
        Write-Error "A Device ID is required for dummy data uploads."
        return
    }

    try {
        $response = Send-uRADMonitorDummyData -Headers $headers -BaseUri $BaseUri -DeviceId $DeviceId -Value $DummyDataValue
        $result = [pscustomobject]@{
            DeviceId     = $DeviceId
            DummyValue  = $DummyDataValue
            RawResponse = $response
        }
        Write-Host "Dummy sync sent for device $DeviceId with value $DummyDataValue"
        return $result
    }
    catch {
        Write-Error "uRADMonitor dummy upload failed: $($_.Exception.Message)"
        return
    }
}

# -----------------------------
# Optionally create (register) a new device via DIDAP
# -----------------------------
if ($CreateDevice) {
    if ($UserId -eq 'www' -or $UserHash -eq 'global') {
        Write-Error "Creating a device requires authenticated credentials (-UserId with -Password or -UserHash); the public guest identity cannot register devices."
        return
    }

    try {
        $result = New-uRADMonitorDevice -Headers $headers -BaseUri $BaseUri -RegistrationId $DeviceId -InitialValues $InitialValues

        if ($result.NewDeviceId) {
            Write-Host "New device registered. Device ID: $($result.NewDeviceId)"
            Write-Host "Initial values sent: $($result.InitialValues)"
            Write-Host "View it here: $($result.DeviceUrl)"
            Write-Host "Dashboard: $($result.DashboardNotice)"

            if ($ActivationSyncs -gt 0) {
                $activation = Invoke-uRADMonitorActivationSequence -Headers $headers -BaseUri $BaseUri -DeviceId $result.NewDeviceId -SyncCount $ActivationSyncs -IntervalSeconds $ActivationIntervalSeconds
                $result | Add-Member -NotePropertyName 'ActivationSyncs' -NotePropertyValue $ActivationSyncs
                $result | Add-Member -NotePropertyName 'ActivationIntervalSeconds' -NotePropertyValue $ActivationIntervalSeconds
                $result | Add-Member -NotePropertyName 'ActivationSamples' -NotePropertyValue $activation
                Write-Host "Activation sequence completed: $($activation.Count) dummy uploads sent over $ActivationSyncs minute(s)."
            }
        }
        else {
            Write-Warning "Registration request sent but no Device ID was returned. Server response: $($result.RawResponse)"
        }
        return $result
    }
    catch {
        Write-Error "uRADMonitor device registration failed: $($_.Exception.Message)"
        return
    }
}

# -----------------------------
# Optionally query the API
# -----------------------------
if ($Path) {
    $uri = "{0}/{1}" -f $BaseUri.TrimEnd('/'), $Path.TrimStart('/')
    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
        return $response
    }
    catch {
        Write-Error "uRADMonitor API request to '$uri' failed: $($_.Exception.Message)"
        return
    }
}

# When no path is requested, hand back the headers for reuse.
return $headers
