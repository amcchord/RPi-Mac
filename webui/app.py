#!/usr/bin/env python3
"""RPi-Mac web control panel.

A small Flask application, styled after classic Mac OS, for managing the
Basilisk II emulator: prefs, disk images, ISOs, shared files, Bluetooth
pairing, WiFi and basic system actions.

Intentionally unsecured; meant for trusted local networks only.
"""

import os
import re
import subprocess
import time

from flask import (
    Flask,
    flash,
    redirect,
    render_template,
    request,
    send_from_directory,
    url_for,
)

APP_ROOT = os.path.dirname(os.path.abspath(__file__))

PREFS_PATH = "/home/mac/.basilisk_ii_prefs"
PREFS_DEFAULT = "/etc/rpimac/prefs.default"
PREFS_OWNER = "mac"
MAC_TXT = "/boot/firmware/mac.txt"
DISKS_DIR = "/opt/rpimac/disks"
ISOS_DIR = "/opt/rpimac/isos"
SHARED_DIR = "/opt/rpimac/shared"

DISK_EXTENSIONS = (".dsk", ".hfv", ".img", ".dmg")
ISO_EXTENSIONS = (".iso", ".toast", ".cdr")

app = Flask(__name__)
app.secret_key = "rpimac-not-a-secret"
app.config["MAX_CONTENT_LENGTH"] = 4 * 1024 * 1024 * 1024


# --------------------------------------------------------------- helpers ---

def run(cmd, timeout=30):
    """Run a command, return (exit_code, output)."""
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            text=True,
        )
        return proc.returncode, proc.stdout
    except subprocess.TimeoutExpired:
        return 124, "command timed out"
    except FileNotFoundError:
        return 127, "command not found: %s" % cmd[0]


def safe_name(name):
    """Reduce an uploaded filename to a safe basename."""
    base = os.path.basename(name.replace("\\", "/"))
    base = base.strip()
    base = re.sub(r"[^A-Za-z0-9 ._()-]", "_", base)
    return base


def human_size(num_bytes):
    size = float(num_bytes)
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024.0:
            return "%.1f %s" % (size, unit)
        size = size / 1024.0
    return "%.1f TB" % size


# ----------------------------------------------------------- prefs file ---

def ensure_prefs():
    if not os.path.exists(PREFS_PATH):
        with open(PREFS_DEFAULT) as src:
            content = src.read()
        with open(PREFS_PATH, "w") as dst:
            dst.write(content)
        run(["chown", "%s:%s" % (PREFS_OWNER, PREFS_OWNER), PREFS_PATH])


def read_prefs():
    """Return prefs as a list of (keyword, value) preserving order."""
    ensure_prefs()
    items = []
    with open(PREFS_PATH) as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line.strip():
                continue
            parts = line.split(" ", 1)
            keyword = parts[0]
            value = ""
            if len(parts) > 1:
                value = parts[1]
            items.append((keyword, value))
    return items


def write_prefs(items):
    lines = []
    for keyword, value in items:
        if value == "":
            lines.append(keyword)
        else:
            lines.append("%s %s" % (keyword, value))
    content = "\n".join(lines) + "\n"
    with open(PREFS_PATH, "w") as handle:
        handle.write(content)
    run(["chown", "%s:%s" % (PREFS_OWNER, PREFS_OWNER), PREFS_PATH])


def prefs_get(items, keyword, default=""):
    for key, value in items:
        if key == keyword:
            return value
    return default


def prefs_set(items, keyword, value):
    """Replace the first occurrence of keyword, or append."""
    for index, (key, _) in enumerate(items):
        if key == keyword:
            items[index] = (keyword, value)
            return
    items.append((keyword, value))


def prefs_values(items, keyword):
    values = []
    for key, value in items:
        if key == keyword:
            values.append(value)
    return values


def prefs_remove(items, keyword, value):
    kept = []
    for key, val in items:
        if key == keyword and val == value:
            continue
        kept.append((key, val))
    return kept


# -------------------------------------------------------------- mac.txt ---

def read_mac_txt():
    settings = {}
    if os.path.exists(MAC_TXT):
        with open(MAC_TXT) as handle:
            for line in handle:
                line = line.strip().rstrip("\r")
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    key, _, value = line.partition("=")
                    settings[key.strip()] = value.strip()
    return settings


