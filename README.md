# uRADMonitor API Headers & Data (PowerShell)

A small PowerShell helper for the [uRADMonitor](https://www.uradmonitor.com/) REST API. It builds the
required authentication headers (`X-User-id` / `X-User-hash`), can query any API endpoint, and can
register a brand‑new device using uRADMonitor's **DIDAP** (Dynamic ID Allocation Protocol).

## Features

- Builds the two custom auth headers uRADMonitor requires on every request.
- Derives `X-User-hash` from your account password (lowercase MD5), or accepts a pre‑computed hash / User Key.
- Falls back to the public read‑only guest identity (`www` / `global`) when no credentials are supplied.
- Calls any API path and returns the parsed response.
- Registers a new sensor via DIDAP and returns the server‑assigned Device ID (`13xxxxxx`).

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.x.
- Internet access to `https://data.uradmonitor.com`.
- A [uRADMonitor Dashboard](https://www.uradmonitor.com/dashboard) account for authenticated calls
  (the Dashboard **API** tab shows your User ID and User Key).

## Authentication

Every request is authenticated with two headers:

| Header | Value |
| --- | --- |
| `X-User-id` | Your account User ID (numeric), or `www` for public read‑only access. |
| `X-User-hash` | For read calls: the lowercase MD5 of your password. For upload / device registration: your account **User Key**. Use `global` for public access. |

> Because the read API and the upload/registration API can expect different secrets, pass the
> appropriate value with `-UserHash` when registering a device.

## Parameters

| Parameter | Description |
| --- | --- |
| `-UserId` | Account User ID. Defaults to `www` (public guest). |
| `-Password` | Password used to derive `X-User-hash`. Accepts a `String`, `SecureString`, or `PSCredential`. Ignored when `-UserHash` is set. |
| `-UserHash` | Pre‑computed `X-User-hash` (or your User Key). Defaults to `global` when no credentials are given. |
| `-Path` | API path relative to the base URI (e.g. `devices`). When omitted, only the headers are returned. |
| `-BaseUri` | API base URI. Defaults to `https://data.uradmonitor.com/api/v1`. |
| `-ShowHeaders` | Also print the resolved headers (the hash is masked). |
| `-CreateDevice` | Register a new device via DIDAP and return the assigned Device ID. Requires authenticated credentials. |
| `-DeviceId` | Placeholder `X-Device-id` used with `-CreateDevice`. Defaults to `13000000` (asks the server to allocate a new ID). |

## Common API paths

Relative to `https://data.uradmonitor.com/api/v1/`:

| Path | Returns |
| --- | --- |
| `devices` | Devices visible to the account. |
| `devices/<deviceId>` | Latest reading for a device. |
| `devices/<deviceId>/all/<span>` | Historical data (span in seconds, e.g. `3600` for the last hour). |

## Usage

Show the public guest headers (no API call):

```powershell
.\uRADMonitor - Get API Headers and Data.ps1 -ShowHeaders
```

List your account's devices (prompts securely for the password):

```powershell
.\uRADMonitor - Get API Headers and Data.ps1 -UserId 12345 -Password (Read-Host -AsSecureString) -Path 'devices'
```

Get the latest reading and the last hour of history for a device:

```powershell
.\uRADMonitor - Get API Headers and Data.ps1 -UserId 12345 -Password $cred -Path 'devices/131234AB'
.\uRADMonitor - Get API Headers and Data.ps1 -UserId 12345 -Password $cred -Path 'devices/131234AB/all/3600'
```

Reuse the headers with your own request:

```powershell
$headers = .\uRADMonitor - Get API Headers and Data.ps1 -UserId 12345 -Password $cred
Invoke-RestMethod -Uri 'https://data.uradmonitor.com/api/v1/devices' -Headers $headers
```

## Example responses

Listing devices (`-Path 'devices'`):

```json
[
  {
    "id": "131234AB",
    "latitude": 50.85,
    "longitude": 4.35,
    "detector": "SI29BG",
    "time": 1719228914,
    "avg_temperature": 23.5
  }
]
```

Latest reading (`-Path 'devices/131234AB'`):

```json
{
  "id": "131234AB",
  "temperature": 23.5,
  "pressure": 101325,
  "humidity": 55.2,
  "cpm": 18,
  "time": 1719228914
}
```

Device registration (`-CreateDevice`):

```json
{ "setid": 131234AB }
```

> Note: the `setid` value is **unquoted hex**, so the script extracts it with a regex rather than
> parsing it as JSON.

## Creating a device (DIDAP)

To register a new sensor, the script POSTs to `/api/v1/upload/exp/` with a placeholder `X-Device-id`.
The server allocates a unique Device ID (format `13xxxxxx`) and returns it as `{ "setid": 13xxxxxx }`.

```powershell
.\uRADMonitor - Get API Headers and Data.ps1 -UserId 12345 -UserHash <userKey> -CreateDevice
# -> New device registered. Device ID: 131234AB
```

The command returns an object with:

- `NewDeviceId` – the assigned Device ID (store this permanently).
- `RawResponse` – the raw server response.

> **Store the returned Device ID.** All future data uploads for that sensor must use it as
> `X-Device-id`. Device IDs are permanently bound to your account and are recycled after ~30 days
> of inactivity.

## Security notes

- Prefer `-Password (Read-Host -AsSecureString)` or a `PSCredential` over a plain string so the
  secret doesn't land in your shell history.
- Keep your User ID and User Key private. Rotate the key from the Dashboard if it is exposed.
- The public guest identity (`www` / `global`) can only read publicly shared data and cannot
  register devices.

## References

- [uRADMonitor Dashboard](https://www.uradmonitor.com/dashboard)
- [Open data upload tutorial (DIDAP / EXP protocol)](https://www.uradmonitor.com/open-data-upload-tutorial/)

## License

Released under the [MIT License](LICENSE).

Copyright &copy; DonZalmrol

## Author

**DonZalmrol**

- GitHub: <https://github.com/DonZalmrol/>
- Website: <https://www.don-zalmrol.be/>
