#!/usr/bin/env python3
"""Tkinter GUI for the uRADMonitor API helper.

This provides a desktop window to:
- build X-User authentication headers
- refresh account device IDs
- query selected API paths
- create a DIDAP device
- display headers and API responses
"""

from __future__ import annotations

import argparse
import json
import math
import re
import threading
import time
import tkinter as tk
import webbrowser
from pathlib import Path
from tkinter import messagebox, ttk
from typing import Any, Dict, Optional

import requests

BASE_URI = "https://data.uradmonitor.com/api/v1"

# EXP protocol sensor fields (id, label, unit) from the uRADMonitor open-data upload tutorial.
# Field 01 (Unix timestamp) is mandatory and added automatically on every upload.
SENSOR_DEFINITIONS = [
    ("01", "Local time (epoch)", "Unix timestamp, seconds"),
    ("02", "Temperature", "Degrees Celsius"),
    ("03", "Barometric pressure", "Pascals"),
    ("04", "Relative humidity", "Percent"),
    ("05", "Illuminance", "Lux"),
    ("06", "VOC", "Ohms (sensor resistance)"),
    ("07", "CO2", "Parts per million"),
    ("08", "CH2O (Formaldehyde)", "Parts per million"),
    ("09", "PM2.5", "Micrograms per cubic metre"),
    ("0A", "Battery voltage", "Volts"),
    ("0B", "Radiation level", "Counts per minute"),
    ("0C", "Geiger inverter voltage", "Volts"),
    ("0D", "Geiger inverter duty cycle", "Promille (0-1000)"),
    ("0E", "Hardware version", "Integer"),
    ("0F", "Firmware version", "Integer"),
    ("10", "Geiger tube type", "Manufacturer-defined ID"),
    ("11", "Noise level", "Decibels"),
    ("12", "PM1.0", "Micrograms per cubic metre"),
    ("13", "PM10", "Micrograms per cubic metre"),
    ("14", "Ozone (O3)", "Parts per billion"),
    ("15", "Radon (Rn)", "Becquerels per cubic metre"),
    ("16", "Wind speed", "Metres per second"),
    ("17", "Wind direction", "Azimuth degrees"),
    ("18", "Rain accumulation", "Millimetres"),
    ("19", "Irradiance", "Watts per square metre"),
    ("1A", "Signal", "dBm"),
]

# The mandatory timestamp (01) is supplied automatically, so it is not a selectable measurement.
MANDATORY_SENSOR_ID = "01"
SUPPORTED_SENSOR_IDS = {sensor_id for sensor_id, _, _ in SENSOR_DEFINITIONS if sensor_id != MANDATORY_SENSOR_ID}
SENSOR_LABELS = {sensor_id: label for sensor_id, label, _ in SENSOR_DEFINITIONS}

# Suggested default values for specific EXP fields; all other optional fields default to "0".
SENSOR_DEFAULT_VALUES = {
    "0E": "3",    # Hardware version
    "0F": "104",  # Firmware version
}

# Geiger tube type field (10) handled with a dropdown instead of a free-text value.
TUBE_SENSOR_ID = "10"
CUSTOM_TUBE_LABEL = "Custom..."

# Geiger tube types from the uRADMonitor KIT1 firmware (code/124/geiger/detectors.h).
# Each entry is (decimal tube ID, display name); the decimal ID is sent as the field 10 value.
TUBE_DEFINITIONS = [
    (0, "Unknown"),
    (1, "SBM-20"),
    (2, "SI-29BG"),
    (3, "SBM-19"),
    (4, "LND-712"),
    (5, "SBM-20M"),
    (6, "SI-22G"),
    (7, "STS-5"),
    (8, "SI-3BG"),
    (9, "SBM-21"),
    (10, "SBT-9"),
    (11, "SI-1G"),
    (12, "SI-8B"),
    (13, "SBT-10A"),
    (14, "J305"),
    (15, "M4011"),
]
TUBE_CHOICES = [f"{name} (0x{tube_id:X})" for tube_id, name in TUBE_DEFINITIONS]
TUBE_CHOICE_TO_VALUE = {choice: str(tube_id) for choice, (tube_id, _) in zip(TUBE_CHOICES, TUBE_DEFINITIONS)}
TUBE_VALUE_TO_CHOICE = {str(tube_id): choice for choice, (tube_id, _) in zip(TUBE_CHOICES, TUBE_DEFINITIONS)}


class ApiError(RuntimeError):
    """Raised when an API operation fails."""


