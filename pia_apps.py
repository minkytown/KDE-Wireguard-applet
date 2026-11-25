"""Plasma app selection and Vopono launch management."""
import base64
import dbus
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile

import gi
gi.require_version("GioUnix", "2.0")
from gi.repository import GioUnix, Gio, GLib

FLATPAK = "/usr/bin/flatpak"
APP_ID = re.compile(r"[A-Za-z0-9_.-]{1,200}")
DATA = Path(os.environ.get("XDG_DATA_HOME", str(Path.home() / ".local/share")))
SETTINGS = Path.home() / ".config/pia-wireguard/apps.json"
OVERRIDES = DATA / "flatpak/overrides"
FORMAT = re.compile(r"%[A-Za-z%]")
DESKTOP_GROUP = "Desktop Entry"
MANAGED_KEY = "X-PIA-Protected-Launcher"


class AppError(Exception):
    pass


def atomic(path, data):
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def load():
    return json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}


def save(apps):
    atomic(SETTINGS, json.dumps(apps, indent=2, ensure_ascii=False).encode())


def list_flatpaks():
    result = subprocess.check_output([FLATPAK, "list", "--app", "--columns=application,name"], text=True)
    return {id_: name for id_, name in (line.split("\t", 1) for line in result.splitlines()
                                       if "\t" in line) if APP_ID.fullmatch(id_) and not id_.startswith("-")}


def panel_state(installed):
    apps = load()
    catalog = {id_: entry["name"] for id_, entry in apps.items()
               if entry["kind"] == "Flatpak"}
    catalog.update(installed)
    rows = []
    for id_, name in sorted(catalog.items(), key=lambda item: (item[1].casefold(), item[0])):
        try:
            desktop = GioUnix.DesktopAppInfo.new(id_ + ".desktop")
        except TypeError:
            desktop = None
        rows.append({"id": id_, "name": name,
                     "icon": (desktop.get_string("Icon") if desktop else None) or id_,
                     "required": id_ in apps and apps[id_].get("mode", "vpn") == "vpn",
                     "excluded": apps.get(id_, {}).get("mode") == "direct"})
    return rows


def panel_update(id_, required, mode, installed):
    if not APP_ID.fullmatch(id_) or id_.startswith("-"):
        raise AppError("Invalid app selection.")
    if required and id_ not in installed:
        raise AppError("This Flatpak is no longer installed.")
    if required:
        add(id_, {"name": installed[id_], "kind": "Flatpak", "mode": mode})
    else:
        remove(id_, mode=mode)


def panel_response(id_=None, required=False, mode="vpn"):
    try:
        installed = list_flatpaks()
    except (OSError, subprocess.SubprocessError):
        return {"apps": None, "error": "Could not load installed apps."}
    error = ""
    try:
        if id_ is not None:
            panel_update(id_, required, mode, installed)
    except AppError as problem:
        error = str(problem)
    except (GLib.Error, OSError, ValueError, subprocess.SubprocessError):
        error = "Could not change this app’s network setting."
    try:
        rows = panel_state(installed)
    except (GLib.Error, OSError, ValueError):
        return {"apps": None, "error": error or "Could not load installed apps."}
    return {"apps": rows, "error": error}


def inventory():
    actions = {
        key: {"name": value, "kind": "Flatpak"}
        for key, value in list_flatpaks().items()
    }
    for info in Gio.AppInfo.get_all():
        id_ = info.get_id()
        if not id_ or not id_.endswith(".desktop") or not APP_ID.fullmatch(id_):
            continue
        if id_.removesuffix(".desktop") in actions or id_.startswith(("local.pia.", "pia-vopono")):
            continue
        desktop = GioUnix.DesktopAppInfo.new(id_)
        if desktop and desktop.should_show() and not desktop.get_boolean("Terminal"):
            command = desktop.get_string("Exec")
            if command and native_args(desktop, command):
                actions[id_] = {"name": desktop.get_display_name(), "kind": "Native"}
    return actions