def update_mac_txt(updates):
    """Update KEY=VALUE lines in mac.txt, preserving comments/layout."""
    lines = []
    if os.path.exists(MAC_TXT):
        with open(MAC_TXT) as handle:
            lines = handle.read().splitlines()
    seen = set()
    new_lines = []
    for line in lines:
        stripped = line.strip().rstrip("\r")
        replaced = False
        for key, value in updates.items():
            if stripped.startswith(key + "="):
                new_lines.append("%s=%s" % (key, value))
                seen.add(key)
                replaced = True
                break
        if not replaced:
            new_lines.append(line)
    for key, value in updates.items():
        if key not in seen:
            new_lines.append("%s=%s" % (key, value))
    with open(MAC_TXT, "w") as handle:
        handle.write("\n".join(new_lines) + "\n")


# ------------------------------------------------------------ dashboard ---

@app.context_processor
def inject_globals():
    code, state = run(["systemctl", "is-active", "basilisk"])
    return {"emulator_running": state.strip() == "active"}


@app.route("/")
def index():
    info = {}
    code, out = run(["hostname", "-I"])
    info["ip_addresses"] = out.strip()
    code, out = run(["uptime", "-p"])
    info["uptime"] = out.strip()
    code, out = run(["systemctl", "is-active", "basilisk"])
    info["emulator_state"] = out.strip()

    mem_total = ""
    mem_available = ""
    with open("/proc/meminfo") as handle:
        for line in handle:
            if line.startswith("MemTotal:"):
                mem_total = human_size(int(line.split()[1]) * 1024)
            if line.startswith("MemAvailable:"):
                mem_available = human_size(int(line.split()[1]) * 1024)
    info["mem_total"] = mem_total
    info["mem_available"] = mem_available

    code, out = run(["df", "-h", "--output=avail", "/"])
    out_lines = out.strip().splitlines()
    info["disk_free"] = ""
    if len(out_lines) > 1:
        info["disk_free"] = out_lines[1].strip()

    return render_template("index.html", info=info)


@app.route("/system/<action>", methods=["POST"])
def system_action(action):
    if action == "restart-emulator":
        run(["systemctl", "restart", "basilisk"])
        flash("Emulator restarted.")
        return redirect(url_for("index"))
    if action == "reboot":
        run(["systemctl", "reboot", "--no-block"])
        flash("Rebooting...")
        return redirect(url_for("index"))
    if action == "shutdown":
        run(["systemctl", "poweroff", "--no-block"])
        flash("Shutting down...")
        return redirect(url_for("index"))
    flash("Unknown action.")
    return redirect(url_for("index"))


@app.route("/status.txt")
def status_text():
    code, out = run(["/usr/local/bin/rpimac-status"], timeout=60)
    return out, 200, {"Content-Type": "text/plain; charset=utf-8"}


# -------------------------------------------------------------- settings ---

RAM_CHOICES = (16, 32, 64, 128, 256)
SCREEN_CHOICES = ("512/384", "640/480", "800/600", "1024/768")