def mask_user_hash(user_hash: str) -> str:
    if not user_hash:
        return ""
    return user_hash[: min(6, len(user_hash))] + "..."


def validate_user_id(user_id: str) -> None:
    value = str(user_id).strip()
    if not value or not re.fullmatch(r"\d+", value):
        raise ValueError("User ID must contain digits only.")


def validate_device_id(value: str, *, registration: bool = False) -> None:
    value = str(value).strip()
    if registration:
        if value != "13000000":
            raise ValueError("DIDAP registration requires the 13000000 placeholder Device ID.")
        return
    if not re.fullmatch(r"13[0-9A-Fa-f]{6}", value):
        raise ValueError("Device ID must be an eight-character hexadecimal value beginning with 13.")


def validate_initial_values(values: str) -> None:
    if values is None:
        raise ValueError(
            "Initial values must contain one or more EXP ID/value pairs, for example '02/21.5/04/55'."
        )

    raw = values.strip().strip("/")
    if not raw:
        raise ValueError(
            "Initial values must contain one or more EXP ID/value pairs, for example '02/21.5/04/55'."
        )

    segments = [segment.strip() for segment in raw.split("/") if segment.strip()]
    if len(segments) < 2 or len(segments) % 2 != 0:
        raise ValueError(
            "Initial values must contain one or more EXP ID/value pairs, for example '02/21.5/04/55'."
        )

    for index in range(0, len(segments), 2):
        sensor_id = segments[index].upper()
        if sensor_id not in SUPPORTED_SENSOR_IDS:
            raise ValueError(
                f"Unsupported EXP sensor ID '{sensor_id}'. Use an ID from 02 through 1A, excluding 01 which is added automatically."
            )

        try:
            value = float(segments[index + 1])
        except ValueError as exc:
            raise ValueError(
                f"EXP value for sensor ID '{sensor_id}' must be a finite number using a decimal point."
            ) from exc

        if math.isnan(value) or math.isinf(value):
            raise ValueError(
                f"EXP value for sensor ID '{sensor_id}' must be a finite number using a decimal point."
            )


def build_headers(user_id: str, user_hash: str) -> Dict[str, str]:
    validate_user_id(user_id)
    return {
        "X-User-id": str(user_id).strip(),
        "X-User-hash": str(user_hash).strip(),
    }


def get_error_detail(exc: requests.RequestException) -> str:
    if exc is None:
        return "Unknown error"

    message = str(exc)
    response = getattr(exc, "response", None)
    if response is None:
        return message

    try:
        status_text = f"{response.status_code} {response.reason}"
        body = response.text.strip()
        if body:
            return f"{message}\nHTTP {status_text}\n{body}"
        return f"{message}\nHTTP {status_text}"
    except Exception:
        return message


def is_transient_error(exc: requests.RequestException) -> bool:
    response = getattr(exc, "response", None)
    if response is None:
        return True
    status_code = getattr(response, "status_code", None)
    return status_code in (408, 429) or (status_code is not None and status_code >= 500)


def request_json_or_text(method: str, url: str, headers: Dict[str, str], timeout: int = 30) -> Any:
    for attempt in range(1, 4):
        try:
            response = requests.request(method=method, url=url, headers=headers, timeout=timeout)
            response.raise_for_status()
            if not response.content:
                return None
            try:
                return response.json()
            except ValueError:
                return response.text
        except requests.RequestException as exc:
            if attempt == 3 or not is_transient_error(exc):
                raise ApiError(f"Request to '{url}' failed: {get_error_detail(exc)}") from exc
            time.sleep(attempt)

    raise ApiError(f"Request to '{url}' failed after retries.")


def send_exp_upload(
    headers: Dict[str, str],
    base_uri: str,
    device_id: str,
    fields: Optional[str] = None,
    timeout: int = 30,
) -> str:
    exp_headers = dict(headers)
    exp_headers["X-Device-id"] = str(device_id)

    payload = f"01/{int(time.time())}"
    if fields and str(fields).strip():
        payload = f"{payload}/{str(fields).strip('/')}"

    uri = f"{base_uri.rstrip('/')}/upload/exp/{payload}"
    for attempt in range(1, 4):
        try:
            response = requests.post(uri, headers=exp_headers, timeout=timeout)
            response.raise_for_status()
            return response.text
        except requests.RequestException as exc:
            if attempt == 3:
                raise ApiError(f"EXP upload failed: {get_error_detail(exc)}") from exc
            time.sleep(attempt)

    raise ApiError(f"EXP upload failed for device '{device_id}'.")