def native_args(desktop, command):
    try:
        args = shlex.split(command)
    except ValueError:
        return []
    if not args or Path(args[0]).name in {"env", "sh", "bash", "flatpak", "gio", "xdg-open"}:
        return []
    executable = shutil.which(args[0])
    if not executable:
        return []
    result = [os.path.realpath(executable)]
    for arg in args[1:]:
        if arg in {"%u", "%U", "%f", "%F", "%i", "%d", "%D", "%n", "%N", "%v", "%m"}:
            continue
        if arg == "%c":
            result.append(desktop.get_display_name())
        elif arg == "%k":
            result.append(desktop.get_filename())
        elif FORMAT.search(arg.replace("%%", "")):
            return []
        else:
            result.append(arg.replace("%%", "%"))
    return result


def override_network(id_):
    keyfile = GLib.KeyFile()
    path = OVERRIDES / id_
    if path.exists():
        keyfile.load_from_file(str(path), GLib.KeyFileFlags.KEEP_COMMENTS)
    try:
        settings = keyfile.get_string_list("Context", "shared")
    except GLib.Error:
        settings = []
    return path, keyfile, settings


def set_network(id_, old_value=None, block=False):
    path, keyfile, settings = override_network(id_)
    if block:
        subprocess.run([FLATPAK, "override", "--user", "--unshare=network", id_], check=True)
        return
    if "!network" not in settings:
        return
    new_settings = [setting for setting in settings if setting not in {"network", "!network"}]
    if old_value:
        new_settings.append(old_value)
    if new_settings:
        keyfile.set_string_list("Context", "shared", new_settings)
    else:
        keyfile.remove_key("Context", "shared")
        if not keyfile.get_keys("Context")[0]:
            keyfile.remove_group("Context")
    if keyfile.get_groups()[0]:
        atomic(path, keyfile.to_data()[0].encode())
    else:
        path.unlink(missing_ok=True)


def desktop_path(id_):
    return DATA / "applications" / f"{id_}.desktop"


def launcher_snapshot(path):
    if path.is_symlink():
        return {"link": os.readlink(path)}
    if path.is_file():
        return {"data": base64.b64encode(path.read_bytes()).decode(),
                "mode": path.stat().st_mode & 0o777}
    return None


def write_launcher(id_, name):
    path = desktop_path(id_)
    keyfile = GLib.KeyFile()
    try:
        desktop = GioUnix.DesktopAppInfo.new(f"{id_}.desktop")
    except TypeError:
        desktop = None
    source = str(path) if path.is_file() else desktop.get_filename() if desktop else None
    if source:
        keyfile.load_from_file(source,
                               GLib.KeyFileFlags.KEEP_TRANSLATIONS | GLib.KeyFileFlags.KEEP_COMMENTS)
    else:
        keyfile.set_string(DESKTOP_GROUP, "Type", "Application")
        keyfile.set_string(DESKTOP_GROUP, "Name", name)
        keyfile.set_string(DESKTOP_GROUP, "Icon", id_)
    previous = None
    previous = launcher_snapshot(path)
    helper = str(Path(__file__).with_name("pia-vopono").resolve())
    quoted = '"' + helper.replace("\\", "\\\\").replace('"', '\\"') + '"'
    keyfile.set_string(DESKTOP_GROUP, "Exec", f"{quoted} app-launch {id_} -- %U")
    keyfile.set_boolean(DESKTOP_GROUP, "DBusActivatable", False)
    keyfile.set_boolean(DESKTOP_GROUP, "Terminal", False)
    keyfile.set_boolean(DESKTOP_GROUP, MANAGED_KEY, True)
    if "Actions" in keyfile.get_keys(DESKTOP_GROUP)[0]:
        keyfile.remove_key(DESKTOP_GROUP, "Actions")
    for group in keyfile.get_groups()[0]:
        if group.startswith("Desktop Action "):
            keyfile.remove_group(group)
    atomic(path, keyfile.to_data()[0].encode())
    return previous