@app.route("/settings", methods=["GET", "POST"])
def settings():
    items = read_prefs()
    mac_settings = read_mac_txt()

    if request.method == "POST":
        ram_mb = request.form.get("ramsize", "64")
        try:
            ram_bytes = int(ram_mb) * 1024 * 1024
        except ValueError:
            ram_bytes = 64 * 1024 * 1024
        prefs_set(items, "ramsize", str(ram_bytes))

        screen = request.form.get("screen", "640/480")
        if re.fullmatch(r"\d+/\d+", screen):
            prefs_set(items, "screen", "dga/" + screen)

        frameskip = request.form.get("frameskip", "0")
        if frameskip.isdigit():
            prefs_set(items, "frameskip", frameskip)

        if request.form.get("sound") == "on":
            prefs_set(items, "nosound", "false")
        else:
            prefs_set(items, "nosound", "true")

        if request.form.get("idlewait") == "on":
            prefs_set(items, "idlewait", "true")
        else:
            prefs_set(items, "idlewait", "false")

        write_prefs(items)

        display_kind = request.form.get("display", "hdmi")
        display_changed = False
        if display_kind in ("hdmi", "dpi28"):
            current = mac_settings.get("DISPLAY", "hdmi")
            if current != display_kind:
                update_mac_txt({"DISPLAY": display_kind})
                display_changed = True

        if request.form.get("apply_now") == "on":
            run(["systemctl", "restart", "basilisk"])
            flash("Settings saved and emulator restarted.")
        else:
            flash("Settings saved. Restart the emulator to apply.")
        if display_changed:
            flash(
                "Display type changed - it will be applied on the next "
                "reboot (the Pi reboots once more automatically to switch)."
            )
        return redirect(url_for("settings"))

    ram_bytes = prefs_get(items, "ramsize", "67108864")
    try:
        ram_mb = int(ram_bytes) // (1024 * 1024)
    except ValueError:
        ram_mb = 64
    screen = prefs_get(items, "screen", "dga/640/480")
    screen_res = re.sub(r"^[a-z]+/", "", screen)

    current = {
        "ram_mb": ram_mb,
        "screen": screen_res,
        "frameskip": prefs_get(items, "frameskip", "0"),
        "sound_on": prefs_get(items, "nosound", "false") != "true",
        "idlewait_on": prefs_get(items, "idlewait", "true") == "true",
        "display": mac_settings.get("DISPLAY", "hdmi"),
        "rom": prefs_get(items, "rom", ""),
    }
    return render_template(
        "settings.html",
        current=current,
        ram_choices=RAM_CHOICES,
        screen_choices=SCREEN_CHOICES,
    )


# ----------------------------------------------------------------- disks ---

def list_images(directory, extensions, attached):
    entries = []
    if os.path.isdir(directory):
        for name in sorted(os.listdir(directory)):
            path = os.path.join(directory, name)
            if not os.path.isfile(path):
                continue
            if not name.lower().endswith(extensions):
                continue
            entries.append(
                {
                    "name": name,
                    "path": path,
                    "size": human_size(os.path.getsize(path)),
                    "attached": path in attached,
                }
            )
    return entries


@app.route("/disks")
def disks():
    items = read_prefs()
    attached_disks = prefs_values(items, "disk")
    attached_cdroms = prefs_values(items, "cdrom")
    disk_entries = list_images(DISKS_DIR, DISK_EXTENSIONS, attached_disks)
    iso_entries = list_images(ISOS_DIR, ISO_EXTENSIONS, attached_cdroms)
    return render_template(
        "disks.html", disks=disk_entries, isos=iso_entries
    )


@app.route("/disks/upload", methods=["POST"])
def disks_upload():
    kind = request.form.get("kind", "disk")
    upload = request.files.get("file")
    if upload is None or upload.filename == "":
        flash("No file selected.")
        return redirect(url_for("disks"))
    name = safe_name(upload.filename)
    if kind == "iso":
        directory = ISOS_DIR
    else:
        directory = DISKS_DIR
    dest = os.path.join(directory, name)
    upload.save(dest)
    run(["chown", "mac:mac", dest])
    flash("Uploaded %s." % name)
    return redirect(url_for("disks"))


@app.route("/disks/create", methods=["POST"])
def disks_create():
    name = safe_name(request.form.get("name", ""))
    size_mb_raw = request.form.get("size_mb", "100")
    if not name:
        flash("Disk name required.")
        return redirect(url_for("disks"))
    if not name.lower().endswith(DISK_EXTENSIONS):
        name = name + ".dsk"
    try:
        size_mb = int(size_mb_raw)
    except ValueError:
        size_mb = 100
    size_mb = max(1, min(size_mb, 2000))
    dest = os.path.join(DISKS_DIR, name)
    if os.path.exists(dest):
        flash("A disk named %s already exists." % name)
        return redirect(url_for("disks"))
    with open(dest, "wb") as handle:
        handle.truncate(size_mb * 1024 * 1024)
    run(["chown", "mac:mac", dest])
    items = read_prefs()
    items.append(("disk", dest))
    write_prefs(items)
    flash(
        "Created blank %d MB disk %s and attached it. Restart the emulator, "
        "then initialize the disk inside Mac OS." % (size_mb, name)
    )
    return redirect(url_for("disks"))


