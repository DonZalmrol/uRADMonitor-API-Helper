#!/usr/bin/env python3
"""Tkinter GUI for the uRADMonitor API helper.

This mirrors the core PowerShell helper behavior in a desktop window:
- build U-User authentication headers
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
SUPPORTED_SENSOR_IDS = {
    "02", "03", "04", "05", "06", "07", "08", "09",
    "0A", "0B", "0C", "0D", "0E", "0F", "10", "11",
    "12", "13", "14",
}


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
                f"Unsupported EXP sensor ID '{sensor_id}'. Use an ID from 02 through 14, excluding 01 which is added automatically."
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


def send_dummy_data(
    headers: Dict[str, str],
    base_uri: str,
    device_id: str,
    value: int = 0,
    timeout: int = 30,
) -> str:
    exp_headers = dict(headers)
    exp_headers["X-Device-id"] = str(device_id)

    payload = f"01/{int(time.time())}/02/{value}"
    uri = f"{base_uri.rstrip('/')}/upload/exp/{payload}"
    for attempt in range(1, 4):
        try:
            response = requests.post(uri, headers=exp_headers, timeout=timeout)
            response.raise_for_status()
            return response.text
        except requests.RequestException as exc:
            if attempt == 3:
                raise ApiError(f"Dummy upload failed: {get_error_detail(exc)}") from exc
            time.sleep(attempt)

    raise ApiError(f"Dummy upload failed for device '{device_id}'.")


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
        self.initial_values_var = tk.StringVar(value="02/0/03/0/04/0/07/0/09/0/0B/0")
        ttk.Entry(top, textvariable=self.initial_values_var, width=58).grid(row=4, column=1, columnspan=2, sticky="ew", pady=(0, 8))

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
        footer.grid_columnconfigure(0, weight=1)

        footer_text = tk.Label(
            footer,
            text="Version 1.4.5 - Copyright 2026 ",
            font=("Segoe UI", 8),
            fg="#000000",
            anchor="center",
        )
        footer_text.grid(row=0, column=0, sticky="nsew")

        don_link = tk.Label(
            footer,
            text="Don Zalmrol",
            fg="#1a5ca5",
            font=("Segoe UI", 8, "underline"),
            cursor="hand2",
            anchor="center",
        )
        don_link.grid(row=0, column=1, sticky="nsew")
        don_link.bind("<Button-1>", lambda event: webbrowser.open("https://www.don-zalmrol.be"))

        dash = tk.Label(footer, text=" - ", font=("Segoe UI", 8), fg="#000000", anchor="center")
        dash.grid(row=0, column=2, sticky="nsew")

        github_link = tk.Label(
            footer,
            text="GitHub",
            fg="#1a5ca5",
            font=("Segoe UI", 8, "underline"),
            cursor="hand2",
            anchor="center",
        )
        github_link.grid(row=0, column=3, sticky="nsew")
        github_link.bind("<Button-1>", lambda event: webbrowser.open("https://github.com/DonZalmrol"))

        footer.grid_columnconfigure(0, weight=1)
        footer.grid_columnconfigure(1, weight=0)
        footer.grid_columnconfigure(2, weight=0)
        footer.grid_columnconfigure(3, weight=0)

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
            "Initial EXP: 02/0 = temperature, 03/0 = pressure, 04/0 = humidity,\n"
            "             07/0 = CO2, 09/0 = PM2.5, 0B/0 = radiation.\n"
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
        for child in self.winfo_children():
            if child.winfo_class() == "TButton":
                child.configure(state="disabled" if busy else "normal")

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

        if messagebox.askyesno("Create Device", "Register a new device on your uRADMonitor account?"):
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
    parser.add_argument("--gui", action="store_true", help="Open the desktop GUI")
    parser.add_argument("--base-uri", default=BASE_URI, help="API base URI")
    args = parser.parse_args()

    app = UraDMonitorGui(base_uri=args.base_uri)
    app.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
