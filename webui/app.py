#!/usr/bin/env python3
"""RPi-Mac web control panel.

A small Flask application, styled after classic Mac OS, for managing the
Basilisk II emulator: prefs, disk images, ISOs, shared files, Bluetooth
pairing, WiFi and basic system actions.

Intentionally unsecured; meant for trusted local networks only.
"""

import glob
import os
import re
import struct
import subprocess
import threading
import time
import zipfile
import zlib

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
ZIPS_DIR = "/opt/rpimac/zips"
ISOS_DIR = "/opt/rpimac/isos"
SHARED_DIR = "/opt/rpimac/shared"

# Windows mode (DOSBox-X) paths
WIN98_DIR = "/opt/rpimac/win98"
WIN98_HDD = "/opt/rpimac/win98/hdd.vhd"
WIN98_ISOS_DIR = "/opt/rpimac/win98/isos"
WIN98_SHARED_DIR = "/opt/rpimac/win98/shared"
WIN98_CDROM_FILE = "/opt/rpimac/win98/cdrom"
WIN98_ZIP = "/opt/rpimac/zips/Win98.vhd.zip"
DOSBOX_BIN = "/usr/local/bin/dosbox-x"
EXPAND_WIN98 = "/usr/local/bin/rpimac-expand-win98"

# The systemd unit that runs whichever emulator MODE selects.
EMULATOR_UNIT = "rpimac-emulator"

DISK_EXTENSIONS = (".dsk", ".hfv", ".img", ".dmg")
ISO_EXTENSIONS = (".iso", ".toast", ".cdr")

# Captive portal: while the "RPi-Mac Setup" hotspot is up, rpimac-wifi-fallback
# creates this marker and the AP's dnsmasq resolves every name to the gateway.
# A joining device's OS connectivity check (captive.apple.com, generate_204,
# msftconnecttest, ...) then lands here with a foreign Host header; we redirect
# it to the setup page so the user never needs the 10.42.0.1 address.
HOTSPOT_MARKER = "/run/rpimac-hotspot"
AP_GATEWAY = "10.42.0.1"
CAPTIVE_PORTAL_URL = "http://%s/wifi" % AP_GATEWAY
CAPTIVE_LOCAL_HOSTS = {AP_GATEWAY, "rpimac.local", "rpimac", "localhost", "127.0.0.1"}

app = Flask(__name__)
app.secret_key = "rpimac-not-a-secret"
app.config["MAX_CONTENT_LENGTH"] = 4 * 1024 * 1024 * 1024


@app.before_request
def captive_portal_redirect():
    """When the setup hotspot is up, act as a captive portal: redirect any
    request for a foreign host (the OS connectivity-check probes, since the
    AP's DNS points everything at us) to the WiFi setup page. Gated on the
    hotspot marker so normal access via rpimac.local / LAN IP is untouched."""
    if not os.path.exists(HOTSPOT_MARKER):
        return None
    host = (request.host or "").split(":")[0].lower()
    if host in CAPTIVE_LOCAL_HOSTS:
        return None
    return redirect(CAPTIVE_PORTAL_URL, code=302)


@app.before_request
def optional_password_gate():
    """If WEBUI_PASS is set in mac.txt, require it via HTTP basic auth.
    Default is no password (hobbyist-friendly). Locked out? Edit mac.txt
    on the SD card's boot partition from any computer."""
    password = read_mac_txt().get("WEBUI_PASS", "")
    if not password:
        return None
    auth = request.authorization
    if auth is not None and auth.password == password:
        return None
    return (
        "Password required",
        401,
        {"WWW-Authenticate": 'Basic realm="RPi-Mac"'},
    )


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
    # Atomic write so a power cut can't leave a truncated prefs file
    tmp_path = PREFS_PATH + ".tmp"
    with open(tmp_path, "w") as handle:
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp_path, PREFS_PATH)
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


def same_file(path_a, path_b):
    """Compare two paths robustly (symlinks, trailing spaces, // etc)."""
    norm_a = os.path.realpath(path_a.strip())
    norm_b = os.path.realpath(path_b.strip())
    return norm_a == norm_b


def prefs_has_file(items, keyword, path):
    for value in prefs_values(items, keyword):
        if same_file(value, path):
            return True
    return False


def prefs_remove(items, keyword, value):
    kept = []
    for key, val in items:
        if key == keyword and same_file(val, value):
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


# ---------------------------------------------------------------- mode ---

def current_mode():
    """Active emulator mode: 'win' (DOSBox-X / Windows 98) or 'mac' (the
    default classic Macintosh). Single source of truth is MODE in mac.txt."""
    value = read_mac_txt().get("MODE", "mac").strip().lower()
    if value in ("win", "windows", "win98"):
        return "win"
    return "mac"


def win_payload_present():
    """True when this image actually carries the Windows mode payload, so the
    UI only offers the toggle when there is something to switch to."""
    if os.path.exists(DOSBOX_BIN):
        return True
    if os.path.exists(WIN98_HDD) or os.path.exists(WIN98_ZIP):
        return True
    return False


# ------------------------------------------------------------ dashboard ---

@app.context_processor
def inject_globals():
    code, state = run(["systemctl", "is-active", EMULATOR_UNIT])
    mode = current_mode()
    if mode == "win":
        machine_name = "Windows 98"
    else:
        machine_name = "Macintosh"
    return {
        "emulator_running": state.strip() == "active",
        "mode": mode,
        "machine_name": machine_name,
        "win_available": win_payload_present(),
    }


@app.route("/")
def index():
    info = {}
    code, out = run(["hostname", "-I"])
    info["ip_addresses"] = out.strip()
    code, out = run(["uptime", "-p"])
    info["uptime"] = out.strip()
    code, out = run(["systemctl", "is-active", EMULATOR_UNIT])
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
        run(["systemctl", "restart", EMULATOR_UNIT])
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
SCREEN_CHOICES = ("512/384", "640/480", "800/600", "960/540", "1024/768", "1920/1080")
CPU_CHOICES = (("2", "68020"), ("3", "68030"), ("4", "68040"))
# Gestalt model IDs minus 6. The Quadra 650 matches the bundled ROM and is
# required for Mac OS 8.x; the IIci is the classic safe choice for System 7.
MODEL_CHOICES = (
    ("30", "Quadra 650 (Mac OS 8 capable)"),
    ("14", "Quadra 900"),
    ("5", "Mac IIci (System 7 era)"),
)
ROTATE_CHOICES = ("auto", "0", "90", "180", "270")


