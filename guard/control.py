"""A bounded, single-request systemd service for the authorized desktop user."""
import base64
from concurrent.futures import ThreadPoolExecutor
import contextlib
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import runpy
import select
import signal
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
from threading import Event, Thread
import time

BASE = Path(__file__).resolve().parent
RUNTIME = Path("/run/pia-vopono")
NETNS_HELPER = BASE / "app-netns"
GUARD = runpy.run_path(str(BASE / "guard.py"))
PIA = GUARD["PIA"]
ERROR = GUARD["ERROR"]
CONTROL_SOCKET = RUNTIME / "control.sock"
APP_ID = re.compile(r"[A-Za-z0-9_.][A-Za-z0-9_.-]{0,199}")
REGION_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
SESSION_KEYS = {
    "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "LANG", "LC_ALL", "XDG_CURRENT_DESKTOP",
    "XDG_SESSION_TYPE", "QT_QPA_PLATFORM", "PIPEWIRE_REMOTE", "PULSE_SERVER",
}


def send(connection, data):
    connection.sendall(json.dumps(data, ensure_ascii=False).encode() + b"\n")


def credentials(data):
    user, password = data["user"], data["password"]
    if not isinstance(user, str) or not re.fullmatch(r"p[0-9]{1,20}", user) or not isinstance(password, str):
        raise ERROR("Invalid PIA login input.")
    if not 1 <= len(password) <= 512 or any(character in password for character in "\r\n\0"):
        raise ERROR("Invalid PIA login input.")
    return user, password


def region_id(data):
    region = data["region"]
    if not isinstance(region, str) or not REGION_ID.fullmatch(region):
        raise ERROR("Invalid PIA location.")
    return region


def system_action(data):
    action = data["action"]
    if action in ("switch", "validate-login"):
        credentials(data)
    if action == "switch":
        region_id(data)
    with GUARD["manager_lock"]():
        if action == "switch":
            return GUARD["switch"](data)
        if action == "locations":
            return {"locations": GUARD["catalog"]()}
        if action == "validate-login":
            GUARD["validate_login"](data)
        elif action == "disconnect":
            GUARD["disconnect"]()
        elif action == "disconnect-open":
            GUARD["disconnect_open"]()
        else:
            GUARD["set_kill_switch"](action == "kill-on")
    return {}


def app_plan(data, dns):
    plan = data["plan"]
    session = data.get("session", {})
    if not isinstance(plan, dict) or not isinstance(session, dict):
        raise ERROR("Invalid app launch request.")
    app, kind, argv = plan["app"], plan["kind"], plan["argv"]
    if kind not in ("Flatpak", "Native") or not isinstance(app, str) or not APP_ID.fullmatch(app):
        raise ERROR("Invalid protected app.")
    if not isinstance(argv, list) or not 1 <= len(argv) <= 48 or any(
            not isinstance(arg, str) or "\0" in arg or len(arg) > 2048 for arg in argv):
        raise ERROR("Invalid app launch arguments.")
    session = {key: value for key, value in session.items()
               if key in SESSION_KEYS and isinstance(value, str) and "\0" not in value and len(value) <= 1024}
    return {
        "app": app, "kind": kind, "argv": argv, "dns": dns, "session": session,
        "host_net": os.readlink("/proc/self/ns/net"),
    }


def log_output(process, name, ready):
    for line in process.stdout:
        print(line.rstrip(), file=sys.stderr, flush=True)
        if f"Created netns {name} -" in line:
            ready.set()


def vopono_profile(data):
    user, password = credentials(data)
    requested = region_id(data)
    with ThreadPoolExecutor(max_workers=2) as workers:
        regions = workers.submit(PIA["live_regions"])
        token = PIA["token_for"](user, password)
        region = next((item for item in regions.result() if item["id"] == requested), None)
    if region is None:
        raise ERROR("The requested Vopono location is unavailable.")
    return PIA["wireguard_config"](region, token)


def physical_uplink():
    routes = json.loads(GUARD["run"]("/usr/sbin/ip", "-j", "-4", "route", "show",
                                    "table", "main", "default", capture=True).stdout)
    for route in sorted(routes, key=lambda item: item.get("metric", 0)):
        dev = route.get("dev", "")
        if valid_interface(dev) and Path(f"/sys/class/net/{dev}/device").exists():
            dns_result = GUARD["run"]("/usr/bin/resolvectl", "dns", dev, capture=True, check=False)
            if dns_result.returncode:
                continue
            servers = []
            for word in dns_result.stdout.partition(":")[2].split():
                try:
                    address = ipaddress.IPv4Address(word)
                except ValueError:
                    continue
                if not address.is_loopback and not address.is_unspecified and not address.is_multicast:
                    servers.append(str(address))
            if servers:
                return dev, servers[:3]
    raise ERROR("No physical IPv4 uplink with DNS is available for this excluded app.")