def restore_launcher(id_, previous):
    path = desktop_path(id_)
    if not path.is_file() or path.is_symlink():
        return
    keyfile = GLib.KeyFile()
    keyfile.load_from_file(str(path), GLib.KeyFileFlags.NONE)
    if (MANAGED_KEY not in keyfile.get_keys(DESKTOP_GROUP)[0]
            or not keyfile.get_boolean(DESKTOP_GROUP, MANAGED_KEY)):
        return
    replace_launcher(path, previous)


def replace_launcher(path, previous):
    if previous is None:
        path.unlink(missing_ok=True)
    elif "link" in previous:
        with tempfile.TemporaryDirectory(dir=path.parent) as directory:
            temp = Path(directory) / path.name
            temp.symlink_to(previous["link"])
            temp.replace(path)
    else:
        atomic(path, base64.b64decode(previous["data"]))
        path.chmod(previous["mode"])


def check_flatpak_closed(id_, name):
    running = subprocess.check_output([FLATPAK, "ps", "--columns=application"], text=True)
    if id_ in running.splitlines():
        raise AppError(f"Quit {name}, including its tray icon, before changing its routing or opening another protected instance.")


def add(id_, info):
    with registry_lock():
        apps = load()
        if id_ in apps:
            current = apps[id_]
            mode = info.get("mode", "vpn")
            if current.get("mode", "vpn") != mode:
                check_flatpak_closed(id_, current["name"])
                current["mode"] = mode
                save(apps)
            return
        entry = dict(info)
        if entry["kind"] == "Flatpak":
            check_flatpak_closed(id_, entry["name"])
            _, _, settings = override_network(id_)
            entry["previous_network"] = next((value for value in settings
                                               if value in {"network", "!network"}), None)
            set_network(id_, block=True)
        try:
            if entry["kind"] == "Flatpak":
                entry["previous_launcher"] = write_launcher(id_, entry["name"])
            apps[id_] = entry
            save(apps)
        except (OSError, GLib.Error):
            if entry["kind"] == "Flatpak":
                if "previous_launcher" in entry:
                    restore_launcher(id_, entry["previous_launcher"])
                set_network(id_, entry["previous_network"])
            raise


def remove(id_, mode=None):
    with registry_lock():
        apps = load()
        if id_ not in apps:
            return
        entry = apps[id_]
        if mode is not None and entry.get("mode", "vpn") != mode:
            return
        flatpak = entry["kind"] == "Flatpak"
        if flatpak:
            check_flatpak_closed(id_, entry["name"])
            path = desktop_path(id_)
            managed_launcher = launcher_snapshot(path)
        del apps[id_]
        save(apps)
        if flatpak:
            try:
                if "previous_launcher" in entry:
                    restore_launcher(id_, entry["previous_launcher"])
                set_network(id_, entry["previous_network"])
            except (OSError, GLib.Error):
                apps[id_] = entry
                save(apps)
                if "previous_launcher" in entry:
                    replace_launcher(path, managed_launcher)
                raise


def registry_lock():
    SETTINGS.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    lock = SETTINGS.with_suffix(".lock").open("a")
    fcntl.flock(lock, fcntl.LOCK_EX)
    return lock


def menu(dialog, title, entries):
    values = [value for key, caption in entries for value in (key, caption)]
    return dialog("--menu", title, *values)


def select_app(dialog, entries, action, search=False):
    if not entries:
        dialog("--msgbox", "No applications are available for this action.")
        return None
    if search:
        query = dialog("--inputbox", "Search installed apps. Leave blank to show all.")
        if query is None:
            return None
        entries = {key: value for key, value in entries.items()
                   if query.casefold() in (value["name"] + " " + key).casefold()}
    if not entries:
        dialog("--msgbox", "No installed apps matched the search.")
        return None
    return menu(dialog, action,
                [(key, f'{value["name"]}  ·  {value["kind"]}')
                 for key, value in sorted(entries.items(), key=lambda item: item[1]["name"].casefold())])


