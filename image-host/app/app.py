#!/usr/bin/env python3
"""pimac.net - RPi-Mac image host and SD card builder.

Public site: download stock release images, or queue a custom SD card
build (pick ROM / disks / ISOs / network settings) assembled by the
builder worker (builder/worker.py) on this machine.

Admin backend (/admin): upload and manage the component library.

Runs behind Caddy, which terminates TLS and serves the large image
downloads directly from disk; the Flask routes that stream files exist
so the app also works stand-alone (development, self-hosters without
the provided Caddyfile).
"""

import functools
import json
import os
import re
import sys
import time
import zipfile

from flask import (
    Flask,
    abort,
    jsonify,
    redirect,
    render_template,
    request,
    send_from_directory,
    session,
    url_for,
)
from werkzeug.security import check_password_hash

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import db

app = Flask(__name__)

LISTEN_HOST = os.environ.get("PIMAC_LISTEN", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("PIMAC_PORT", "8080"))
SITE_NAME = os.environ.get("PIMAC_SITE_NAME", "pimac.net")

MAX_QUEUED_JOBS = 12
MAX_BLANK_DISKS = 4
MAX_BLANK_DISK_MB = 2048
MIN_BLANK_DISK_MB = 10
MAX_PAYLOAD_BYTES = 12 * 1024**3

# .dsk.zip disks are shipped compressed on the card and expanded by the
# image on its first boot, which keeps custom downloads small.
ALLOWED_EXTENSIONS = {
    "rom": (".rom",),
    "disk": (".dsk.zip", ".dsk", ".img", ".hfv", ".hda"),
    "iso": (".iso", ".toast", ".cdr"),
}

RELEASE_RE = re.compile(r"^image_(\d{4}-\d{2}-\d{2})-RPi-Mac(-[A-Za-z0-9]+)?\.img\.xz$")

# Flavour suffix in the release filename -> what it is for
RELEASE_VARIANT_LABELS = {
    "": "HDMI display",
    "Waveshare": "Waveshare 2.8\u2033 DPI LCD",
}
SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,79}$")
BLANK_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 _-]{0,26}$")

with db.connect() as _conn:
    app.secret_key = db.secret_key(_conn)


# ------------------------------------------------------------- helpers ---

def human_size(num):
    value = float(num)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if value < 1024 or unit == "TB":
            if unit == "B":
                return "%d %s" % (int(value), unit)
            return "%.1f %s" % (value, unit)
        value = value / 1024
    return "%d B" % num


app.jinja_env.filters["human_size"] = human_size
app.jinja_env.globals["site_name"] = SITE_NAME


def strip_component_extension(filename):
    """Component name without its (possibly compound) extension."""
    lowered = filename.lower()
    for extensions in ALLOWED_EXTENSIONS.values():
        for extension in extensions:
            if lowered.endswith(extension):
                return filename[: -len(extension)]
    return os.path.splitext(filename)[0]


def component_install_size(comp):
    """Bytes the component occupies once installed on the SD card.
    Zipped disks are expanded on the Pi's first boot, so their expanded
    size is what matters for sizing; everything else is used as-is."""
    if not comp["filename"].lower().endswith(".dsk.zip"):
        return comp["size_bytes"]
    try:
        with zipfile.ZipFile(db.component_path(comp)) as archive:
            return sum(info.file_size for info in archive.infolist())
    except (OSError, zipfile.BadZipFile):
        return comp["size_bytes"]