def hdmi_screen_choices():
    """Native HDMI mode (and exactly half) read from KMS/DRM sysfs, so the
    dropdown can offer the attached display's resolution. Returns a list of
    "W/H" strings; empty when no HDMI display is connected."""
    choices = []
    for status_path in glob.glob("/sys/class/drm/card*-HDMI-A-*/status"):
        try:
            with open(status_path) as fh:
                if fh.read().strip() != "connected":
                    continue
            modes_path = os.path.join(os.path.dirname(status_path), "modes")
            with open(modes_path) as fh:
                for line in fh:
                    match = re.match(r"(\d+)x(\d+)", line.strip())
                    if match:
                        w, h = int(match.group(1)), int(match.group(2))
                        choices.append("%d/%d" % (w, h))
                        choices.append("%d/%d" % (w // 2, h // 2))
                        break
        except OSError:
            continue
    return choices


def apply_display_settings(mac_settings):
    """Apply DISPLAY/ROTATE from the settings form. Shared by both modes -
    the display pipeline (config.txt/cmdline/KMS rotation) is identical for
    Basilisk and DOSBox-X. Triggers the one-shot reboot via rpimac-boot-config
    only when the firmware configuration actually changes."""
    display_changed = False
    display_kind = request.form.get("display", "hdmi")
    if display_kind in ("hdmi", "dpi28"):
        if mac_settings.get("DISPLAY", "hdmi") != display_kind:
            update_mac_txt({"DISPLAY": display_kind})
            display_changed = True
    rotate = request.form.get("rotate", "auto")
    if rotate in ROTATE_CHOICES:
        current_rotate = mac_settings.get("ROTATE", "")
        new_rotate = rotate
        if rotate == "auto":
            new_rotate = ""
        if current_rotate != new_rotate:
            update_mac_txt({"ROTATE": new_rotate})
            display_changed = True
    if display_changed:
        flash("Display/rotation changed - the Pi will reboot once to apply it.")
        run(["/usr/local/bin/rpimac-boot-config"], timeout=120)


def apply_access_settings(mac_settings):
    """Apply the SSH toggle and optional web UI password. Shared by both
    modes (these live in mac.txt, not the emulator prefs)."""
    ssh_wanted = request.form.get("ssh") == "on"
    ssh_now = mac_settings.get("SSH", "1") != "0"
    if ssh_wanted != ssh_now:
        if ssh_wanted:
            update_mac_txt({"SSH": "1"})
            run(["systemctl", "enable", "--now", "ssh"])
            flash("SSH enabled.")
        else:
            update_mac_txt({"SSH": "0"})
            run(["systemctl", "disable", "--now", "ssh"])
            flash("SSH disabled.")
    new_pass = request.form.get("webui_pass", None)
    if new_pass is not None:
        current_pass = mac_settings.get("WEBUI_PASS", "")
        if new_pass != current_pass:
            update_mac_txt({"WEBUI_PASS": new_pass})
            if new_pass:
                flash(
                    "Web UI password set. You will be asked for it on the "
                    "next page load (any username). To recover from a lost "
                    "password, edit WEBUI_PASS in mac.txt on the SD card."
                )
            else:
                flash("Web UI password removed.")


@app.route("/settings/mode", methods=["POST"])
def settings_mode():
    """Switch between Mac and Windows mode. Writes MODE to mac.txt, expands the
    Windows disk on first switch, and restarts the emulator unit (no reboot -
    both modes share the same display pipeline)."""
    requested = request.form.get("mode", "mac").strip().lower()
    if requested in ("win", "windows", "win98"):
        requested = "win"
    else:
        requested = "mac"

    if requested == "win" and not win_payload_present():
        flash("Windows mode is not installed on this image.")
        return redirect(url_for("settings"))

    if requested == current_mode():
        flash("Already in %s mode." % requested)
        return redirect(url_for("settings"))

    update_mac_txt({"MODE": requested})
    if requested == "win":
        # Materialise the disk now (it may take a minute) so the emulator has
        # something to boot the moment it restarts.
        if not os.path.exists(WIN98_HDD) and os.path.exists(EXPAND_WIN98):
            run([EXPAND_WIN98], timeout=1800)
        flash("Switched to Windows 98. Starting DOSBox-X...")
    else:
        flash("Switched to Mac. Starting Basilisk II...")
    run(["systemctl", "restart", EMULATOR_UNIT])
    return redirect(url_for("settings"))


@app.route("/settings", methods=["GET", "POST"])
def settings():
    items = read_prefs()
    mac_settings = read_mac_txt()

    if request.method == "POST":
        # Windows mode has no Basilisk prefs; only the shared display/access
        # settings apply. Skip the Mac-only prefs block entirely so saving
        # Windows settings never rewrites the Mac prefs with defaults.
        if current_mode() == "win":
            apply_display_settings(mac_settings)
            apply_access_settings(mac_settings)
            if request.form.get("apply_now") == "on":
                run(["systemctl", "restart", EMULATOR_UNIT])
                flash("Settings saved and Windows restarted.")
            else:
                flash("Settings saved. Restart Windows to apply.")
            return redirect(url_for("settings"))

        ram_mb = request.form.get("ramsize", "64")
        try:
            ram_bytes = int(ram_mb) * 1024 * 1024
        except ValueError:
            ram_bytes = 64 * 1024 * 1024
        prefs_set(items, "ramsize", str(ram_bytes))

        # Screen size, shrunk by the display margins (for panels whose
        # edges are physically covered by a bezel or enclosure)
        margins = []
        for side in ("margin_l", "margin_r", "margin_t", "margin_b"):
            raw = request.form.get(side, "0").strip()
            value = 0
            if raw.isdigit():
                value = min(int(raw), 200)
            margins.append(value)
        ml, mr, mt, mb = margins

        screen = request.form.get("screen", "640/480")
        if re.fullmatch(r"\d+/\d+", screen):
            base_w, base_h = [int(part) for part in screen.split("/")]
            eff_w = max(base_w - ml - mr, 64)
            eff_h = max(base_h - mt - mb, 64)
            prefs_set(items, "screen", "dga/%d/%d" % (eff_w, eff_h))
            prefs_set(items, "sdloffsetx", str((ml - mr) // 2))
            prefs_set(items, "sdloffsety", str((mt - mb) // 2))
            update_mac_txt(
                {
                    "MARGINS": "%d,%d,%d,%d" % (ml, mr, mt, mb),
                    "SCREEN_BASE": screen,
                }
            )

        frameskip = request.form.get("frameskip", "0")
        if frameskip.isdigit():
            prefs_set(items, "frameskip", frameskip)

        cpu = request.form.get("cpu", "4")
        if cpu in ("2", "3", "4"):
            prefs_set(items, "cpu", cpu)
            if cpu == "4":
                prefs_set(items, "fpu", "true")

        model = request.form.get("modelid", "")
        valid_models = []
        for value, _label in MODEL_CHOICES:
            valid_models.append(value)
        if model in valid_models:
            prefs_set(items, "modelid", model)

        if request.form.get("sound") == "on":
            prefs_set(items, "nosound", "false")
        else:
            prefs_set(items, "nosound", "true")

        if request.form.get("idlewait") == "on":
            prefs_set(items, "idlewait", "true")
        else:
            prefs_set(items, "idlewait", "false")

        # Shared folder: an "extfs" line mounts /opt/rpimac/shared as the
        # "Unix" volume on the Mac desktop
        has_extfs = len(prefs_values(items, "extfs")) > 0
        if request.form.get("shared_folder") == "on":
            if not has_extfs:
                items.append(("extfs", SHARED_DIR))
        else:
            if has_extfs:
                items = [i for i in items if i[0] != "extfs"]

        # Networking: slirp gives the Mac user-mode NAT internet access
        # (configure TCP/IP in the Mac with DHCP)
        has_ether = len(prefs_values(items, "ether")) > 0
        if request.form.get("network") == "on":
            if not has_ether:
                items.append(("ether", "slirp"))
        else:
            if has_ether:
                items = [i for i in items if i[0] != "ether"]

        write_prefs(items)

        apply_display_settings(mac_settings)
        apply_access_settings(mac_settings)

        if request.form.get("apply_now") == "on":
            run(["systemctl", "restart", EMULATOR_UNIT])
            flash("Settings saved and emulator restarted.")
        else:
            flash("Settings saved. Restart the emulator to apply.")
        return redirect(url_for("settings"))

    ram_bytes = prefs_get(items, "ramsize", "67108864")
    try:
        ram_mb = int(ram_bytes) // (1024 * 1024)
    except ValueError:
        ram_mb = 64
    # The settings form shows the BASE screen size; the prefs hold the
    # margin-reduced effective size
    screen_res = mac_settings.get("SCREEN_BASE", "")
    if not re.fullmatch(r"\d+/\d+", screen_res):
        screen = prefs_get(items, "screen", "dga/640/480")
        screen_res = re.sub(r"^[a-z]+/", "", screen)

    margins_raw = mac_settings.get("MARGINS", "0,0,0,0").split(",")
    margins = []
    for part in margins_raw:
        if part.strip().isdigit():
            margins.append(int(part))
        else:
            margins.append(0)
    while len(margins) < 4:
        margins.append(0)

    rotate_setting = mac_settings.get("ROTATE", "")
    if rotate_setting not in ("0", "90", "180", "270"):
        rotate_setting = "auto"

    merged = list(SCREEN_CHOICES) + hdmi_screen_choices() + [screen_res]
    screen_choices = sorted(
        set(merged), key=lambda s: [int(p) for p in s.split("/")]
    )

    current = {
        "ram_mb": ram_mb,
        "screen": screen_res,
        "frameskip": prefs_get(items, "frameskip", "0"),
        "cpu": prefs_get(items, "cpu", "4"),
        "modelid": prefs_get(items, "modelid", "30"),
        "sound_on": prefs_get(items, "nosound", "false") != "true",
        "idlewait_on": prefs_get(items, "idlewait", "true") == "true",
        "shared_on": len(prefs_values(items, "extfs")) > 0,
        "network_on": len(prefs_values(items, "ether")) > 0,
        "display": mac_settings.get("DISPLAY", "hdmi"),
        "rotate": rotate_setting,
        "rom": prefs_get(items, "rom", ""),
        "ssh_on": mac_settings.get("SSH", "1") != "0",
        "webui_pass": mac_settings.get("WEBUI_PASS", ""),
        "margins": margins,
    }
    return render_template(
        "settings.html",
        current=current,
        ram_choices=RAM_CHOICES,
        screen_choices=screen_choices,
        cpu_choices=CPU_CHOICES,
        model_choices=MODEL_CHOICES,
        rotate_choices=ROTATE_CHOICES,
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
            is_attached = False
            for value in attached:
                if same_file(value, path):
                    is_attached = True
                    break
            entries.append(
                {
                    "name": name,
                    "path": path,
                    "size": human_size(os.path.getsize(path)),
                    "attached": is_attached,
                }
            )
    return entries


# Zipped Mac OS disk images shipped on the card (in ZIPS_DIR) that the
# user can install on demand. Installing expands the zip into DISKS_DIR
# in a background thread, attaches the disk and deletes the zip.

ARCHIVE_LABELS = {
    "Mac7.dsk.zip": "Mac OS 7",
    "Mac8.dsk.zip": "Mac OS 8",
}

install_lock = threading.Lock()
install_jobs = {}


def archive_target_name(zip_name):
    return zip_name[: -len(".zip")]


def archive_label(zip_name):
    return ARCHIVE_LABELS.get(zip_name, archive_target_name(zip_name))


def list_archives():
    entries = []
    if not os.path.isdir(ZIPS_DIR):
        return entries
    for name in sorted(os.listdir(ZIPS_DIR)):
        if not name.lower().endswith(".dsk.zip"):
            continue
        path = os.path.join(ZIPS_DIR, name)
        if not os.path.isfile(path):
            continue
        try:
            with zipfile.ZipFile(path) as archive:
                expanded = sum(info.file_size for info in archive.infolist())
        except (OSError, zipfile.BadZipFile):
            continue
        with install_lock:
            job = dict(install_jobs.get(name, {}))
        entries.append(
            {
                "name": name,
                "label": archive_label(name),
                "target": archive_target_name(name),
                "size": human_size(os.path.getsize(path)),
                "expanded": human_size(expanded),
                "job": job,
            }
        )
    return entries


def install_archive_worker(name):
    path = os.path.join(ZIPS_DIR, name)
    target = os.path.join(DISKS_DIR, archive_target_name(name))
    part = target + ".part"

    def set_job(**fields):
        with install_lock:
            install_jobs.setdefault(name, {}).update(fields)

    try:
        with zipfile.ZipFile(path) as archive:
            members = []
            for member in archive.infolist():
                if not member.is_dir():
                    members.append(member)
            total = sum(member.file_size for member in members)
            done = 0
            with open(part, "wb") as out:
                for member in members:
                    with archive.open(member) as src:
                        while True:
                            chunk = src.read(4 * 1024 * 1024)
                            if not chunk:
                                break
                            out.write(chunk)
                            done += len(chunk)
                            if total > 0:
                                set_job(pct=done * 100 // total)
        os.replace(part, target)
        run(["chown", "mac:mac", target])
        items = read_prefs()
        if not prefs_has_file(items, "disk", target):
            items.append(("disk", target))
            write_prefs(items)
        os.remove(path)
        set_job(state="done", pct=100)
    except (OSError, zipfile.BadZipFile) as exc:
        try:
            os.remove(part)
        except OSError:
            pass
        set_job(state="error", error=str(exc))


@app.route("/disks/install", methods=["POST"])
def disks_install():
    name = safe_name(request.form.get("name", ""))
    path = os.path.join(ZIPS_DIR, name)
    if not name.lower().endswith(".dsk.zip") or not os.path.isfile(path):
        flash("Archive not found.")
        return redirect(url_for("disks"))
    target = os.path.join(DISKS_DIR, archive_target_name(name))
    if os.path.exists(target):
        flash("A disk named %s already exists." % archive_target_name(name))
        return redirect(url_for("disks"))
    with install_lock:
        job = install_jobs.get(name)
        if job is not None and job.get("state") == "running":
            flash("%s is already being installed." % archive_label(name))
            return redirect(url_for("disks"))
        install_jobs[name] = {"state": "running", "pct": 0, "error": ""}
    worker = threading.Thread(
        target=install_archive_worker, args=(name,), daemon=True
    )
    worker.start()
    flash(
        "Installing %s in the background (a few minutes). The disk is "
        "attached automatically when it finishes; restart the emulator "
        "to boot it." % archive_label(name)
    )
    return redirect(url_for("disks"))


@app.route("/disks/install-status.json")
def disks_install_status():
    jobs = {}
    with install_lock:
        for name, job in install_jobs.items():
            jobs[name] = dict(job)
    return {"jobs": jobs}


def win_cdrom_attached():
    """Basename of the ISO currently set as the Windows CD-ROM, or "".
    The launcher (rpimac-dosbox) reads this same marker file."""
    try:
        with open(WIN98_CDROM_FILE) as handle:
            return handle.read().strip()
    except OSError:
        return ""


def write_win_cdrom(name):
    """Atomically set the attached-CD marker to a single ISO basename."""
    os.makedirs(WIN98_DIR, exist_ok=True)
    tmp = WIN98_CDROM_FILE + ".tmp"
    with open(tmp, "w") as handle:
        handle.write(name)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, WIN98_CDROM_FILE)


def disks_win():
    """Windows-mode Disks view: the fixed C: drive plus the uploadable
    CD-ROM ISOs, one of which can be inserted at a time."""
    if os.path.exists(WIN98_HDD):
        win_hdd = {
            "name": "hdd.vhd",
            "size": human_size(os.path.getsize(WIN98_HDD)),
            "exists": True,
        }
    else:
        win_hdd = {"name": "hdd.vhd", "size": "", "exists": False}
    cdrom = win_cdrom_attached()
    attached = []
    if cdrom:
        attached.append(os.path.join(WIN98_ISOS_DIR, cdrom))
    win_isos = list_images(WIN98_ISOS_DIR, ISO_EXTENSIONS, attached)
    return render_template(
        "disks.html",
        win_hdd=win_hdd,
        win_isos=win_isos,
        win_cdrom=cdrom,
    )


@app.route("/disks")
def disks():
    if current_mode() == "win":
        return disks_win()
    items = read_prefs()
    attached_disks = prefs_values(items, "disk")
    attached_cdroms = prefs_values(items, "cdrom")
    disk_entries = list_images(DISKS_DIR, DISK_EXTENSIONS, attached_disks)
    iso_entries = list_images(ISOS_DIR, ISO_EXTENSIONS, attached_cdroms)
    return render_template(
        "disks.html",
        disks=disk_entries,
        isos=iso_entries,
        archives=list_archives(),
    )


def save_upload(upload, dest):
    """Stream an upload to a temp file, then move into place atomically
    so an interrupted transfer never leaves a half-written image."""
    tmp = dest + ".uploading"
    upload.save(tmp)
    os.replace(tmp, dest)
    run(["chown", "mac:mac", dest])


@app.route("/upload-raw", methods=["POST"])
def upload_raw():
    """Streamlined upload used by the JS on the Disks/Files pages: the file
    arrives as the raw request body, skipping multipart parsing and one
    full temp-file copy - a big deal at SD card write speeds."""
    kind = request.args.get("kind", "disk")
    name = safe_name(request.args.get("name", ""))
    if not name:
        return {"ok": False, "error": "name required"}, 400
    win = current_mode() == "win"
    if kind == "iso":
        if win:
            directory = WIN98_ISOS_DIR
        else:
            directory = ISOS_DIR
    elif kind == "shared":
        if win:
            directory = WIN98_SHARED_DIR
        else:
            directory = SHARED_DIR
    else:
        directory = DISKS_DIR
    dest = os.path.join(directory, name)
    tmp = dest + ".uploading"
    try:
        with open(tmp, "wb") as out:
            while True:
                chunk = request.stream.read(1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
        os.replace(tmp, dest)
    except OSError as exc:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return {"ok": False, "error": str(exc)}, 500
    run(["chown", "mac:mac", dest])
    return {"ok": True, "name": name}


@app.route("/disks/upload", methods=["POST"])
def disks_upload():
    kind = request.form.get("kind", "disk")
    upload = request.files.get("file")
    if upload is None or upload.filename == "":
        flash("No file selected.")
        return redirect(url_for("disks"))
    name = safe_name(upload.filename)
    if kind == "iso":
        if current_mode() == "win":
            directory = WIN98_ISOS_DIR
        else:
            directory = ISOS_DIR
    else:
        directory = DISKS_DIR
    os.makedirs(directory, exist_ok=True)
    save_upload(upload, os.path.join(directory, name))
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
    size_mb = max(1, min(size_mb, 4096))
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
    if prefs_has_file(items, keyword, path):
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
    if not prefs_has_file(items, keyword, path):
        flash("%s was not attached." % name)
        return redirect(url_for("disks"))
    items = prefs_remove(items, keyword, path)
    write_prefs(items)
    if request.form.get("restart") == "1":
        run(["systemctl", "restart", EMULATOR_UNIT])
        flash("Detached %s and restarted the emulator." % name)
    else:
        flash("Detached %s. Restart the emulator to apply." % name)
    return redirect(url_for("disks"))


@app.route("/disks/download/<kind>/<path:name>")
def disks_download(kind, name):
    if kind == "win-iso":
        directory = WIN98_ISOS_DIR
    elif kind == "iso":
        directory = ISOS_DIR
    else:
        directory = DISKS_DIR
    return send_from_directory(
        directory, safe_name(name), as_attachment=True
    )


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
    if prefs_has_file(items, keyword, path):
        flash("Detach %s before deleting it." % name)
        return redirect(url_for("disks"))
    if os.path.isfile(path):
        os.remove(path)
        flash("Deleted %s." % name)
    return redirect(url_for("disks"))


# ----------------------------------------------------- windows CD-ROM (ISO) ---
# The DOSBox-X launcher only consults the CD marker when it (re)starts, so
# inserting or ejecting a disc means restarting Windows. These routes mirror
# the Mac iso attach/detach affordances but write the single-basename marker
# file the launcher reads instead of the Basilisk prefs.

@app.route("/disks/win-iso-attach", methods=["POST"])
def disks_win_iso_attach():
    name = safe_name(request.form.get("name", ""))
    path = os.path.join(WIN98_ISOS_DIR, name)
    if not name or not os.path.isfile(path):
        flash("ISO not found.")
        return redirect(url_for("disks"))
    write_win_cdrom(name)
    if request.form.get("restart") == "1":
        run(["systemctl", "restart", EMULATOR_UNIT])
        flash("Inserted %s and restarted Windows to mount the CD." % name)
    else:
        flash("Inserted %s. Restart Windows to insert the CD." % name)
    return redirect(url_for("disks"))


@app.route("/disks/win-iso-detach", methods=["POST"])
def disks_win_iso_detach():
    name = win_cdrom_attached()
    try:
        os.remove(WIN98_CDROM_FILE)
    except OSError:
        pass
    if request.form.get("restart") == "1":
        run(["systemctl", "restart", EMULATOR_UNIT])
        flash("Ejected %s and restarted Windows." % (name or "the CD"))
    else:
        flash("Ejected %s. Restart Windows to apply." % (name or "the CD"))
    return redirect(url_for("disks"))


@app.route("/disks/win-iso-delete", methods=["POST"])
def disks_win_iso_delete():
    name = safe_name(request.form.get("name", ""))
    path = os.path.join(WIN98_ISOS_DIR, name)
    if name and win_cdrom_attached() == name:
        flash("Eject %s before deleting it." % name)
        return redirect(url_for("disks"))
    if os.path.isfile(path):
        os.remove(path)
        flash("Deleted %s." % name)
    return redirect(url_for("disks"))


# ---------------------------------------------------------- shared files ---

def shared_dir():
    """Active shared folder: the FAT-synced Windows dir in Windows mode, the
    Basilisk "Unix" extfs dir otherwise. The files routes operate on this so
    the same page serves both modes."""
    if current_mode() == "win":
        return WIN98_SHARED_DIR
    return SHARED_DIR


@app.route("/files")
def files():
    directory = shared_dir()
    entries = []
    if os.path.isdir(directory):
        for name in sorted(os.listdir(directory)):
            path = os.path.join(directory, name)
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
    directory = shared_dir()
    os.makedirs(directory, exist_ok=True)
    save_upload(upload, os.path.join(directory, name))
    flash("Uploaded %s to the shared folder." % name)
    return redirect(url_for("files"))


@app.route("/files/delete", methods=["POST"])
def files_delete():
    name = safe_name(request.form.get("name", ""))
    path = os.path.join(shared_dir(), name)
    if os.path.isfile(path):
        os.remove(path)
        flash("Deleted %s." % name)
    return redirect(url_for("files"))


@app.route("/files/download/<path:name>")
def files_download(name):
    return send_from_directory(
        shared_dir(), safe_name(name), as_attachment=True
    )


# -------------------------------------------------------------- bluetooth ---

bt_scan_proc = None
bt_pair_state = {}
bt_pair_lock = threading.Lock()


def bt_power_on():
    run(["rfkill", "unblock", "bluetooth"])
    run(["bluetoothctl", "power", "on"])


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


ANSI_RE = re.compile(r"\x1b\[[0-9;]*m|\x01|\x02|\r")


def bt_pair_worker(addr):
    """Interactive pairing via bluetoothctl. Keyboards usually require a
    passkey typed on the keyboard itself; bluez tells us the passkey to
    display, and we surface it in the UI via bt_pair_state."""
    import select as select_mod

    state = {"status": "pairing", "message": "Pairing..."}
    with bt_pair_lock:
        bt_pair_state[addr] = state

    bt_power_on()
    proc = subprocess.Popen(
        ["bluetoothctl"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )

    def send(command):
        try:
            proc.stdin.write(command + "\n")
            proc.stdin.flush()
        except OSError:
            pass

    send("agent KeyboardDisplay")
    send("default-agent")
    send("pair " + addr)

    success = False
    deadline = time.time() + 60
    fd = proc.stdout.fileno()
    buffer = ""
    while time.time() < deadline:
        ready, _, _ = select_mod.select([fd], [], [], 1.0)
        if not ready:
            continue
        chunk = os.read(fd, 4096).decode("utf-8", "replace")
        if not chunk:
            break
        buffer += chunk
        lines = buffer.split("\n")
        buffer = lines.pop()
        pending = lines
        if buffer.strip():
            # prompts often arrive without a newline
            pending = pending + [buffer]
        for raw_line in pending:
            line = ANSI_RE.sub("", raw_line).strip()
            match = re.search(r"Passkey:?\s*(\d{6})", line)
            if match and "Confirm" not in line:
                state["message"] = (
                    "Type %s on the keyboard, then press Enter"
                    % match.group(1)
                )
            if "Confirm passkey" in line:
                send("yes")
            if "Authorize service" in line:
                send("yes")
            if "Pairing successful" in line:
                success = True
            if "Failed to pair" in line or "AuthenticationFailed" in line:
                state["status"] = "failed"
                state["message"] = "Pairing failed - try again"
        if success:
            break
        if state["status"] == "failed":
            break

    if success:
        state["message"] = "Paired - connecting..."
        send("trust " + addr)
        send("connect " + addr)
        time.sleep(5)
        send("quit")
        state["status"] = "done"
        state["message"] = "Paired and trusted"
    else:
        send("quit")
        if state["status"] != "failed":
            state["status"] = "failed"
            state["message"] = "Pairing timed out - try again"
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()


@app.route("/bluetooth")
def bluetooth():
    return render_template("bluetooth.html")


def bt_scan_stop():
    """End discovery promptly - active BT inquiry tramples WiFi on the
    Zero 2 W's shared 2.4GHz radio (measured: ~16ms ping -> 100ms+)."""
    global bt_scan_proc
    if bt_scan_proc is not None and bt_scan_proc.poll() is None:
        bt_scan_proc.terminate()
        try:
            bt_scan_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            bt_scan_proc.kill()
    bt_scan_proc = None


@app.route("/bluetooth/scan-start", methods=["POST"])
def bluetooth_scan_start():
    global bt_scan_proc
    bt_power_on()
    if bt_scan_proc is None or bt_scan_proc.poll() is not None:
        bt_scan_proc = subprocess.Popen(
            ["bluetoothctl", "--timeout", "20", "scan", "on"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    return {"ok": True}


@app.route("/bluetooth/scan-stop", methods=["POST"])
def bluetooth_scan_stop():
    bt_scan_stop()
    return {"ok": True}


@app.route("/bluetooth/devices.json")
def bluetooth_devices_json():
    paired = bluetoothctl_devices(["Paired"])
    paired_addrs = set()
    for device in paired:
        paired_addrs.add(device["addr"])
    connected_addrs = set()
    for device in bluetoothctl_devices(["Connected"]):
        connected_addrs.add(device["addr"])
    for device in paired:
        device["connected"] = device["addr"] in connected_addrs
    discovered = []
    for device in bluetoothctl_devices([]):
        if device["addr"] in paired_addrs:
            continue
        device["unnamed"] = device["name"].replace("-", ":") == device["addr"]
        discovered.append(device)
    discovered.sort(key=lambda d: d["unnamed"])
    scanning = bt_scan_proc is not None and bt_scan_proc.poll() is None
    with bt_pair_lock:
        pair_states = dict(bt_pair_state)
    return {
        "paired": paired,
        "discovered": discovered,
        "scanning": scanning,
        "pairing": pair_states,
    }


@app.route("/bluetooth/pair", methods=["POST"])
def bluetooth_pair():
    addr = request.form.get("addr", "")
    if not re.fullmatch(r"[0-9A-F:]{17}", addr):
        return {"ok": False, "error": "bad address"}, 400
    with bt_pair_lock:
        state = bt_pair_state.get(addr)
        if state is not None and state.get("status") == "pairing":
            return {"ok": True}
    # Discovery fights both WiFi and the pairing handshake for airtime
    bt_scan_stop()
    worker = threading.Thread(target=bt_pair_worker, args=(addr,))
    worker.daemon = True
    worker.start()
    return {"ok": True}


@app.route("/bluetooth/connect", methods=["POST"])
def bluetooth_connect():
    addr = request.form.get("addr", "")
    if re.fullmatch(r"[0-9A-F:]{17}", addr):
        run(["bluetoothctl", "--timeout", "15", "connect", addr], timeout=30)
        return {"ok": True}
    return {"ok": False}, 400


@app.route("/bluetooth/remove", methods=["POST"])
def bluetooth_remove():
    addr = request.form.get("addr", "")
    if re.fullmatch(r"[0-9A-F:]{17}", addr):
        run(["bluetoothctl", "remove", addr])
        with bt_pair_lock:
            bt_pair_state.pop(addr, None)
        return {"ok": True}
    return {"ok": False}, 400


# --------------------------------------------------------------- console ---

# The emulator mirrors its framebuffer to a shared-memory file with an 80-byte
# header. Both emulators use the same wire format (magic, w, h, seq, rgb byte
# offsets, dirty rect, ...); only the path and magic differ by mode.
SCREEN_SHM_MAC = "/dev/shm/rpimac-screen"
SCREEN_MAGIC_MAC = 0x52504D34
SCREEN_SHM_WIN = "/dev/shm/win98-screen"
SCREEN_MAGIC_WIN = 0x57493832


def screen_target():
    """Return (shm_path, magic) for the active mode's frame mirror."""
    if current_mode() == "win":
        return SCREEN_SHM_WIN, SCREEN_MAGIC_WIN
    return SCREEN_SHM_MAC, SCREEN_MAGIC_MAC

# Browser KeyboardEvent.code -> Linux input event code names
KEY_CODE_MAP = {}


def build_key_map():
    for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
        KEY_CODE_MAP["Key" + letter] = "KEY_" + letter
    for digit in "0123456789":
        KEY_CODE_MAP["Digit" + digit] = "KEY_" + digit
    for fnum in range(1, 13):
        KEY_CODE_MAP["F%d" % fnum] = "KEY_F%d" % fnum
    KEY_CODE_MAP.update(
        {
            "Enter": "KEY_ENTER",
            "Escape": "KEY_ESC",
            "Backspace": "KEY_BACKSPACE",
            "Tab": "KEY_TAB",
            "Space": "KEY_SPACE",
            "Minus": "KEY_MINUS",
            "Equal": "KEY_EQUAL",
            "BracketLeft": "KEY_LEFTBRACE",
            "BracketRight": "KEY_RIGHTBRACE",
            "Backslash": "KEY_BACKSLASH",
            "Semicolon": "KEY_SEMICOLON",
            "Quote": "KEY_APOSTROPHE",
            "Backquote": "KEY_GRAVE",
            "Comma": "KEY_COMMA",
            "Period": "KEY_DOT",
            "Slash": "KEY_SLASH",
            "CapsLock": "KEY_CAPSLOCK",
            "ShiftLeft": "KEY_LEFTSHIFT",
            "ShiftRight": "KEY_RIGHTSHIFT",
            "ControlLeft": "KEY_LEFTCTRL",
            "ControlRight": "KEY_RIGHTCTRL",
            "AltLeft": "KEY_LEFTALT",
            "AltRight": "KEY_RIGHTALT",
            "MetaLeft": "KEY_LEFTMETA",
            "MetaRight": "KEY_RIGHTMETA",
            "ArrowUp": "KEY_UP",
            "ArrowDown": "KEY_DOWN",
            "ArrowLeft": "KEY_LEFT",
            "ArrowRight": "KEY_RIGHT",
            "Delete": "KEY_DELETE",
            "Home": "KEY_HOME",
            "End": "KEY_END",
            "PageUp": "KEY_PAGEUP",
            "PageDown": "KEY_PAGEDOWN",
        }
    )


build_key_map()

uinput_device = None
uinput_lock = threading.Lock()

ABS_RANGE = 32767


def get_uinput():
    """Create the virtual tablet+keyboard on first use.

    Uses absolute axes (like a drawing tablet / VM pointer) so the Mac
    cursor lands exactly where the user clicks, immune to the classic
    Mac's mouse acceleration and to relative-tracking drift.
    """
    global uinput_device
    with uinput_lock:
        if uinput_device is not None:
            return uinput_device
        try:
            from evdev import AbsInfo, UInput, ecodes

            keys = [ecodes.BTN_LEFT, ecodes.BTN_RIGHT]
            for name in KEY_CODE_MAP.values():
                keys.append(getattr(ecodes, name))
            abs_info = AbsInfo(
                value=0, min=0, max=ABS_RANGE, fuzz=0, flat=0, resolution=0
            )
            capabilities = {
                ecodes.EV_KEY: keys,
                ecodes.EV_ABS: [
                    (ecodes.ABS_X, abs_info),
                    (ecodes.ABS_Y, abs_info),
                ],
                ecodes.EV_REL: [ecodes.REL_WHEEL],
            }
            uinput_device = UInput(
                capabilities, name="rpimac-web-tablet", version=1
            )
        except Exception as exc:
            app.logger.error("uinput unavailable: %s", exc)
            uinput_device = None
        return uinput_device


def screen_placement():
    """Read the guest dimensions and on-screen placement (visible rect,
    window size, rotation) that the emulator publishes with each frame."""
    placement = {
        "gw": 640, "gh": 480,
        "vx": 0, "vy": 0, "vw": 640, "vh": 480,
        "ww": 640, "wh": 480,
        "rot": 0,
    }
    try:
        with open(SCREEN_SHM_MAC, "rb") as handle:
            header = handle.read(80)
        if len(header) == 80:
            fields = struct.unpack("<20I", header)
            if fields[0] == SCREEN_MAGIC_MAC:
                placement.update(
                    gw=fields[1], gh=fields[2],
                    vx=fields[12], vy=fields[13],
                    vw=fields[14], vh=fields[15],
                    ww=fields[16], wh=fields[17],
                    rot=fields[18],
                )
    except OSError:
        pass
    return placement


def guest_to_abs(gx, gy, placement):
    """Map guest screen pixels to the tablet's absolute axis range using
    the exact placement (rotation, margins, scaling) the emulator
    reported - the emulator applies the inverse on the way back in."""
    gw = max(placement["gw"], 2)
    gh = max(placement["gh"], 2)
    fx = min(max(gx / (gw - 1.0), 0.0), 1.0)
    fy = min(max(gy / (gh - 1.0), 0.0), 1.0)
    rot = placement["rot"]
    if rot == 90:
        u = 1.0 - fy
        v = fx
    elif rot == 180:
        u = 1.0 - fx
        v = 1.0 - fy
    elif rot == 270:
        u = fy
        v = 1.0 - fx
    else:
        u = fx
        v = fy
    vw = max(placement["vw"], 2)
    vh = max(placement["vh"], 2)
    wx = placement["vx"] + u * (vw - 1)
    wy = placement["vy"] + v * (vh - 1)
    ww = max(placement["ww"], 2)
    wh = max(placement["wh"], 2)
    ax = int(min(max(wx / (ww - 1.0), 0.0), 1.0) * ABS_RANGE)
    ay = int(min(max(wy / (wh - 1.0), 0.0), 1.0) * ABS_RANGE)
    return ax, ay


@app.route("/console")
def console():
    # Pre-create the Windows-mode virtual input device when the console opens,
    # so DOSBox-X's SDL hotplug-detects it before the user starts interacting
    # (otherwise the first few events can be lost during detection).
    if current_mode() == "win":
        get_win_uinput()
    return render_template("console.html")


@app.route("/screen.raw")
def screen_raw():
    shm_path, want_magic = screen_target()
    # Tell the emulator someone is watching, so it mirrors frames at all
    # (it skips all screen-sharing work when this token goes stale)
    try:
        with open(shm_path + "-want", "w") as token:
            token.write("1")
    except OSError:
        pass
    try:
        with open(shm_path, "rb") as handle:
            data = handle.read()
    except OSError:
        return "no screen", 503
    if len(data) < 80:
        return "no screen", 503
    (magic, width, height, seq, roff, goff, boff, _pad,
     dx, dy, dw, dh,
     _vx, _vy, _vw, _vh, _ww, _wh, _rot, _r2) = struct.unpack(
        "<20I", data[:80]
    )
    if magic != want_magic:
        return "bad magic", 503

    since_raw = request.args.get("since", "")
    since = -1
    if since_raw.isdigit():
        since = int(since_raw)

    # Client is up to date: empty response, no pixel traffic at all
    if since == seq:
        response = app.response_class(b"", status=204)
        response.headers["X-Screen-Seq"] = str(seq)
        response.headers["Cache-Control"] = "no-store"
        return response

    frame = data[80 : 80 + width * height * 4]

    # VNC-style partial update: only valid if the client has exactly the
    # previous frame, and only worthwhile for small changes (<20% area)
    rect = None
    if (
        since == seq - 1
        and dw > 0
        and dh > 0
        and dw * dh <= (width * height) // 5
    ):
        rect = (dx, dy, dw, dh)
        rows = []
        for row in range(dy, dy + dh):
            start = (row * width + dx) * 4
            rows.append(frame[start : start + dw * 4])
        body = b"".join(rows)
    else:
        body = frame

    # Classic Mac screens are mostly flat colour, so even fast deflate
    # shrinks frames dramatically - vital over WiFi.
    compressed = zlib.compress(body, 1)
    response = app.response_class(
        compressed, mimetype="application/octet-stream"
    )
    response.headers["Content-Encoding"] = "deflate"
    response.headers["X-Screen-Width"] = str(width)
    response.headers["X-Screen-Height"] = str(height)
    response.headers["X-Screen-Seq"] = str(seq)
    response.headers["X-Screen-Order"] = "%d,%d,%d" % (roff, goff, boff)
    if rect is not None:
        response.headers["X-Screen-Rect"] = "%d,%d,%d,%d" % rect
    response.headers["Cache-Control"] = "no-store"
    return response


# Windows mode delivers input through a uinput virtual keyboard + relative
# mouse. Under the appliance's KMSDRM renderer, DOSBox-X's SDL reads real input
# devices directly, so web input must arrive as a real evdev device (SDL
# hotplug-detects it); the patched shm-queue path that DOSBox-X polls does not
# reach the booted guest under KMSDRM. SDL maps a uinput ABS tablet
# unreliably, so we use a relative mouse and convert the console's absolute
# coordinates into deltas here.
win_uinput_device = None
win_uinput_lock = threading.Lock()
win_mouse_last = None


def get_win_uinput():
    """Create (once) the Windows-mode virtual keyboard + relative mouse."""
    global win_uinput_device
    with win_uinput_lock:
        if win_uinput_device is not None:
            return win_uinput_device
        try:
            from evdev import UInput, ecodes

            keys = [ecodes.BTN_LEFT, ecodes.BTN_RIGHT]
            for name in KEY_CODE_MAP.values():
                keys.append(getattr(ecodes, name))
            capabilities = {
                ecodes.EV_KEY: keys,
                ecodes.EV_REL: [ecodes.REL_X, ecodes.REL_Y, ecodes.REL_WHEEL],
            }
            win_uinput_device = UInput(
                capabilities, name="rpimac-win-input", version=1
            )
        except Exception as exc:
            app.logger.error("win uinput unavailable: %s", exc)
            win_uinput_device = None
        return win_uinput_device


def console_input_mac(events):
    device = get_uinput()
    if device is None:
        return {"ok": False, "error": "uinput unavailable"}, 503
    from evdev import ecodes

    geometry = None
    for event in events:
        kind = event.get("t")
        if kind == "abspos":
            if geometry is None:
                geometry = screen_placement()
            ax, ay = guest_to_abs(
                int(event.get("x", 0)),
                int(event.get("y", 0)),
                geometry,
            )
            device.write(ecodes.EV_ABS, ecodes.ABS_X, ax)
            device.write(ecodes.EV_ABS, ecodes.ABS_Y, ay)
        elif kind == "wheel":
            amount = int(event.get("d", 0))
            if amount:
                device.write(ecodes.EV_REL, ecodes.REL_WHEEL, amount)
        elif kind == "button":
            button = ecodes.BTN_LEFT
            if event.get("b") == "right":
                button = ecodes.BTN_RIGHT
            value = 0
            if event.get("down"):
                value = 1
            device.write(ecodes.EV_KEY, button, value)
        elif kind == "key":
            name = KEY_CODE_MAP.get(event.get("code", ""))
            if name:
                value = 0
                if event.get("down"):
                    value = 1
                device.write(ecodes.EV_KEY, getattr(ecodes, name), value)
    device.syn()
    return {"ok": True}


def console_input_win(events):
    global win_mouse_last
    device = get_win_uinput()
    if device is None:
        return {"ok": False, "error": "uinput unavailable"}, 503
    from evdev import ecodes

    with win_uinput_lock:
        for event in events:
            kind = event.get("t")
            if kind == "abspos":
                # Convert the console's absolute coordinates into relative
                # deltas for the relative mouse (the guest cursor follows the
                # web cursor's movement).
                x = int(event.get("x", 0))
                y = int(event.get("y", 0))
                if win_mouse_last is not None:
                    dx = x - win_mouse_last[0]
                    dy = y - win_mouse_last[1]
                    if dx != 0:
                        device.write(ecodes.EV_REL, ecodes.REL_X, dx)
                    if dy != 0:
                        device.write(ecodes.EV_REL, ecodes.REL_Y, dy)
                win_mouse_last = (x, y)
            elif kind == "wheel":
                amount = int(event.get("d", 0))
                if amount:
                    device.write(ecodes.EV_REL, ecodes.REL_WHEEL, amount)
            elif kind == "button":
                button = ecodes.BTN_LEFT
                if event.get("b") == "right":
                    button = ecodes.BTN_RIGHT
                value = 0
                if event.get("down"):
                    value = 1
                device.write(ecodes.EV_KEY, button, value)
            elif kind == "key":
                name = KEY_CODE_MAP.get(event.get("code", ""))
                if name:
                    value = 0
                    if event.get("down"):
                        value = 1
                    device.write(ecodes.EV_KEY, getattr(ecodes, name), value)
        device.syn()
    return {"ok": True}


@app.route("/input", methods=["POST"])
def console_input():
    events = request.get_json(silent=True)
    if not isinstance(events, list):
        return {"ok": False, "error": "bad payload"}, 400
    if current_mode() == "win":
        return console_input_win(events)
    return console_input_mac(events)


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
        # Leave the setup hotspot (if any) before joining the real network,
        # and stop acting as a captive portal.
        run(["nmcli", "connection", "down", "rpimac-hotspot"], timeout=30)
        try:
            os.remove(HOTSPOT_MARKER)
        except OSError:
            pass
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
    for directory in (
        DISKS_DIR,
        ISOS_DIR,
        SHARED_DIR,
        WIN98_ISOS_DIR,
        WIN98_SHARED_DIR,
    ):
        os.makedirs(directory, exist_ok=True)
    from waitress import serve

    # channel_timeout must comfortably exceed the slowest plausible
    # multi-hundred-MB ISO upload over WiFi
    serve(app, host="0.0.0.0", port=80, threads=6, channel_timeout=3600)