@app.route("/disks/attach", methods=["POST"])
def disks_attach():
    kind = request.form.get("kind", "disk")
    name = safe_name(request.form.get("name", ""))
    if kind == "iso":
        directory = ISOS_DIR
        keyword = "cdrom"
    else:
        directory = DISKS_DIR
        keyword = "disk"
    path = os.path.join(directory, name)
    if not os.path.isfile(path):
        flash("File not found.")
        return redirect(url_for("disks"))
    items = read_prefs()
    if path in prefs_values(items, keyword):
        flash("%s is already attached." % name)
        return redirect(url_for("disks"))
    items.append((keyword, path))
    write_prefs(items)
    flash("Attached %s. Restart the emulator to apply." % name)
    return redirect(url_for("disks"))


@app.route("/disks/detach", methods=["POST"])
def disks_detach():
    kind = request.form.get("kind", "disk")
    name = safe_name(request.form.get("name", ""))
    if kind == "iso":
        directory = ISOS_DIR
        keyword = "cdrom"
    else:
        directory = DISKS_DIR
        keyword = "disk"
    path = os.path.join(directory, name)
    items = read_prefs()
    items = prefs_remove(items, keyword, path)
    write_prefs(items)
    flash("Detached %s. Restart the emulator to apply." % name)
    return redirect(url_for("disks"))


@app.route("/disks/delete", methods=["POST"])
def disks_delete():
    kind = request.form.get("kind", "disk")
    name = safe_name(request.form.get("name", ""))
    if kind == "iso":
        directory = ISOS_DIR
        keyword = "cdrom"
    else:
        directory = DISKS_DIR
        keyword = "disk"
    path = os.path.join(directory, name)
    items = read_prefs()
    if path in prefs_values(items, keyword):
        flash("Detach %s before deleting it." % name)
        return redirect(url_for("disks"))
    if os.path.isfile(path):
        os.remove(path)
        flash("Deleted %s." % name)
    return redirect(url_for("disks"))


# ---------------------------------------------------------- shared files ---

@app.route("/files")
def files():
    entries = []
    if os.path.isdir(SHARED_DIR):
        for name in sorted(os.listdir(SHARED_DIR)):
            path = os.path.join(SHARED_DIR, name)
            entry = {"name": name, "is_dir": os.path.isdir(path)}
            if os.path.isfile(path):
                entry["size"] = human_size(os.path.getsize(path))
            else:
                entry["size"] = ""
            entries.append(entry)
    return render_template("files.html", entries=entries)


@app.route("/files/upload", methods=["POST"])
def files_upload():
    upload = request.files.get("file")
    if upload is None or upload.filename == "":
        flash("No file selected.")
        return redirect(url_for("files"))
    name = safe_name(upload.filename)
    dest = os.path.join(SHARED_DIR, name)
    upload.save(dest)
    run(["chown", "mac:mac", dest])
    flash("Uploaded %s to the shared folder." % name)
    return redirect(url_for("files"))


@app.route("/files/delete", methods=["POST"])
def files_delete():
    name = safe_name(request.form.get("name", ""))
    path = os.path.join(SHARED_DIR, name)
    if os.path.isfile(path):
        os.remove(path)
        flash("Deleted %s." % name)
    return redirect(url_for("files"))


@app.route("/files/download/<path:name>")
def files_download(name):
    return send_from_directory(
        SHARED_DIR, safe_name(name), as_attachment=True
    )


# -------------------------------------------------------------- bluetooth ---

def bluetoothctl_devices(args):
    devices = []
    code, out = run(["bluetoothctl", "devices"] + args)
    if code != 0:
        return devices
    for line in out.splitlines():
        match = re.match(r"Device ([0-9A-F:]{17}) (.*)", line)
        if match:
            devices.append({"addr": match.group(1), "name": match.group(2)})
    return devices


@app.route("/bluetooth")
def bluetooth():
    paired = bluetoothctl_devices(["Paired"])
    if not paired:
        paired = bluetoothctl_devices(["Trusted"])
    connected = bluetoothctl_devices(["Connected"])
    connected_addrs = set()
    for device in connected:
        connected_addrs.add(device["addr"])
    for device in paired:
        device["connected"] = device["addr"] in connected_addrs
    return render_template(
        "bluetooth.html", paired=paired, discovered=None
    )