def list_releases():
    """Stock images published into the releases directory by rsync."""
    releases = []
    if not os.path.isdir(db.RELEASES_DIR):
        return releases
    for name in os.listdir(db.RELEASES_DIR):
        match = RELEASE_RE.match(name)
        if match is None:
            continue
        path = os.path.join(db.RELEASES_DIR, name)
        date = match.group(1)
        variant = (match.group(2) or "").lstrip("-")
        stem = name[len("image_"):-len(".img.xz")]
        bmap = stem + ".bmap"
        if not os.path.exists(os.path.join(db.RELEASES_DIR, bmap)):
            bmap = ""
        releases.append({
            "filename": name,
            "date": date,
            "variant": variant,
            "variant_label": RELEASE_VARIANT_LABELS.get(variant, variant),
            "size_bytes": os.path.getsize(path),
            "bmap": bmap,
        })
    # Newest first; the standard flavour before variants within a date
    releases.sort(key=lambda r: r["variant"])
    releases.sort(key=lambda r: r["date"], reverse=True)
    return releases


def is_admin():
    return bool(session.get("admin"))


def admin_required(view):
    @functools.wraps(view)
    def wrapped(*args, **kwargs):
        if not is_admin():
            return redirect(url_for("admin_login", next=request.path))
        return view(*args, **kwargs)
    return wrapped


def bad_request(message):
    response = jsonify({"error": message})
    response.status_code = 400
    return response


# -------------------------------------------------------- public pages ---

@app.route("/")
def index():
    with db.connect() as conn:
        components = db.list_components(conn)
    counts = {"rom": 0, "disk": 0, "iso": 0}
    for comp in components:
        counts[comp["kind"]] += 1
    return render_template(
        "index.html",
        releases=list_releases(),
        counts=counts,
    )


@app.route("/builder")
def builder():
    with db.connect() as conn:
        roms = db.list_components(conn, "rom")
        disks = db.list_components(conn, "disk")
        isos = db.list_components(conn, "iso")
    has_zipped_disks = False
    for disk in disks:
        disk["install_size"] = component_install_size(disk)
        if disk["install_size"] != disk["size_bytes"]:
            has_zipped_disks = True
    # Only the standard flavour is offered as a base: custom builds write
    # their own mac.txt, so the display choice below covers what the
    # flavours differ in.
    base_releases = []
    for release in list_releases():
        if not release["variant"]:
            base_releases.append(release)
    return render_template(
        "builder.html",
        releases=base_releases,
        roms=roms,
        disks=disks,
        isos=isos,
        has_zipped_disks=has_zipped_disks,
        max_blank_disks=MAX_BLANK_DISKS,
    )


@app.route("/build/<job_id>")
def build_status_page(job_id):
    token = request.args.get("t", "")
    with db.connect() as conn:
        job = db.get_job(conn, job_id)
    if job is None or job["token"] != token:
        abort(404)
    return render_template("build.html", job_id=job_id, token=token)


# ----------------------------------------------------------- build API ---

