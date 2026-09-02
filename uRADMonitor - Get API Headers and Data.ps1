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
    - Provide -UserId together with either -Password (any of String / SecureString / PSCredential) or a
      pre-computed -UserHash. If a password is given, its MD5 hash is calculated for you.
    - With no credentials the script falls back to the public guest identity (www / global), which can
      read publicly shared device data only.

    Common API paths (relative to https://data.uradmonitor.com/api/v1/):
        devices                         -> list devices visible to the account
        devices/<deviceId>              -> latest reading for a device
        devices/<deviceId>/all/<span>   -> historical data (span e.g. 3600 for the last hour)

    Creating a device:
    - Use -CreateDevice to register a new sensor via DIDAP (Dynamic ID Allocation Protocol). The
      script POSTs to /api/v1/upload/exp/ with a placeholder X-Device-id (-DeviceId, default
      13000000); the server allocates and returns a unique Device ID (setid, format 13xxxxxx).
    - This requires authenticated credentials (the X-User-hash is your account User Key); the
      public guest identity cannot register devices.
    - Store the returned Device ID - all future data uploads for this sensor must use it.

.PARAMETER UserId
    uRADMonitor account user id. Defaults to 'www' (public read-only guest).

.PARAMETER Password
    Account password used to derive the X-User-hash. Accepts a plain string, a SecureString, or a
    PSCredential (its password is used). Ignored when -UserHash is supplied.

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
    which signals the server to allocate a new ID.

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
#>

[CmdletBinding()]
param(
    [string] $UserId = 'www',

    [object] $Password,

    [string] $UserHash,

    [string] $Path,

    [string] $BaseUri = 'https://data.uradmonitor.com/api/v1',

    [switch] $ShowHeaders,

    [switch] $CreateDevice,

    [string] $DeviceId = '13000000'
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

# Registers a new device via DIDAP by POSTing to the upload endpoint with a placeholder Device ID;
# the server allocates a real id and returns it as { "setid": 13xxxxxx } (unquoted hex).
function New-uRADMonitorDevice {
    param(
        [Parameter(Mandatory)] [hashtable] $Headers,
        [Parameter(Mandatory)] [string]    $BaseUri,
        [string] $RegistrationId = '13000000'
    )

    $uri = "{0}/upload/exp/" -f $BaseUri.TrimEnd('/')

    $registerHeaders = @{} + $Headers
    $registerHeaders['X-Device-id'] = $RegistrationId

    $response = Invoke-WebRequest -Uri $uri -Headers $registerHeaders -Method Post -ErrorAction Stop
    $content  = $response.Content

    # The setid value is unquoted hex, so extract it directly instead of parsing JSON.
    $match = [regex]::Match($content, '"setid"\s*:\s*"?([0-9A-Fa-f]{6,8})"?')
    return [pscustomobject]@{
        NewDeviceId = if ($match.Success) { $match.Groups[1].Value.ToUpper() } else { $null }
        RawResponse = $content
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
# Optionally create (register) a new device via DIDAP
# -----------------------------
if ($CreateDevice) {
    if ($UserId -eq 'www' -or $UserHash -eq 'global') {
        Write-Error "Creating a device requires authenticated credentials (-UserId with -Password or -UserHash); the public guest identity cannot register devices."
        return
    }

    try {
        $result = New-uRADMonitorDevice -Headers $headers -BaseUri $BaseUri -RegistrationId $DeviceId
        if ($result.NewDeviceId) {
            Write-Host "New device registered. Device ID: $($result.NewDeviceId)"
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