@app.route("/bluetooth/scan", methods=["POST"])
def bluetooth_scan():
    run(["bluetoothctl", "power", "on"])
    run(["bluetoothctl", "--timeout", "12", "scan", "on"], timeout=30)
    paired = bluetoothctl_devices(["Paired"])
    paired_addrs = set()
    for device in paired:
        paired_addrs.add(device["addr"])
    connected = bluetoothctl_devices(["Connected"])
    connected_addrs = set()
    for device in connected:
        connected_addrs.add(device["addr"])
    for device in paired:
        device["connected"] = device["addr"] in connected_addrs
    discovered = []
    for device in bluetoothctl_devices([]):
        if device["addr"] not in paired_addrs:
            discovered.append(device)
    return render_template(
        "bluetooth.html", paired=paired, discovered=discovered
    )


@app.route("/bluetooth/pair", methods=["POST"])
def bluetooth_pair():
    addr = request.form.get("addr", "")
    if not re.fullmatch(r"[0-9A-F:]{17}", addr):
        flash("Bad device address.")
        return redirect(url_for("bluetooth"))
    run(["bluetoothctl", "power", "on"])
    run(["bluetoothctl", "agent", "NoInputNoOutput"])
    code, out = run(["bluetoothctl", "--timeout", "30", "pair", addr], timeout=45)
    run(["bluetoothctl", "trust", addr])
    code2, out2 = run(["bluetoothctl", "--timeout", "15", "connect", addr], timeout=30)
    if "successful" in out or "successful" in out2 or code2 == 0:
        flash("Paired and connected %s." % addr)
    else:
        flash("Pairing attempted; check the device. (%s)" % out.strip()[-120:])
    return redirect(url_for("bluetooth"))


@app.route("/bluetooth/connect", methods=["POST"])
def bluetooth_connect():
    addr = request.form.get("addr", "")
    if re.fullmatch(r"[0-9A-F:]{17}", addr):
        run(["bluetoothctl", "--timeout", "15", "connect", addr], timeout=30)
        flash("Connect requested for %s." % addr)
    return redirect(url_for("bluetooth"))


@app.route("/bluetooth/remove", methods=["POST"])
def bluetooth_remove():
    addr = request.form.get("addr", "")
    if re.fullmatch(r"[0-9A-F:]{17}", addr):
        run(["bluetoothctl", "remove", addr])
        flash("Removed %s." % addr)
    return redirect(url_for("bluetooth"))


# ------------------------------------------------------------------ wifi ---

@app.route("/wifi", methods=["GET", "POST"])
def wifi():
    if request.method == "POST":
        ssid = request.form.get("ssid", "").strip()
        password = request.form.get("password", "")
        country = request.form.get("country", "US").strip().upper()
        if not ssid:
            flash("Network name required.")
            return redirect(url_for("wifi"))
        updates = {"WIFI_SSID": ssid, "WIFI_PASS": password}
        if re.fullmatch(r"[A-Z]{2}", country):
            updates["WIFI_COUNTRY"] = country
        update_mac_txt(updates)
        run(["/usr/local/bin/rpimac-boot-config"], timeout=60)
        run(["nmcli", "connection", "up", "rpimac-wifi"], timeout=60)
        flash("WiFi settings saved and applied.")
        return redirect(url_for("wifi"))

    mac_settings = read_mac_txt()
    status = {"ssid": mac_settings.get("WIFI_SSID", "")}
    code, out = run(["nmcli", "-t", "-f", "NAME,DEVICE", "connection", "show", "--active"])
    status["active"] = out.strip()
    code, out = run(["hostname", "-I"])
    status["ip"] = out.strip()
    status["country"] = mac_settings.get("WIFI_COUNTRY", "US")
    return render_template("wifi.html", status=status)


if __name__ == "__main__":
    for directory in (DISKS_DIR, ISOS_DIR, SHARED_DIR):
        os.makedirs(directory, exist_ok=True)
    from waitress import serve

    serve(app, host="0.0.0.0", port=80, threads=4)