def validate_build_request(payload, conn):
    """Returns (params, error). params is None when invalid."""
    if not isinstance(payload, dict):
        return None, "Malformed request."

    base = payload.get("base", "")
    release_names = []
    for release in list_releases():
        release_names.append(release["filename"])
    if base not in release_names:
        return None, "Unknown base image."

    def fetch_components(ids, kind):
        result = []
        if not isinstance(ids, list):
            return None
        for comp_id in ids:
            if not isinstance(comp_id, int):
                return None
            comp = db.get_component(conn, comp_id)
            if comp is None or comp["kind"] != kind:
                return None
            if not os.path.exists(db.component_path(comp)):
                return None
            result.append(comp)
        return result

    roms = fetch_components([payload.get("rom")], "rom")
    if roms is None:
        return None, "Please choose a ROM."
    rom = roms[0]

    disks = fetch_components(payload.get("disks", []), "disk")
    if disks is None:
        return None, "Invalid disk selection."
    if len(disks) > 6:
        return None, "Too many disks selected (maximum 6)."

    isos = fetch_components(payload.get("isos", []), "iso")
    if isos is None:
        return None, "Invalid CD-ROM selection."
    if len(isos) > 4:
        return None, "Too many CD-ROMs selected (maximum 4)."

    blank_disks = payload.get("blank_disks", [])
    if not isinstance(blank_disks, list) or len(blank_disks) > MAX_BLANK_DISKS:
        return None, "Too many blank disks (maximum %d)." % MAX_BLANK_DISKS
    cleaned_blanks = []
    used_names = set()
    for disk in disks:
        used_names.add(disk["filename"].lower())
    for blank in blank_disks:
        if not isinstance(blank, dict):
            return None, "Malformed blank disk entry."
        name = str(blank.get("name", "")).strip()
        if not BLANK_NAME_RE.match(name):
            return None, "Blank disk names may use letters, numbers, spaces, - and _."
        try:
            size_mb = int(blank.get("size_mb"))
        except (TypeError, ValueError):
            return None, "Blank disk size must be a number of megabytes."
        if size_mb < MIN_BLANK_DISK_MB or size_mb > MAX_BLANK_DISK_MB:
            return None, ("Blank disk size must be between %d and %d MB."
                          % (MIN_BLANK_DISK_MB, MAX_BLANK_DISK_MB))
        filename = name + ".dsk"
        if filename.lower() in used_names:
            return None, "Duplicate disk name: %s" % name
        used_names.add(filename.lower())
        cleaned_blanks.append({"name": name, "size_mb": size_mb})

    if len(disks) == 0 and len(cleaned_blanks) == 0 and len(isos) == 0:
        return None, "Select at least one disk, blank disk or CD-ROM."

    boot = payload.get("boot", "disk")
    if boot not in ("disk", "cdrom"):
        return None, "Invalid boot device."
    if boot == "cdrom" and len(isos) == 0:
        return None, "Boot from CD-ROM requires at least one CD-ROM image."
    if boot == "disk" and len(disks) == 0 and len(cleaned_blanks) == 0:
        return None, "Boot from disk requires at least one disk."

    total = rom["size_bytes"]
    for comp in disks + isos:
        total += component_install_size(comp)
    for blank in cleaned_blanks:
        total += blank["size_mb"] * 1024**2
    if total > MAX_PAYLOAD_BYTES:
        return None, "Selection is too large (%s); keep it under %s." % (
            human_size(total), human_size(MAX_PAYLOAD_BYTES))

    network = payload.get("network", {})
    if not isinstance(network, dict):
        return None, "Malformed network settings."
    wifi_ssid = str(network.get("wifi_ssid", ""))[:32].strip()
    wifi_pass = str(network.get("wifi_pass", ""))[:63]
    wifi_country = str(network.get("wifi_country", "US")).strip().upper()
    if not re.match(r"^[A-Z]{2}$", wifi_country):
        return None, "WiFi country must be a two-letter code (US, GB, DE...)."
    if "\n" in wifi_ssid or "\r" in wifi_ssid:
        return None, "Invalid WiFi network name."
    if "\n" in wifi_pass or "\r" in wifi_pass:
        return None, "Invalid WiFi password."
    if wifi_ssid and wifi_pass and len(wifi_pass) < 8:
        return None, "WiFi passwords are at least 8 characters."

    display = payload.get("display", "hdmi")
    if display not in ("hdmi", "dpi28"):
        return None, "Invalid display selection."
    rotate = str(payload.get("rotate", ""))
    if rotate not in ("", "0", "90", "180", "270"):
        return None, "Invalid rotation."

    disk_ids = []
    for comp in disks:
        disk_ids.append(comp["id"])
    iso_ids = []
    for comp in isos:
        iso_ids.append(comp["id"])

    params = {
        "base": base,
        "rom": rom["id"],
        "disks": disk_ids,
        "blank_disks": cleaned_blanks,
        "isos": iso_ids,
        "boot": boot,
        "network": {
            "wifi_ssid": wifi_ssid,
            "wifi_pass": wifi_pass,
            "wifi_country": wifi_country,
        },
        "display": display,
        "rotate": rotate,
    }
    return params, None