def valid_interface(name):
    return re.fullmatch(r"[A-Za-z0-9_-]{1,15}", name) is not None


@contextlib.contextmanager
def direct_route(name, physical):
    if not valid_interface(physical) or not re.fullmatch(r"piaa[0-9a-f]{6}", name):
        raise ERROR("Invalid interface for the VPN exclusion.")
    ip = "/usr/sbin/ip"
    inside = json.loads(GUARD["run"](ip, "-n", name, "-j", "-d", "link", capture=True).stdout)
    veths = [link["link_index"] for link in inside
             if link.get("linkinfo", {}).get("info_kind") == "veth"]
    outside = json.loads(GUARD["run"](ip, "-j", "-d", "link", capture=True).stdout)
    peers = [link["ifname"] for link in outside if link["ifindex"] in veths
             and link.get("linkinfo", {}).get("info_kind") == "veth"]
    if len(peers) != 1 or not valid_interface(peers[0]):
        raise ERROR("Could not identify the excluded app’s host veth.")
    veth = peers[0]
    rules = ["pref", "102", "iif", veth, "lookup", "main"]
    table = f"pia_direct_{name}"
    # Route excluded ingress past wg-quick's unmarked default rule even
    # when wg-quick changes its rule priorities during a reconnect.
    GUARD["nft"](f'''
table inet {table} {{
    chain prerouting {{
        type filter hook prerouting priority -140; policy accept;
        iifname "{veth}" meta nfproto ipv4 meta mark set 51820
    }}
    chain forward {{
        type filter hook forward priority -20; policy accept;
        iifname "{veth}" meta nfproto ipv6 drop
        iifname "{veth}" oifname != "{physical}" counter drop
        iifname "{veth}" meta mark set 0
    }}
    chain input {{
        type filter hook input priority -20; policy accept;
        iifname "{veth}" counter drop
    }}
}}
''')
    rule_added = False
    exception_added = False
    try:
        GUARD["run"](ip, "-4", "rule", "add", *rules)
        rule_added = True
        GUARD["register_direct"](name, veth, physical)
        exception_added = True
        yield
    finally:
        # Remove this session's only host uplink before releasing its firewall.
        # The application may have left children in the namespace.
        deleted = GUARD["run"](ip, "link", "del", veth, check=False, capture=True)
        if deleted.returncode and GUARD["run"](
                ip, "link", "show", "dev", veth, check=False, capture=True).returncode == 0:
            raise ERROR("The exclusion firewall was retained because the app uplink still exists.")
        if rule_added:
            GUARD["run"](ip, "-4", "rule", "del", *rules, check=False)
        if exception_added:
            GUARD["unregister_direct"](name)
        GUARD["nft"](f"destroy table inet {table}\n")