def register_new_device(
    headers: Dict[str, str],
    base_uri: str,
    registration_id: str = "13000000",
    initial_values: str = "02/0/03/0/04/0/07/0/09/0/0B/0",
    timeout: int = 30,
) -> Dict[str, Any]:
    validate_device_id(registration_id, registration=True)
    validate_initial_values(initial_values)

    content = send_exp_upload(headers, base_uri, registration_id, initial_values, timeout=timeout)
    match = re.search(r'"setid"\s*:\s*"?([0-9A-Fa-f]{6,8})"?', content, flags=re.IGNORECASE)
    new_device_id = match.group(1).upper() if match else None

    return {
        "NewDeviceId": new_device_id,
        "DeviceUrl": f"https://www.uradmonitor.com/tools/dashboard-09/?open={new_device_id}" if new_device_id else None,
        "InitialValues": initial_values,
        "DashboardNotice": (
            "The device may take some time to appear in your dashboard. If it does not appear after waiting, "
            "contact uRADMonitor support to have it added to your dashboard."
        ),
        "RawResponse": content,
    }


def parse_initial_values(values: str) -> Dict[str, str]:
    """Parse an 'ID/value/ID/value' EXP string into an ordered {id: value} mapping."""
    result: Dict[str, str] = {}
    if not values:
        return result
    segments = [segment.strip() for segment in values.strip().strip("/").split("/") if segment.strip()]
    for index in range(0, len(segments) - 1, 2):
        result[segments[index].upper()] = segments[index + 1]
    return result


def center_on_parent(window: tk.Misc, parent: tk.Misc) -> None:
    try:
        px, py = parent.winfo_rootx(), parent.winfo_rooty()
        pw, ph = parent.winfo_width(), parent.winfo_height()
        w, h = window.winfo_width(), window.winfo_height()
        window.geometry(f"+{px + (pw - w) // 2}+{py + (ph - h) // 2}")
    except Exception:
        pass