@app.route("/api/builds", methods=["POST"])
def api_create_build():
    payload = request.get_json(silent=True)
    with db.connect() as conn:
        queued = conn.execute(
            "SELECT COUNT(*) AS n FROM jobs WHERE status IN ('queued', 'running')"
        ).fetchone()["n"]
        if queued >= MAX_QUEUED_JOBS:
            return bad_request(
                "The build queue is full right now - please try again in a "
                "few minutes.")
        params, error = validate_build_request(payload, conn)
        if error is not None:
            return bad_request(error)
        job_id, token = db.create_job(conn, params)
    return jsonify({
        "job_id": job_id,
        "status_url": url_for("build_status_page", job_id=job_id, t=token),
    })


@app.route("/api/builds/<job_id>")
def api_build_status(job_id):
    token = request.args.get("t", "")
    with db.connect() as conn:
        job = db.get_job(conn, job_id)
        if job is None or job["token"] != token:
            abort(404)
        position = db.queue_position(conn, job_id)
    result = {
        "status": job["status"],
        "stage": job["stage"],
        "percent": job["percent"],
        "queue_position": position,
        "error": job["error"],
    }
    if job["status"] == "done":
        result["download_url"] = "/builds/%s/%s?token=%s" % (
            job_id, job["output_name"], job["token"])
        result["output_name"] = job["output_name"]
        result["output_size"] = human_size(job["output_size"])
        result["expires_at"] = job["expires_at"]
    return jsonify(result)


# ------------------------------------------------------------ downloads ---
# In production Caddy serves these paths straight from disk; the /builds
# auth decision is delegated to /internal/auth-build via forward_auth.

def check_build_download(job_id, filename, token):
    with db.connect() as conn:
        job = db.get_job(conn, job_id)
    if job is None:
        return False
    if job["status"] != "done" or job["token"] != token:
        return False
    if job["output_name"] != filename:
        return False
    if job["expires_at"] is not None and job["expires_at"] < time.time():
        return False
    return True


@app.route("/internal/auth-build")
def internal_auth_build():
    uri = request.headers.get("X-Forwarded-Uri", "")
    match = re.match(r"^/builds/([0-9a-f]+)/([^/?]+)(?:\?(.*))?$", uri)
    if match is None:
        abort(403)
    job_id = match.group(1)
    filename = match.group(2)
    query = match.group(3)
    token = ""
    if query:
        for part in query.split("&"):
            if part.startswith("token="):
                token = part[len("token="):]
    if not check_build_download(job_id, filename, token):
        abort(403)
    return "", 204


@app.route("/builds/<job_id>/<path:filename>")
def download_build(job_id, filename):
    token = request.args.get("token", "")
    if not check_build_download(job_id, filename, token):
        abort(403)
    return send_from_directory(
        os.path.join(db.BUILDS_DIR, job_id), filename, as_attachment=True)


@app.route("/releases/<path:filename>")
def download_release(filename):
    return send_from_directory(db.RELEASES_DIR, filename, as_attachment=True)


# ---------------------------------------------------------------- admin ---

@app.route("/admin/login", methods=["GET", "POST"])
def admin_login():
    error = ""
    if request.method == "POST":
        password = request.form.get("password", "")
        with db.connect() as conn:
            password_hash = db.get_setting(conn, "admin_password_hash")
        if password_hash and check_password_hash(password_hash, password):
            session["admin"] = True
            session.permanent = True
            target = request.args.get("next", "/admin")
            if not target.startswith("/"):
                target = "/admin"
            return redirect(target)
        time.sleep(1)
        error = "Wrong password."
    return render_template("admin_login.html", error=error)


@app.route("/admin/logout", methods=["POST"])
def admin_logout():
    session.pop("admin", None)
    return redirect(url_for("index"))