def manage(api):
    dialog = api["dialog"]
    while True:
        apps = load()
        summary = ", ".join(sorted(item["name"] for item in apps.values())) or "No apps selected"
        action = menu(dialog, f"VPN-only apps\n{summary}", [
            ("add", "Add an app…"), ("remove", "Remove an app…"),
            ("launch", "Launch a VPN-only app…")])
        try:
            if action == "add":
                choices = {key: value for key, value in inventory().items() if key not in apps}
                id_ = select_app(dialog, choices, "Add a VPN-only app", search=True)
                if id_:
                    info = choices[id_]
                    if info["kind"] == "Native":
                        accepted = subprocess.run(["/usr/bin/kdialog", "--title", "VPN-only apps",
                            "--yesno", "Native apps are protected when launched from this list. "
                            "Their ordinary launchers and direct commands retain normal behavior. Add this app?"])
                        if accepted.returncode:
                            continue
                    add(id_, info)
            elif action in ("remove", "launch"):
                id_ = select_app(dialog, apps, "Remove app protection" if action == "remove"
                                 else "Launch through Vopono")
                if id_ and action == "remove":
                    remove(id_)
                elif id_:
                    launch(api, id_)
                    return
            else:
                return
        except (AppError, api["SetupError"], OSError, subprocess.SubprocessError, GLib.Error) as error:
            dialog("--error", str(error))


def flatpak_command(id_):
    text = subprocess.check_output([FLATPAK, "info", "--show-metadata", id_], text=True)
    keyfile = GLib.KeyFile()
    keyfile.load_from_data(text, len(text.encode()), GLib.KeyFileFlags.NONE)
    command = keyfile.get_string("Application", "command")
    if not re.fullmatch(r"[A-Za-z0-9_./+-]+", command) or command.startswith("-"):
        raise AppError("The Flatpak command is unsupported.")
    return command


def protected_plan(id_, info):
    if info["kind"] == "Flatpak":
        check_flatpak_closed(id_, info["name"])
        return {"kind": "Flatpak", "app": id_, "argv": [flatpak_command(id_)]}
    desktop = GioUnix.DesktopAppInfo.new(id_)
    args = native_args(desktop, desktop.get_string("Exec")) if desktop else []
    if not args:
        raise AppError("This native application no longer has a supported launch command.")
    for process in Path("/proc").iterdir():
        if not process.name.isdecimal():
            continue
        try:
            if os.readlink(process / "exe") == args[0]:
                raise AppError(f'Quit {info["name"]} before launching it through Vopono.')
        except OSError:
            continue
    return {"kind": "Native", "app": id_, "argv": args}