class SensorSelectionDialog(tk.Toplevel):
    """Modal checkbox picker for the EXP sensor fields used as a device's initial values."""

    def __init__(self, parent: tk.Misc, current_values: str = ""):
        super().__init__(parent)
        self.title("Select EXP Sensors")
        self.transient(parent)
        self.resizable(False, True)
        self.result: Optional[str] = None

        selected = parse_initial_values(current_values)
        self._rows: Dict[str, Dict[str, Any]] = {}

        intro = ttk.Label(
            self,
            text=(
                "Tick each sensor to include in the device's initial upload and enter its value.\n"
                "Field 01 (Unix timestamp) is mandatory and is added automatically on every upload."
            ),
            justify="left",
        )
        intro.pack(fill="x", padx=12, pady=(12, 8))

        note = ttk.Label(
            self,
            text=(
                "Important: include every parameter your device will ever report in this first\n"
                "upload. Any field missing from the first upload is disabled and hidden on the\n"
                "dashboard, and re-enabling it later requires contacting uRADMonitor support.\n"
                "Rule of thumb: upload complete data from day one (approximate values are fine)."
            ),
            justify="left",
            foreground="#b00020",
        )
        note.pack(fill="x", padx=12, pady=(0, 8))

        container = ttk.Frame(self)
        container.pack(fill="both", expand=True, padx=12)

        canvas = tk.Canvas(container, borderwidth=0, highlightthickness=0, width=440, height=420)
        scrollbar = ttk.Scrollbar(container, orient="vertical", command=canvas.yview)
        canvas.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")
        canvas.pack(side="left", fill="both", expand=True)

        grid = ttk.Frame(canvas)
        grid.columnconfigure(1, weight=1)
        grid_window = canvas.create_window((0, 0), window=grid, anchor="nw")
        grid.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.bind("<Configure>", lambda e: canvas.itemconfigure(grid_window, width=e.width))

        ttk.Label(grid, text="Use", font=("Segoe UI", 9, "bold")).grid(row=0, column=0, padx=(0, 8), pady=(0, 4))
        ttk.Label(grid, text="Sensor", font=("Segoe UI", 9, "bold")).grid(row=0, column=1, sticky="w", pady=(0, 4))
        ttk.Label(grid, text="Value", font=("Segoe UI", 9, "bold")).grid(row=0, column=2, padx=(8, 0), pady=(0, 4))

        for offset, (sensor_id, label, unit) in enumerate(SENSOR_DEFINITIONS, start=1):
            mandatory = sensor_id == MANDATORY_SENSOR_ID
            check_var = tk.BooleanVar(value=mandatory or sensor_id in selected)
            check = ttk.Checkbutton(grid, variable=check_var)
            if mandatory:
                check.state(["disabled", "selected"])
            check.grid(row=offset, column=0, padx=(0, 8), pady=2)

            ttk.Label(grid, text=f"{sensor_id}  {label} ({unit})").grid(row=offset, column=1, sticky="w", pady=2)

            if mandatory:
                ttk.Label(grid, text="automatic", foreground="#666666").grid(row=offset, column=2, sticky="e", padx=(8, 0), pady=2)
                value_var = None
                self._rows[sensor_id] = {"check": check_var, "value": value_var, "mandatory": mandatory}
            elif sensor_id == TUBE_SENSOR_ID:
                preset = selected.get(sensor_id)
                cell = ttk.Frame(grid)
                cell.grid(row=offset, column=2, sticky="e", padx=(8, 0), pady=2)
                choice_var = tk.StringVar()
                combo = ttk.Combobox(
                    cell, textvariable=choice_var, values=TUBE_CHOICES + [CUSTOM_TUBE_LABEL],
                    state="readonly", width=16,
                )
                combo.pack(anchor="e")
                custom_var = tk.StringVar()
                custom_entry = ttk.Entry(cell, textvariable=custom_var, width=16)

                def _toggle_custom(*_args, _choice=choice_var, _entry=custom_entry):
                    if _choice.get() == CUSTOM_TUBE_LABEL:
                        _entry.pack(anchor="e", pady=(4, 0))
                    else:
                        _entry.pack_forget()

                choice_var.trace_add("write", _toggle_custom)
                if preset is not None and preset not in TUBE_VALUE_TO_CHOICE:
                    choice_var.set(CUSTOM_TUBE_LABEL)
                    custom_var.set(preset)
                elif preset is not None:
                    choice_var.set(TUBE_VALUE_TO_CHOICE[preset])
                else:
                    choice_var.set(TUBE_VALUE_TO_CHOICE["3"])  # SBM-19 default
                self._rows[sensor_id] = {
                    "check": check_var, "value": None, "mandatory": mandatory,
                    "tube": True, "choice": choice_var, "custom": custom_var,
                }
            else:
                default_value = selected.get(sensor_id, SENSOR_DEFAULT_VALUES.get(sensor_id, "0"))
                value_var = tk.StringVar(value=default_value)
                ttk.Entry(grid, textvariable=value_var, width=12).grid(row=offset, column=2, sticky="e", padx=(8, 0), pady=2)
                self._rows[sensor_id] = {"check": check_var, "value": value_var, "mandatory": mandatory}

        button_row = ttk.Frame(self)
        button_row.pack(fill="x", padx=12, pady=12)
        ttk.Button(button_row, text="OK", command=self._on_ok).pack(side="right")
        ttk.Button(button_row, text="Cancel", command=self._on_cancel).pack(side="right", padx=(0, 8))

        self.bind("<Return>", lambda e: self._on_ok())
        self.bind("<Escape>", lambda e: self._on_cancel())
        self.protocol("WM_DELETE_WINDOW", self._on_cancel)

        self.update_idletasks()
        center_on_parent(self, parent)
        self.grab_set()

    def _on_ok(self) -> None:
        pairs = []
        for sensor_id, row in self._rows.items():
            if row["mandatory"] or not row["check"].get():
                continue
            if row.get("tube"):
                if row["choice"].get() == CUSTOM_TUBE_LABEL:
                    raw = row["custom"].get().strip()
                else:
                    raw = TUBE_CHOICE_TO_VALUE.get(row["choice"].get(), "").strip()
            else:
                raw = row["value"].get().strip()
            try:
                value = float(raw)
                if math.isnan(value) or math.isinf(value):
                    raise ValueError
            except ValueError:
                messagebox.showerror(
                    "Invalid value",
                    f"Sensor {sensor_id} needs a finite number using a decimal point.",
                    parent=self,
                )
                return
            pairs.append(f"{sensor_id}/{raw}")

        if not pairs:
            messagebox.showwarning(
                "Select a measurement",
                "Select at least one sensor besides the mandatory timestamp. "
                "The server rejects a timestamp-only upload.",
                parent=self,
            )
            return

        self.result = "/".join(pairs)
        self.destroy()

    def _on_cancel(self) -> None:
        self.result = None
        self.destroy()