@app.route("/admin")
@admin_required
def admin_home():
    with db.connect() as conn:
        components = db.list_components(conn)
        jobs = conn.execute(
            "SELECT * FROM jobs ORDER BY created_at DESC LIMIT 25").fetchall()
    grouped = {"rom": [], "disk": [], "iso": []}
    for comp in components:
        grouped[comp["kind"]].append(comp)
    disk_stats = os.statvfs(db.PIMAC_ROOT)
    free_bytes = disk_stats.f_bavail * disk_stats.f_frsize
    job_rows = []
    for job in jobs:
        job_rows.append(dict(job))
    return render_template(
        "admin.html",
        grouped=grouped,
        releases=list_releases(),
        jobs=job_rows,
        free_bytes=free_bytes,
        allowed_extensions=ALLOWED_EXTENSIONS,
    )


@app.route("/admin/upload-raw", methods=["POST"])
@admin_required
def admin_upload_raw():
    kind = request.args.get("kind", "")
    name = os.path.basename(request.args.get("name", ""))
    if kind not in db.COMPONENT_KINDS:
        return bad_request("Unknown component kind.")
    if not SAFE_NAME_RE.match(name):
        return bad_request(
            "Filename may only use letters, numbers, spaces, . _ and -")
    if not name.lower().endswith(ALLOWED_EXTENSIONS[kind]):
        return bad_request(
            "A %s must end in %s." % (kind, " or ".join(ALLOWED_EXTENSIONS[kind])))

    target_dir = db.component_dir(kind)
    os.makedirs(target_dir, exist_ok=True)
    final_path = os.path.join(target_dir, name)
    temp_path = final_path + ".uploading"
    written = 0
    try:
        with open(temp_path, "wb") as out:
            while True:
                chunk = request.stream.read(4 * 1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
                written += len(chunk)
        if written == 0:
            os.unlink(temp_path)
            return bad_request("Empty upload.")
        os.replace(temp_path, final_path)
    except OSError as exc:
        if os.path.exists(temp_path):
            os.unlink(temp_path)
        return bad_request("Upload failed: %s" % exc)

    display_name = strip_component_extension(name)
    with db.connect() as conn:
        comp = db.add_component(conn, kind, name, display_name)
    return jsonify({"ok": True, "id": comp["id"]})


@app.route("/admin/component/<int:comp_id>", methods=["POST"])
@admin_required
def admin_edit_component(comp_id):
    action = request.form.get("action", "save")
    with db.connect() as conn:
        comp = db.get_component(conn, comp_id)
        if comp is None:
            abort(404)
        if action == "delete":
            path = db.component_path(comp)
            if os.path.exists(path):
                os.unlink(path)
            conn.execute("DELETE FROM components WHERE id = ?", (comp_id,))
            conn.commit()
        else:
            display_name = request.form.get("display_name", "").strip()
            description = request.form.get("description", "").strip()
            if not display_name:
                display_name = comp["display_name"]
            conn.execute(
                "UPDATE components SET display_name = ?, description = ? "
                "WHERE id = ?",
                (display_name[:80], description[:400], comp_id))
            conn.commit()
    return redirect(url_for("admin_home"))


@app.route("/admin/release/delete", methods=["POST"])
@admin_required
def admin_delete_release():
    filename = os.path.basename(request.form.get("filename", ""))
    match = RELEASE_RE.match(filename)
    if match is None:
        abort(400)
    stem = filename[len("image_"):-len(".img.xz")]
    for name in (filename, stem + ".bmap", stem + ".info"):
        path = os.path.join(db.RELEASES_DIR, name)
        if os.path.exists(path):
            os.unlink(path)
    return redirect(url_for("admin_home"))


@app.route("/healthz")
def healthz():
    return "ok"


if __name__ == "__main__":
    if os.environ.get("PIMAC_DEV"):
        app.run(host=LISTEN_HOST, port=LISTEN_PORT, debug=True)
    else:
        from waitress import serve
        serve(app, host=LISTEN_HOST, port=LISTEN_PORT, threads=8,
              max_request_body_size=8 * 1024**3)