def launch(api, id_, probe=False, region_id=None, app_args=()):
    direct = False
    if probe:
        plan = {"kind": "Native", "app": "probe", "argv": [
            "/usr/bin/curl", "--noproxy", "*", "--ipv4", "--silent", "--show-error",
            "--fail", "--output", "/dev/null", "--max-time", "12",
            "--write-out", "Vopono HTTPS %{http_code}, TLS %{ssl_verify_result}\\n",
            "https://www.cloudflare.com/cdn-cgi/trace"]}
    else:
        entries = load()
        if id_ not in entries:
            raise AppError("Add this app to the VPN-only list first.")
        entry = entries[id_]
        direct = entry.get("mode") == "direct"
        plan = protected_plan(id_, entry)
        if plan["kind"] == "Flatpak":
            bus = dbus.SessionBus()
            monitor = bus.get_object("org.freedesktop.Flatpak", "/org/freedesktop/Flatpak/SessionHelper")
            monitor.RequestSession(dbus_interface="org.freedesktop.Flatpak.SessionHelper")
            if id_ == api["APP"] and os.environ.get("QBT_PROFILE"):
                plan["argv"].append("--profile=" + os.environ["QBT_PROFILE"])
            plan["argv"].extend(app_args)
    if not direct and api["kill_switch_on"]() and not api["interface_exists"]():
        raise AppError("Connect the system-wide PIA tunnel before launching a VPN-only app.")
    if not region_id and api["interface_exists"]() and api["desktop_state"]().exists():
        location = json.loads(api["desktop_state"]().read_text())["region"]
        region_id = next((row["id"] for row in api["locations_json"]() if row["name"] == location), None)
    if not region_id:
        region_id = "us_new_york_city"
    if probe:
        print("Testing HTTPS in a systemd-managed Vopono namespace.", flush=True)
    session = {key: os.environ[key] for key in (
        "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "LANG", "LC_ALL", "XDG_CURRENT_DESKTOP",
        "XDG_SESSION_TYPE", "QT_QPA_PLATFORM", "PIPEWIRE_REMOTE", "PULSE_SERVER")
        if key in os.environ}
    if direct:
        api["service_request"]("launch-direct", plan=plan, session=session)
    else:
        user, password = api["read_login"]()
        api["service_request"]("launch", plan=plan, region=region_id, user=user,
                               password=password, session=session, diagnostic=probe)
    if probe:
        print("Protected HTTPS passed.")


def inside(api, encoded_plan, interface):
    if os.geteuid() == 0:
        raise AppError("Protected apps cannot run as root.")
    plan = json.loads(base64.urlsafe_b64decode(encoded_plan))
    plan["interface"] = interface
    if os.readlink("/proc/self/ns/net") == plan["host_net"]:
        raise AppError("Refusing to start an app outside its protected namespace.")
    dns = {" ".join(line.split()) for line in Path("/etc/resolv.conf").read_text().splitlines()}
    if not all(f"nameserver {value}" in dns for value in plan["dns"]):
        raise AppError("The Vopono namespace is missing its private DNS configuration.")
    if plan["kind"] == "Flatpak":
        id_, command = plan["app"], plan["argv"][0]
        check_flatpak_closed(id_, id_)
        diagnostic = plan["argv"][1:] == ["--version"]
        if id_ == api["APP"] and not diagnostic:
            api["clear_old_qbittorrent_binding"]()
        # The Flatpak must inherit the Vopono namespace and its DNS file.
        check = r'''
set -eu
if ! grep -Eq "^[[:space:]]*$1:" /proc/net/dev; then
    echo "The Flatpak did not inherit the Vopono WireGuard interface." >&2
    exit 1
fi
shift
command=$1
shift
while [ "$1" != "--" ]; do
    dns=$1
    if ! awk -v server="$dns" '$1 == "nameserver" && $2 == server { found = 1 }
                              END { exit !found }' /etc/resolv.conf; then
        echo "The Flatpak did not inherit the Vopono DNS configuration." >&2
        exit 1
    fi
    shift
done
shift
exec "$command" "$@"
'''
        arguments = plan["argv"][1:]
        forwarding = []
        if arguments and all(re.match(r"^(?:/|[A-Za-z][A-Za-z0-9+.-]*:)", arg) for arg in arguments):
            forwarding = ["--file-forwarding"]
            arguments = ["@@u", *arguments, "@@"]
        os.execv(FLATPAK, [FLATPAK, "run", "--share=network", "--nosocket=session-bus",
                          "--nosocket=system-bus", "--no-talk-name=org.freedesktop.Flatpak",
                          *forwarding, "--command=sh", id_, "-c",
                          check, "pia-app", plan["interface"], command, *plan["dns"], "--",
                          *arguments])
    env = dict(os.environ)
    env.pop("DBUS_SESSION_BUS_ADDRESS", None)
    env["DBUS_SYSTEM_BUS_ADDRESS"] = "unix:path=/run/pia-vopono-no-system-bus"
    os.execve("/usr/bin/dbus-run-session",
              ["/usr/bin/dbus-run-session", "--", *plan["argv"]], env)