def protected_app(connection, data, uid, direct=False):
    connected = PIA["interface_exists"]()
    switch_on = PIA["managed_guard"]() and not GUARD["OFF"].exists()
    if direct:
        physical, dns = physical_uplink()
        profile = None
    else:
        if switch_on and not connected:
            raise ERROR("Connect the system-wide VPN before launching this app.")
        profile, dns = vopono_profile(data)
    plan = app_plan(data, dns)
    plan["direct"] = direct
    if direct and plan["kind"] != "Flatpak":
        raise ERROR("The exclusions list supports Flatpak applications.")
    with tempfile.TemporaryDirectory(prefix="app-", dir=RUNTIME) as directory:
        work = Path(directory)
        if profile is not None:
            (work / "pia.conf").write_text(profile)
        (work / "vopono.toml").touch()
        if plan["kind"] == "Flatpak":
            monitor = work / "monitor"
            monitor.mkdir(mode=0o755)
            for file in ("host.conf", "gai.conf", "hosts"):
                source = Path("/etc") / file
                if source.is_file():
                    shutil.copyfile(source, monitor / file)
                    (monitor / file).chmod(0o444)
            resolver = monitor / "resolv.conf"
            resolver.write_text("".join(f"nameserver {server}\n" for server in dns))
            resolver.chmod(0o444)
            monitor.chmod(0o555)
            plan["monitor"] = str(monitor)
        payload = base64.urlsafe_b64encode(json.dumps(plan).encode()).decode()
        name = "piaa" + os.urandom(3).hex()
        uplink = ["--interface", physical] if direct else ["--interface", "piadesk"] if connected else []
        options = ["--protocol", "none", "--provider", "none",
                   *[option for server in dns for option in ("--dns", server)]] if direct else [
            "--protocol", "wireguard", "--provider", "custom", "--custom", str(work / "pia.conf")]
        # Vopono scans for abandoned namespaces before registering its own.
        with (RUNTIME / "vopono-start.lock").open("a") as startup, contextlib.ExitStack() as cleanup:
            fcntl.flock(startup, fcntl.LOCK_EX)
            vpn = cleanup.enter_context(subprocess.Popen([
                str(BASE / "vopono"), "exec", *options, "--firewall", "nftables", "--disable-ipv6",
                "--vopono-config", str(work / "vopono.toml"), "--custom-netns-name", name,
                "--create-netns-only", *uplink, "none",
            ], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
            try:
                ready = Event()
                Thread(target=log_output, args=(vpn, name, ready), daemon=True).start()
                deadline = time.monotonic() + 25
                while not ready.wait(0.2):
                    if vpn.poll() is not None:
                        raise ERROR("Vopono could not configure the namespace. Check the system journal.")
                    if time.monotonic() >= deadline:
                        raise ERROR("Vopono timed out establishing the app namespace.")
                fcntl.flock(startup, fcntl.LOCK_UN)
                if direct:
                    cleanup.enter_context(direct_route(name, physical))
                app_env = {"VOPONO_NS": name, "PATH": "/usr/bin:/usr/sbin"}
                with subprocess.Popen([
                    "/usr/sbin/ip", "netns", "exec", name, str(NETNS_HELPER), str(uid), payload,
                ], env=app_env, stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr) as app:
                    try:
                        if data.get("diagnostic") is True:
                            status = app.wait(timeout=20)
                            if status:
                                raise ERROR("The protected app probe failed. Check the system journal.")
                            send(connection, {"ok": True})
                        else:
                            try:
                                status = app.wait(timeout=3)
                            except subprocess.TimeoutExpired:
                                status = None
                            if status:
                                raise ERROR("The app exited during protected startup. Check the PIA request log.")
                            send(connection, {"ok": True})
                            app.wait()
                    finally:
                        if app.poll() is None:
                            app.terminate()
            finally:
                if vpn.poll() is None:
                    vpn.send_signal(signal.SIGINT)
                    try:
                        vpn.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        vpn.kill()


def read_request(connection):
    deadline = time.monotonic() + 10
    message = bytearray()
    while len(message) <= 65536:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([connection], [], [], remaining)[0]:
            break
        chunk = connection.recv(min(8192, 65537 - len(message)))
        if not chunk:
            break
        message.extend(chunk)
        if b"\n" in chunk:
            line, _, trailing = message.partition(b"\n")
            if not trailing and len(line) < 65536:
                data = json.loads(line)
                if isinstance(data, dict):
                    return data
            break
    raise ERROR("Invalid or incomplete PIA request.")


def main():
    with socket.socket(fileno=0) as connection:
        try:
            connection.settimeout(10)
            _, uid, _ = struct.unpack("3i", connection.getsockopt(
                socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
            if uid == 0 or uid != CONTROL_SOCKET.stat().st_uid:
                raise ERROR("This user is not authorized to manage PIA.")
            data = read_request(connection)
            action = data["action"]
            if action == "status":
                send(connection, {"ok": True})
            elif action in ("switch", "disconnect", "disconnect-open", "kill-on", "kill-off", "validate-login", "locations"):
                send(connection, {"ok": True, **system_action(data)})
            elif action == "launch":
                protected_app(connection, data, uid)
            elif action == "launch-direct":
                protected_app(connection, data, uid, direct=True)
            else:
                raise ERROR("Unsupported PIA request.")
        except ERROR as error:
            with contextlib.suppress(OSError):
                send(connection, {"ok": False, "error": str(error)})
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            print(f"PIA request failed: {type(error).__name__}", file=sys.stderr)
            with contextlib.suppress(OSError):
                send(connection, {"ok": False, "error": "PIA service failed. Check the system journal."})


if __name__ == "__main__":
    main()
