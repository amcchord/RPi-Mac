#!/usr/bin/env python3
"""Maintenance CLI for the pimac image host.

  manage.py set-admin-password [PASSWORD]   set/replace the admin password
                                            (prompts when omitted)
  manage.py has-admin-password              exit 0 when a password is set
  manage.py add-component KIND FILE [--name NAME] [--description TEXT]
                                            copy FILE into the library and
                                            register it (KIND: rom|disk|iso)
  manage.py list                            show registered components
"""

import argparse
import getpass
import os
import shutil
import sys

from werkzeug.security import generate_password_hash

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import db


def cmd_set_admin_password(args):
    password = args.password
    if password is None:
        password = getpass.getpass("New admin password: ")
        confirm = getpass.getpass("Repeat: ")
        if password != confirm:
            print("Passwords do not match.", file=sys.stderr)
            return 1
    if len(password) < 6:
        print("Password too short (minimum 6 characters).", file=sys.stderr)
        return 1
    with db.connect() as conn:
        db.set_setting(conn, "admin_password_hash",
                       generate_password_hash(password))
    print("Admin password updated.")
    return 0


def cmd_has_admin_password(_args):
    with db.connect() as conn:
        if db.get_setting(conn, "admin_password_hash"):
            return 0
    return 1


def cmd_add_component(args):
    if args.kind not in db.COMPONENT_KINDS:
        print("KIND must be one of: %s" % ", ".join(db.COMPONENT_KINDS),
              file=sys.stderr)
        return 1
    source = args.file
    if not os.path.isfile(source):
        print("No such file: %s" % source, file=sys.stderr)
        return 1
    filename = os.path.basename(source)
    target_dir = db.component_dir(args.kind)
    os.makedirs(target_dir, exist_ok=True)
    target = os.path.join(target_dir, filename)
    if os.path.abspath(source) != os.path.abspath(target):
        print("Copying %s -> %s" % (source, target))
        shutil.copyfile(source, target)
    name = args.name
    if name is None:
        if filename.lower().endswith(".dsk.zip"):
            name = filename[: -len(".dsk.zip")]
        else:
            name = os.path.splitext(filename)[0]
    description = args.description
    if description is None:
        description = ""
    with db.connect() as conn:
        comp = db.add_component(conn, args.kind, filename, name, description)
        if comp["display_name"] != name or comp["description"] != description:
            conn.execute(
                "UPDATE components SET display_name = ?, description = ? "
                "WHERE id = ?", (name, description, comp["id"]))
            conn.commit()
    print("Registered %s #%d: %s" % (args.kind, comp["id"], name))
    return 0


def cmd_list(_args):
    with db.connect() as conn:
        for comp in db.list_components(conn):
            print("%4d  %-4s  %-30s  %10d bytes  %s" % (
                comp["id"], comp["kind"], comp["filename"],
                comp["size_bytes"], comp["display_name"]))
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("set-admin-password")
    p.add_argument("password", nargs="?", default=None)
    p.set_defaults(func=cmd_set_admin_password)

    p = sub.add_parser("has-admin-password")
    p.set_defaults(func=cmd_has_admin_password)

    p = sub.add_parser("add-component")
    p.add_argument("kind")
    p.add_argument("file")
    p.add_argument("--name", default=None)
    p.add_argument("--description", default=None)
    p.set_defaults(func=cmd_add_component)

    p = sub.add_parser("list")
    p.set_defaults(func=cmd_list)

    args = parser.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
