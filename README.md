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
- Can send a slow 5-minute dummy activation ramp after registration to help the new device settle without triggering SHIELD rate protection.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.x.
- Internet access to `https://data.uradmonitor.com`.
- A [uRADMonitor Dashboard](https://www.uradmonitor.com/dashboard) account for authenticated calls
  (the Dashboard **API** tab shows your User ID and User Key).

## Files

| File | Purpose |
| --- | --- |
| `uRADMonitor - Get API Headers and Data.ps1` | Core script: headers, API queries, device registration. |
| `uRADMonitor GUI.ps1` | uRADMonitor API Helper – Windows Forms front-end for the core script. |
| `uradmonitor-logo-2026.png` / `uradmonitor-logo-2026.ico` | Optional branding assets used by the GUI. |
| `gui-screenshot.png` | Screenshot used in this README. |

## GUI

`uRADMonitor GUI.ps1` (**uRADMonitor API Helper**) provides a small Windows Forms front-end for the
core script – the easiest way to get started:

```powershell
.\uRADMonitor GUI.ps1
```

![uRADMonitor API Helper](gui-screenshot.png)

- Enter your User ID and User Key (masked, with a **Show** toggle).
- Pick a **Path** preset (`devices`, `devices/{id}`, `devices/{id}/all/3600`, …) or type your own;
  `{id}` is replaced with the selected Device ID.
- **Refresh list** loads your device IDs into the Device ID picker, while the adjacent **Get Data**
  retrieves the selected path.
- **Create Device** and **Show Headers** run the matching core-script action and show the result as
  formatted JSON.

Windows Forms needs an STA thread, so the GUI relaunches itself in Windows PowerShell (`-STA`) when
started from `pwsh`. Entering the key in the GUI also keeps it out of your shell history.

The header logo and window icon are loaded from `uradmonitor-logo-2026.png` and `uradmonitor-logo-2026.ico` in the
script folder; the GUI still runs if those files are missing.

## Authentication

Every request is authenticated with two headers:

| Header | Value |
| --- | --- |
| `X-User-id` | Your account User ID (numeric), or `www` for public read-only access. |
| `X-User-hash` | Your account **User Key** (shown on the Dashboard **API** tab), or `global` for public access. |

> The `X-User-hash` value is your **User Key**, not your login password. Copy the User ID and User
> Key from the uRADMonitor Dashboard **API** tab and pass the key with `-UserHash`. The `-Password`
> switch is only a shortcut that sends `MD5(password)` and will fail unless your User Key happens to
> equal that hash — so prefer `-UserHash`.

## Parameters

| Parameter | Description |
| --- | --- |
| `-UserId` | Account User ID. Defaults to `www` (public guest). |
| `-Password` | Password used to derive `X-User-hash`. Accepts a `String`, `SecureString`, or `PSCredential`. Ignored when `-UserHash` is set. |
| `-UserHash` | Pre‑computed `X-User-hash` (or your User Key). Defaults to `global` when no credentials are given. |
| `-Path` | API path relative to the base URI (e.g. `devices`). When omitted, only the headers are returned. |
| `-BaseUri` | API base URI. Defaults to `https://data.uradmonitor.com/api/v1`. |
| `-ShowHeaders` | Also print the resolved headers (the hash is masked). |
| `-SendDummyData` | Sends a single EXP upload for a device using the supplied `-DummyDataValue`. Useful for an activation test or a manual sync. |
| `-DummyDataValue` | Dummy sensor value to send with `-SendDummyData`. Defaults to `0`. |
| `-ActivationSyncs` | Number of slow dummy activation syncs to send after `-CreateDevice`. Defaults to `5`. |
| `-ActivationIntervalSeconds` | Delay in seconds between activation syncs. Defaults to `60` to keep traffic gentle and within SHIELD limits. |
| `-CreateDevice` | Register a new device via DIDAP and return the assigned Device ID. Requires authenticated credentials. |
| `-DeviceId` | Placeholder `X-Device-id` used with `-CreateDevice`. Defaults to `13000000` (asks the server to allocate a new ID). |
| `-InitialValues` | EXP fields (`ID/value`) sent with the registration upload. Defaults to temperature, pressure, humidity, CO₂, PM2.5 and radiation, all `0`. |

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

List your account's devices:

```powershell
.\uRADMonitor - Get API Headers and Data.ps1 -UserId 7076 -UserHash '<your User Key>' -Path 'devices'
```

Get the latest reading and the last hour of history for a device:

```powershell
.\uRADMonitor - Get API Headers and Data.ps1 -UserId 7076 -UserHash '<your User Key>' -Path 'devices/131234AB'
.\uRADMonitor - Get API Headers and Data.ps1 -UserId 7076 -UserHash '<your User Key>' -Path 'devices/131234AB/all/3600'
```

Reuse the headers with your own request:

```powershell
$headers = .\uRADMonitor - Get API Headers and Data.ps1 -UserId 7076 -UserHash '<your User Key>'
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
{ "setid": "1300FFFF" }
```

> Important: the server may return a DIDAP `setid` even when the ID is not yet visible in the dashboard immediately. In live tests, it was possible to receive a valid allocation response while the account list still did not show the ID. That is consistent with SHIELD/DDoS protection behavior and can require a short wait or a fresh account-side synchronization.

## Creating a device (DIDAP)

To register a new sensor, the script POSTs to the EXP upload endpoint with the placeholder
`X-Device-id` header. The server allocates a unique Device ID (format `13xxxxxx`) and returns it as
`{ "setid": "13xxxxxx" }`.

```powershell
.\uRADMonitor - Get API Headers and Data.ps1 -UserId 7076 -UserHash '<your User Key>' -CreateDevice
# -> New device registered. Device ID: 1300FFFF
# -> Initial values sent: 02/0/03/0/04/0/07/0/09/0/0B/0
# -> View it here: https://www.uradmonitor.com/tools/dashboard-09/?open=1300FFFF
```

For a new device, the script can also send a gentle 5-minute activation sequence after registration:

```powershell
.\uRADMonitor - Get API Headers and Data.ps1 -UserId 7076 -UserHash '<your User Key>' -CreateDevice -ActivationSyncs 5 -ActivationIntervalSeconds 60
```

This sends a slow ramp like `0, 1, 2, 3, 4, 5` over time so the device is active without hammering the API. This is intentional because uRADMonitor has SHIELD / DDoS protections and too many rapid DIDAP or EXP requests can trigger account or IP blocking.

The request that works looks like this:

```text
POST https://data.uradmonitor.com/api/v1/upload/exp/01/<epoch>/02/0/03/0/04/0/07/0/09/0/0B/0
X-User-id:   <your User ID>
X-User-hash: <your User Key>
X-Device-id: 13000000
```

Things the server enforces (each returns a distinct error if you get it wrong):

| Requirement | Error if violated |
| --- | --- |
| EXP values must be **URL path segments** (`ID/value`), not a request body. | `EXP payload missing timelocal` |
| Field `01` (local time, Unix epoch) is mandatory. | `EXP payload missing timelocal` |
| At least one real measurement must be present (time alone is not enough). | `EXP payload has no valid measurement` |
| `X-Device-id` must be `13000000`; `FFFFFFFF` / `00000000` are not accepted. | `Invalid Device ID` |
| Uploads are rate limited, so the initial values must ride along with the registration instead of being sent as a second request. | `Too many reports <id>` |

Use `-InitialValues` to control the readings that are sent:

```powershell
# temperature 21.5 C / radiation 12 CPM / humidity 55 %
... -CreateDevice -InitialValues '02/21.5'
... -CreateDevice -InitialValues '0B/12'
... -CreateDevice -InitialValues '02/21.5/04/55'
```

> Registration doubles as the device's first data upload, so the value you pass is stored as a real
> reading. Pass a sensible value if you don't want a dummy `0 °C` in your history.

The command returns an object with:

- `NewDeviceId` – the assigned Device ID (store this permanently).
- `DeviceUrl` – link to view the device on the uRADMonitor map.
- `InitialValues` – the EXP fields that were sent.
- `RawResponse` – the raw server response.

### Initial values

The registration upload initialises these sensors to `0`:

| EXP ID | Sensor |
| --- | --- |
| `02` | Temperature (°C) |
| `03` | Barometric pressure (Pa) |
| `04` | Relative humidity (%) |
| `07` | CO₂ (ppm) |
| `09` | PM2.5 (µg/m³) |
| `0B` | Radiation (CPM) |

> Registration doubles as the device's first data upload, so these values are stored as real
> readings. Pass `-InitialValues` if you'd rather record actual measurements than zeros.

> **Store the returned Device ID.** All future data uploads for that sensor must use it as
> `X-Device-id`. Device IDs are permanently bound to your account and are recycled after ~30 days
> of inactivity.

## Security and rate-limit notes

- Prefer `-Password (Read-Host -AsSecureString)` or a `PSCredential` over a plain string so the
  secret doesn't land in your shell history.
- Keep your User ID and User Key private. Rotate the key from the Dashboard if it is exposed.
- The public guest identity (`www` / `global`) can only read publicly shared data and cannot
  register devices.
- uRADMonitor has a SHIELD/DDoS protection layer that can flag an account or IP if DIDAP or EXP uploads are made too aggressively.
- Do not create many DIDAP IDs in quick succession. A slow activation pattern is safer than a burst of rapid registrations or repeated uploads.
- If a DIDAP response returns a valid `setid` but the device does not immediately appear in the dashboard, wait a few minutes and re-check the device list before retrying.

## References

- [uRADMonitor Dashboard](https://www.uradmonitor.com/dashboard)
- [uRADMonitor Dashboard 09](https://www.uradmonitor.com/tools/dashboard-09/)
- [Open data upload tutorial (DIDAP / EXP protocol)](https://www.uradmonitor.com/open-data-upload-tutorial/)

## License

Released under the [MIT License](LICENSE).

Copyright &copy; DonZalmrol

## Author

**DonZalmrol**

- GitHub: <https://github.com/DonZalmrol/>
- Website: <https://www.don-zalmrol.be/>