class ConfirmCreateDialog(tk.Toplevel):
    """Confirm DIDAP registration, offering Yes / Edit sensors / Cancel."""

    def __init__(self, parent: tk.Misc, initial_values: str = ""):
        super().__init__(parent)
        self.title("Confirm Device Creation")
        self.transient(parent)
        self.resizable(False, False)
        self.result: Optional[str] = None  # "yes", "edit", or "cancel"

        parsed = parse_initial_values(initial_values)

        ttk.Label(
            self,
            text="Register a new device on your uRADMonitor account?",
            font=("Segoe UI", 10, "bold"),
            justify="left",
        ).pack(fill="x", padx=14, pady=(14, 6))

        ttk.Label(
            self,
            text="These sensor fields will be sent on the device's first upload:",
            justify="left",
        ).pack(fill="x", padx=14, pady=(0, 4))

        summary = tk.Text(self, height=min(14, 2 + len(parsed)), width=46, wrap="none", font=("Consolas", 9))
        summary.pack(fill="both", expand=True, padx=14)
        summary.insert("end", "01  Local time (epoch) - automatic\n")
        for sensor_id, value in parsed.items():
            display = value
            if sensor_id == TUBE_SENSOR_ID and value in TUBE_VALUE_TO_CHOICE:
                display = TUBE_VALUE_TO_CHOICE[value]
            summary.insert("end", f"{sensor_id}  {SENSOR_LABELS.get(sensor_id, 'Unknown')} = {display}\n")
        summary.configure(state="disabled")

        if not parsed:
            ttk.Label(
                self,
                text=(
                    "No measurement selected. Click Edit sensors to add at least one;\n"
                    "the server rejects a timestamp-only upload."
                ),
                foreground="#b00020",
                justify="left",
            ).pack(fill="x", padx=14, pady=(6, 0))

        ttk.Label(
            self,
            text=(
                "Reminder: include every parameter your device will ever report now.\n"
                "Fields missing from the first upload stay disabled until you contact support."
            ),
            foreground="#b00020",
            justify="left",
        ).pack(fill="x", padx=14, pady=(8, 0))

        button_row = ttk.Frame(self)
        button_row.pack(fill="x", padx=14, pady=14)
        yes_btn = ttk.Button(button_row, text="Yes, create", command=lambda: self._set_result("yes"))
        yes_btn.pack(side="right")
        if not parsed:
            yes_btn.state(["disabled"])
        ttk.Button(button_row, text="Edit sensors", command=lambda: self._set_result("edit")).pack(side="right", padx=(0, 8))
        ttk.Button(button_row, text="Cancel", command=lambda: self._set_result("cancel")).pack(side="right", padx=(0, 8))

        self.bind("<Escape>", lambda e: self._set_result("cancel"))
        self.protocol("WM_DELETE_WINDOW", lambda: self._set_result("cancel"))

        self.update_idletasks()
        center_on_parent(self, parent)
        self.grab_set()

    def _set_result(self, value: str) -> None:
        self.result = value
        self.destroy()


