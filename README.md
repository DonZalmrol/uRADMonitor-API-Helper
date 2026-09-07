# uRADMonitor API Headers & Data (PowerShell)

A small PowerShell helper for the [uRADMonitor](https://www.uradmonitor.com/) REST API. It builds the
required authentication headers (`X-User-id` / `X-User-hash`), can query any API endpoint, and can
register a brand‑new device using uRADMonitor's **DIDAP** (Dynamic ID Allocation Protocol).

## Features

- Builds the two custom auth headers uRADMonitor requires on every request.
- Uses the User Key from your uRADMonitor Dashboard API tab as `X-User-hash`.
- Calls any API path and returns the parsed response.
- Registers a new sensor via DIDAP and returns the server‑assigned Device ID (`13xxxxxx`).
- Validates registration EXP fields and copies a firmware-ready device ID after successful registration.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.x.
- Internet access to `https://data.uradmonitor.com`.
- A [uRADMonitor Dashboard](https://www.uradmonitor.com/dashboard) account for authenticated calls
  (the Dashboard **API** tab shows your User ID and User Key).

## Files

| File | Purpose |
| --- | --- |
| `uRADMonitor - Get API Headers and Data.ps1` | API helper and Windows Forms interface: headers, queries, and device registration. |
| `uradmonitor-logo-2026.png` / `uradmonitor-logo-2026.ico` | Optional branding assets used by the GUI. |
| `gui-screenshot.png` | Screenshot used in this README. |

## GUI

Run the single script with no parameters to open the **uRADMonitor API Helper** Windows Forms interface:

```powershell
.\uRADMonitor - Get API Headers and Data.ps1
```

![uRADMonitor API Helper](gui-screenshot.png)

- Enter your User ID and User Key (masked, with a **Show** toggle).
- Pick a **Path** preset (`devices`, `devices/{id}`, `devices/{id}/all/3600`, …) or type your own;
  `{id}` is replaced with the selected Device ID.
- **Refresh list** loads your device IDs into the Device ID picker, while the adjacent **Get Data**
  retrieves the selected path.
- **Create Device** and **Show Headers** run the matching core-script action and show the result as
  formatted JSON.
- **Dashboard Online** opens the uRADMonitor Dashboard in your default browser.
- **New Device Setup** lets you choose the initial sensor readings sent with a registration request.
  After registration, the Device ID is copied to the clipboard and selected in the Device ID picker.
- The GUI remains responsive during API requests and disables its action buttons until the request completes.

Windows Forms needs an STA thread, so the GUI relaunches itself in Windows PowerShell (`-STA`) when
started from `pwsh`. Entering the key in the GUI also keeps it out of your shell history.

The header logo and window icon are loaded from `uradmonitor-logo-2026.png` and `uradmonitor-logo-2026.ico` in the
script folder; the GUI still runs if those files are missing.

## Authentication

Every request is authenticated with two headers:

| Header | Value |
| --- | --- |
| `X-User-id` | Your account User ID (numeric). |
| `X-User-hash` | Your account **User Key** (shown on the Dashboard **API** tab). |

> The `X-User-hash` value is your **User Key**, not your login password. Copy the User ID and User
> Key from the uRADMonitor Dashboard **API** tab and pass the key with `-UserHash`.

## Parameters

| Parameter | Description |
| --- | --- |
| `-UserId` | Account User ID. Required for command-line API actions. |
| `-UserHash` | Your User Key. Required for command-line API actions. |
| `-Path` | API path relative to the base URI (e.g. `devices`). When omitted, only the headers are returned. |
| `-BaseUri` | API base URI. Defaults to `https://data.uradmonitor.com/api/v1`. |
| `-TimeoutSeconds` | Maximum seconds to wait for an API request. Defaults to `30`; GET requests retry transient failures twice. |
| `-ShowHeaders` | Also print the resolved headers (the hash is masked). |
| `-Gui` | Opens the Windows Forms interface. This is the default when the script has no parameters. |
| `-SendDummyData` | Sends a single EXP upload for a device using the supplied `-DummyDataValue`. Useful for an activation test or a manual sync. |
| `-DummyDataValue` | Dummy sensor value to send with `-SendDummyData`. Defaults to `0`. |
| `-CreateDevice` | Register a new device via DIDAP and return the assigned Device ID. Requires authenticated credentials. |
| `-DeviceId` | Placeholder `X-Device-id` used with `-CreateDevice`. Defaults to `13000000`, the manual registration value in the uRADMonitor tutorial. |
| `-InitialValues` | EXP fields (`ID/value`) sent with the registration upload. Defaults to temperature, pressure, humidity, CO₂, PM2.5 and radiation, all `0`. |

## Common API paths

Relative to `https://data.uradmonitor.com/api/v1/`:

| Path | Returns |
| --- | --- |
| `devices` | Devices visible to the account. |
| `devices/<deviceId>` | Latest reading for a device. |
| `devices/<deviceId>/all/<span>` | Historical data (span in seconds, e.g. `3600` for the last hour). |

## Usage

Show your authenticated headers (no API call):

```powershell
.\uRADMonitor - Get API Headers and Data.ps1 -UserId 7076 -UserHash '<your User Key>' -ShowHeaders
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

### DIDAP identifiers

- `13000000` is the placeholder this helper uses for manual registration. It is the value shown in
  uRADMonitor's manual upload example and reliably requests a new allocation.
- `13xxxxxx` is an allocated device ID returned in `setid`; persist it in the device's non-volatile
  storage and use it for every future upload.
- `00000000` and `FFFFFFFF` are unknown-ID values described in firmware-oriented DIDAP material,
  but this helper does not offer them because they have been rejected by the API during its manual
  registration tests.

```powershell
.\uRADMonitor - Get API Headers and Data.ps1 -UserId 7076 -UserHash '<your User Key>' -CreateDevice
# -> New device registered. Device ID: 1300FFFF
# -> Initial values sent: 02/0/03/0/04/0/07/0/09/0/0B/0
# -> View it here: https://www.uradmonitor.com/tools/dashboard-09/?open=1300FFFF
```

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

- Keep your User ID and User Key private. Rotate the key from the Dashboard if it is exposed.
- uRADMonitor has a SHIELD/DDoS protection layer that can flag an account or IP if DIDAP or EXP uploads are made too aggressively.
- Do not create many DIDAP IDs in quick succession or repeatedly upload dummy data.
- Persist the returned Device ID in your device's EEPROM, NVS, or other non-volatile storage; do not
  request a DIDAP ID on every boot.
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