class UraDMonitorGui(tk.Tk):
    def __init__(self, base_uri: str = BASE_URI):
        super().__init__()
        self.base_uri = base_uri
        self.title("uRADMonitor API Helper")
        self.geometry("750x820")
        self.minsize(700, 720)

        self.task_running = False
        self.status_var = tk.StringVar(value="Ready")
        self.script_dir = Path(__file__).resolve().parent
        self.logo_image = self._load_logo()

        self._build_ui()

    def _load_logo(self):
        logo_path = self.script_dir / "uradmonitor-logo-2026.png"
        if logo_path.exists():
            try:
                image = tk.PhotoImage(file=str(logo_path))
                target_width = 100
                width = image.width()
                if width > target_width:
                    scale = max(2, round(width / target_width))
                    return image.subsample(scale, scale)
                return image
            except Exception:
                return None
        return None

    def _apply_window_icon(self) -> None:
        icon_path = self.script_dir / "uradmonitor-logo-2026.ico"
        if not icon_path.exists():
            return
        try:
            self.iconbitmap(str(icon_path))
        except Exception:
            pass

    def _build_ui(self) -> None:
        self._apply_window_icon()

        header = ttk.Frame(self)
        header.pack(fill="x", padx=15, pady=(12, 0))
        header.columnconfigure(1, weight=1)

        if self.logo_image:
            logo_label = ttk.Label(header, image=self.logo_image)
            logo_label.grid(row=0, column=0, padx=(0, 12), sticky="w")

        title = ttk.Label(header, text="uRADMonitor API Helper", font=("Segoe UI", 14, "bold"))
        title.grid(row=0, column=1, sticky="w")

        dashboard_button = ttk.Button(header, text="Dashboard Online", command=lambda: webbrowser.open("https://www.uradmonitor.com/dashboard/"))
        dashboard_button.grid(row=0, column=2, sticky="e")

        top = ttk.Frame(self, padding=(15, 10, 15, 15))
        top.pack(fill="both", expand=True)

        ttk.Label(top, text="User ID:").grid(row=0, column=0, sticky="w", padx=(0, 10), pady=(0, 8))
        self.user_id_var = tk.StringVar()
        ttk.Entry(top, textvariable=self.user_id_var, width=24).grid(row=0, column=1, sticky="ew", pady=(0, 8))

        ttk.Label(top, text="User Key:").grid(row=1, column=0, sticky="w", padx=(0, 10), pady=(0, 8))
        self.user_hash_var = tk.StringVar()
        self.user_hash_entry = ttk.Entry(top, textvariable=self.user_hash_var, width=48, show="*")
        self.user_hash_entry.grid(row=1, column=1, sticky="ew", pady=(0, 8))

        self.show_key_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(
            top,
            text="Show",
            variable=self.show_key_var,
            command=self._toggle_user_key_visibility,
        ).grid(row=1, column=2, sticky="w", padx=(10, 0), pady=(0, 8))

        ttk.Label(top, text="Path:").grid(row=2, column=0, sticky="w", padx=(0, 10), pady=(0, 8))
        self.path_var = tk.StringVar(value="devices")
        self.path_combo = ttk.Combobox(
            top,
            textvariable=self.path_var,
            values=[
                "devices",
                "devices/{id}",
                "devices/{id}/all/3600",
                "devices/{id}/all/86400",
                "devices/{id}/all/604800",
            ],
            width=55,
            state="normal",
        )
        self.path_combo.grid(row=2, column=1, columnspan=2, sticky="ew", pady=(0, 8))

        ttk.Label(top, text="Device ID:").grid(row=3, column=0, sticky="w", padx=(0, 10), pady=(0, 8))
        self.device_id_var = tk.StringVar()
        self.device_combo = ttk.Combobox(top, textvariable=self.device_id_var, width=28, state="normal")
        self.device_combo.grid(row=3, column=1, sticky="ew", pady=(0, 8))

        ttk.Label(top, text="Initial EXP:").grid(row=4, column=0, sticky="w", padx=(0, 10), pady=(0, 8))
        self.initial_values_var = tk.StringVar(value="")
        exp_row = ttk.Frame(top)
        exp_row.grid(row=4, column=1, columnspan=2, sticky="ew", pady=(0, 8))
        exp_row.columnconfigure(1, weight=1)
        ttk.Button(exp_row, text="Select sensors...", command=self.on_select_sensors).grid(row=0, column=0, padx=(0, 8))
        ttk.Entry(exp_row, textvariable=self.initial_values_var, state="readonly").grid(row=0, column=1, sticky="ew")

        button_row = ttk.Frame(top)
        button_row.grid(row=5, column=0, columnspan=3, sticky="ew", pady=(8, 12))
        button_row.columnconfigure((0, 1, 2, 3, 4), weight=1)

        ttk.Button(button_row, text="Refresh", command=self.on_refresh_devices).grid(row=0, column=0, sticky="ew", padx=(0, 6))
        ttk.Button(button_row, text="Get Data", command=self.on_get_data).grid(row=0, column=1, sticky="ew", padx=6)
        ttk.Button(button_row, text="Create", command=self.on_create_device).grid(row=0, column=2, sticky="ew", padx=6)
        ttk.Button(button_row, text="Headers", command=self.on_show_headers).grid(row=0, column=3, sticky="ew", padx=6)
        ttk.Button(button_row, text="Clear", command=self.on_clear_output).grid(row=0, column=4, sticky="ew", padx=(6, 0))

        output_frame = ttk.LabelFrame(top, text="Output")
        output_frame.grid(row=6, column=0, columnspan=3, sticky="nsew")
        output_frame.columnconfigure(0, weight=1)
        output_frame.rowconfigure(0, weight=1)

        self.output_widget = tk.Text(output_frame, wrap="none", font=("Consolas", 10), height=24)
        self.output_widget.grid(row=0, column=0, sticky="nsew", padx=8, pady=8)

        scrollbar_y = ttk.Scrollbar(output_frame, orient="vertical", command=self.output_widget.yview)
        scrollbar_y.grid(row=0, column=1, sticky="ns", pady=8)
        scrollbar_x = ttk.Scrollbar(output_frame, orient="horizontal", command=self.output_widget.xview)
        scrollbar_x.grid(row=1, column=0, sticky="ew", padx=(8, 0))
        self.output_widget.config(yscrollcommand=scrollbar_y.set, xscrollcommand=scrollbar_x.set)

        status_bar = ttk.Frame(top)
        status_bar.grid(row=7, column=0, columnspan=3, sticky="ew", pady=(10, 0))
        status_bar.columnconfigure(0, weight=1)
        ttk.Label(status_bar, textvariable=self.status_var).grid(row=0, column=0, sticky="w")

        footer = tk.Frame(self)
        footer.pack(fill="x", padx=15, pady=(0, 6))

        version_label = tk.Label(
            footer,
            text="Version 1.4.5",
            font=("Segoe UI", 8),
            fg="#000000",
            anchor="w",
        )
        version_label.grid(row=0, column=0, sticky="w")

        copyright_label = tk.Label(
            footer,
            text=f"Copyright (c) {time.strftime('%Y')}",
            font=("Segoe UI", 8),
            fg="#000000",
            anchor="center",
        )
        copyright_label.grid(row=0, column=1, sticky="ew")

        links = tk.Frame(footer)
        links.grid(row=0, column=2, sticky="e")

        don_link = tk.Label(
            links,
            text="Don Zalmrol",
            fg="#1a5ca5",
            font=("Segoe UI", 8, "underline"),
            cursor="hand2",
        )
        don_link.pack(side="left")
        don_link.bind("<Button-1>", lambda event: webbrowser.open("https://www.don-zalmrol.be"))

        tk.Label(links, text=" - ", font=("Segoe UI", 8), fg="#000000").pack(side="left")

        github_link = tk.Label(
            links,
            text="GitHub",
            fg="#1a5ca5",
            font=("Segoe UI", 8, "underline"),
            cursor="hand2",
        )
        github_link.pack(side="left")
        github_link.bind("<Button-1>", lambda event: webbrowser.open("https://github.com/DonZalmrol"))

        tk.Label(links, text=" - ", font=("Segoe UI", 8), fg="#000000").pack(side="left")

        uradmonitor_link = tk.Label(
            links,
            text="uRADMonitor",
            fg="#1a5ca5",
            font=("Segoe UI", 8, "underline"),
            cursor="hand2",
        )
        uradmonitor_link.pack(side="left")
        uradmonitor_link.bind("<Button-1>", lambda event: webbrowser.open("https://www.uradmonitor.com"))

        footer.grid_columnconfigure(0, weight=1)
        footer.grid_columnconfigure(1, weight=0)
        footer.grid_columnconfigure(2, weight=1)

        top.columnconfigure(1, weight=1)
        top.rowconfigure(6, weight=1)

        self._show_intro_text()

    def _toggle_user_key_visibility(self) -> None:
        self.user_hash_entry.configure(show="" if self.show_key_var.get() else "*")

    def _show_intro_text(self) -> None:
        text = (
            "Enter your User ID and User Key from the Dashboard API tab.\n\n"
            "Refresh loads device IDs for your account.\n"
            "Get Data retrieves the selected API path; {id} uses the selected Device ID.\n"
            "Create registers a new DIDAP device and keeps the assigned ID on the device list.\n"
            "Headers shows the resolved API headers with the User Key masked.\n\n"
            "Initial EXP: click Select sensors... to tick the sensor fields and enter their\n"
            "values for a new device. Field 01 (Unix timestamp) is mandatory and added\n"
            "automatically on every upload.\n"
        )
        self._set_output_text(text)

    def _set_output_text(self, text: str) -> None:
        self.output_widget.configure(state="normal")
        self.output_widget.delete("1.0", tk.END)
        self.output_widget.insert(tk.END, text)
        self.output_widget.configure(state="disabled")

    def _show_json(self, data: Any) -> None:
        self._set_output_text(json.dumps(data, indent=2, default=str))

    def _get_headers(self) -> Dict[str, str]:
        user_id = self.user_id_var.get().strip()
        user_hash = self.user_hash_var.get().strip()
        if not user_id or not user_hash:
            raise ValueError("Please enter both a User ID and a User Key.")
        return build_headers(user_id, user_hash)

    def _set_busy(self, busy: bool) -> None:
        self.task_running = busy
        self._set_buttons_state(self, "disabled" if busy else "normal")

    def _set_buttons_state(self, widget, state: str) -> None:
        for child in widget.winfo_children():
            if child.winfo_class() == "TButton":
                child.configure(state=state)
            self._set_buttons_state(child, state)

    def run_async(self, label: str, callback):
        def worker():
            try:
                result = callback()
                self.after(0, lambda: self._show_json(result))
            except Exception as exc:  # pragma: no cover
                self.after(0, lambda: self._set_output_text(f"ERROR: {exc}"))
            finally:
                self.after(0, lambda: self._set_busy(False))
                self.after(0, lambda: self.status_var.set("Done."))

        self.status_var.set(label)
        self._set_busy(True)
        threading.Thread(target=worker, daemon=True).start()

    def on_select_sensors(self) -> None:
        if self.task_running:
            return
        dialog = SensorSelectionDialog(self, self.initial_values_var.get())
        self.wait_window(dialog)
        if dialog.result is not None:
            self.initial_values_var.set(dialog.result)

    def on_refresh_devices(self) -> None:
        if self.task_running:
            return

        def task():
            headers = self._get_headers()
            data = request_json_or_text("GET", f"{self.base_uri}/devices", headers, timeout=30)
            if not isinstance(data, list):
                return {"result": data}

            ids = []
            for item in data:
                if isinstance(item, dict) and "id" in item:
                    ids.append(str(item["id"]))
            self.device_combo["values"] = ids
            if ids:
                self.device_id_var.set(ids[0])
            return {"LoadedDeviceIds": ids}

        self.run_async("Loading devices...", task)

    def on_get_data(self) -> None:
        if self.task_running:
            return

        def task():
            headers = self._get_headers()
            path = self.path_var.get().strip()
            if not path:
                raise ValueError("Please choose or enter a path.")

            replacement = self.device_id_var.get().strip()
            if "{id}" in path:
                if not replacement:
                    raise ValueError("Select or enter a Device ID for this path.")
                validate_device_id(replacement)
                path = path.replace("{id}", replacement)

            uri = f"{self.base_uri.rstrip('/')}/{path.strip('/')}"
            response = request_json_or_text("GET", uri, headers, timeout=30)
            return response

        self.run_async("Querying API...", task)

    def on_create_device(self) -> None:
        if self.task_running:
            return

        # Confirm first, letting the user edit the sensor selection and re-review before registering.
        while True:
            confirm = ConfirmCreateDialog(self, self.initial_values_var.get())
            self.wait_window(confirm)
            if confirm.result == "edit":
                sensor_dialog = SensorSelectionDialog(self, self.initial_values_var.get())
                self.wait_window(sensor_dialog)
                if sensor_dialog.result is not None:
                    self.initial_values_var.set(sensor_dialog.result)
                continue
            if confirm.result == "yes":
                break
            return

        def task():
            headers = self._get_headers()
            values = self.initial_values_var.get().strip()
            validate_initial_values(values)

            result = register_new_device(
                headers,
                self.base_uri,
                registration_id="13000000",
                initial_values=values,
                timeout=30,
            )

            if result.get("NewDeviceId"):
                device_id = result["NewDeviceId"]
                current_ids = list(self.device_combo["values"])
                if device_id not in current_ids:
                    current_ids.append(device_id)
                    self.device_combo["values"] = current_ids
                self.device_id_var.set(device_id)
                try:
                    self.clipboard_clear()
                    self.clipboard_append(device_id)
                except Exception:
                    pass

            return result

        self.run_async("Registering device...", task)

    def on_show_headers(self) -> None:
        if self.task_running:
            return

        def task():
            headers = self._get_headers()
            masked = mask_user_hash(headers["X-User-hash"])
            return {
                "X-User-id": headers["X-User-id"],
                "X-User-hash": masked,
            }

        self.run_async("Building headers...", task)

    def on_clear_output(self) -> None:
        self._show_intro_text()

    @property
    def base_uri(self) -> str:
        return self._base_uri

    @base_uri.setter
    def base_uri(self, value: str) -> None:
        self._base_uri = (value or BASE_URI).rstrip("/")


def main() -> int:
    parser = argparse.ArgumentParser(description="uRADMonitor API helper GUI")
    parser.add_argument("--base-uri", default=BASE_URI, help="API base URI")
    args = parser.parse_args()

    app = UraDMonitorGui(base_uri=args.base_uri)
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
