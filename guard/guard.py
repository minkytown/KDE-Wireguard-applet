"""Root-only PIA session manager and boot firewall loader."""
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache
import fcntl
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import runpy
import socket
import ssl
import subprocess
import sys
import time
from urllib.parse import urlencode

BASE = Path(__file__).resolve().parent
RUNTIME = Path("/run/pia-desktop")
PROFILE = RUNTIME / "piadesk.conf"
STOPPED = RUNTIME / "disconnect-requested"
RECONNECTING = Path("/run/pia-vopono/reconnecting")
HANDSHAKE_TIMEOUT = 240
STARTUP_GRACE = 35
RETRY_DELAY = 30
NFT = "/usr/bin/nft"
IP = "/usr/sbin/ip"
WG = "/usr/bin/wg"
WGQUICK = "/usr/bin/wg-quick"
SOCKET_MARK = 0x504941
IFACE = "piadesk"
OFF = BASE / "kill-switch.off"
RESOLVERS = ("1.1.1.1", "1.0.0.1")
PIA = runpy.run_path(str(BASE / "pia-vopono"))
ERROR = PIA["SetupError"]
API_HOSTS = {PIA["TOKEN_HOST"], PIA["LIST_HOST"]}


def run(*args, data=None, capture=False, check=True):
    return subprocess.run(args, input=data, capture_output=capture, text=True, check=check)


def nft(batch, check=True):
    args = (NFT, "-c", "-f", "-") if not check else (NFT, "-f", "-")
    run(*args, data=batch)


def endpoint(value):
    ip, port = value.strip().rsplit(":", 1)
    address = ipaddress.IPv4Address(ip)
    port = int(port)
    if not 1 <= port <= 65535:
        raise ValueError("Invalid peer port")
    return str(address), port


def element(pair):
    ip, port = endpoint(f"{pair[0]}:{pair[1]}")
    return f"{ip} . {port}"


def current_peers():
    if not Path(f"/sys/class/net/{IFACE}").exists():
        return []
    mark = run(WG, "show", IFACE, "fwmark", capture=True).stdout.strip()
    if mark != hex(51820):
        raise ERROR("The existing PIA tunnel uses an unexpected WireGuard mark.")
    lines = run(WG, "show", IFACE, "endpoints", capture=True).stdout.splitlines()
    return [endpoint(line.split()[1]) for line in lines]


def manager_lock(nonblocking=False):
    RUNTIME.mkdir(mode=0o700, exist_ok=True)
    lock = (RUNTIME / "manager.lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0))
    except OSError:
        lock.close()
        raise
    return lock


def direct_record(name):
    if not re.fullmatch(r"piaa[0-9a-f]{6}", name):
        raise ERROR("Invalid exclusion session.")
    return RUNTIME / f"direct-{name}.json"


def direct_elements():
    pairs = set()
    for path in RUNTIME.glob("direct-piaa*.json"):
        try:
            veth, physical, veth_index, physical_index = json.loads(path.read_text())
            if (socket.if_nametoindex(veth) == veth_index
                    and socket.if_nametoindex(physical) == physical_index
                    and Path(f"/sys/class/net/{physical}/device").exists()):
                pairs.add((veth_index, physical_index))
        except (OSError, TypeError, ValueError):
            continue
    if not pairs:
        return ""
    return "add element inet pia_guard direct { " + ", ".join(
        f"{incoming} . {outgoing}" for incoming, outgoing in sorted(pairs)
    ) + " }\n"


def register_direct(name, veth, physical):
    record = direct_record(name)
    with manager_lock():
        veth_index = socket.if_nametoindex(veth)
        physical_index = socket.if_nametoindex(physical)
        if veth_index == physical_index or not Path(f"/sys/class/net/{physical}/device").exists():
            raise ERROR("The exclusion uplink is not a separate physical interface.")
        with record.open("x") as stream:
            json.dump([veth, physical, veth_index, physical_index], stream)
        try:
            nft("flush set inet pia_guard direct\n" + direct_elements())
        except (OSError, subprocess.SubprocessError):
            record.unlink(missing_ok=True)
            raise


def unregister_direct(name):
    with manager_lock():
        direct_record(name).unlink(missing_ok=True)
        nft("flush set inet pia_guard direct\n" + direct_elements())


def firewall(check=False):
    peers = current_peers()
    batch = (BASE / "pia-guard.nft").read_text() + direct_elements()
    if peers:
        batch += "add element inet pia_guard peer { " + ", ".join(map(element, peers)) + " }\n"
    if OFF.exists():
        batch += 'insert rule inet pia_guard output accept comment "System kill switch off"\n'
        batch += 'insert rule inet pia_guard forward accept comment "System kill switch off"\n'
    if check:
        nft(batch, check=False)
        return
    rules = json.loads(run(IP, "-j", "-4", "rule", "show", capture=True).stdout)
    existing = [rule for rule in rules if rule["priority"] == 101]
    if not existing:
        run(IP, "-4", "rule", "add", "pref", "101", "fwmark", hex(SOCKET_MARK), "lookup", "main")
    elif existing != [{"priority": 101, "src": "all", "fwmark": hex(SOCKET_MARK), "table": "main"}]:
        raise ERROR("Routing rule priority 101 is already in use.")
    nft(batch)


def set_kill_switch(enabled):
    previous = OFF.exists()
    if not enabled:
        OFF.touch()
    else:
        OFF.unlink(missing_ok=True)
    try:
        firewall()
    except (OSError, subprocess.SubprocessError, ERROR):
        if previous:
            OFF.touch()
        else:
            OFF.unlink(missing_ok=True)
        raise


def allow_bootstrap(pairs):
    batch = "flush set inet pia_guard bootstrap\n"
    if pairs:
        batch += "add element inet pia_guard bootstrap { " + ", ".join(
            sorted({element(pair) for pair in pairs})
        ) + " }\n"
    nft(batch)


def socket_to(ip, port, timeout):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_MARK, SOCKET_MARK)
        sock.settimeout(timeout)
        sock.connect((ip, port))
        return sock
    except BaseException:
        sock.close()
        raise


@lru_cache(maxsize=2)
def tls_context(pia_ca=False):
    context = ssl.create_default_context(cafile=str(BASE / "pia-ca.crt") if pia_ca else None)
    if pia_ca:
        context.verify_flags &= ~ssl.VERIFY_X509_STRICT
    return context


class BootstrapHTTPS(http.client.HTTPSConnection):
    def __init__(self, host, ip, port=443, pia_ca=False):
        super().__init__(host, port, timeout=7, context=tls_context(pia_ca))
        self.ip = ip

    def connect(self):
        sock = socket_to(self.ip, self.port, self.timeout)
        try:
            self.sock = self._context.wrap_socket(sock, server_hostname=self.host)
        except BaseException:
            sock.close()
            raise


def resolve_pia(host):
    if host not in API_HOSTS:
        raise ERROR("Unapproved bootstrap hostname.")
    for address in RESOLVERS:
        try:
            response = PIA["request"](
                BootstrapHTTPS("cloudflare-dns.com", address), "GET",
                "/dns-query?" + urlencode({"name": host, "type": "A"}),
                headers={"Accept": "application/dns-json"},
            )
            ips = [str(ipaddress.IPv4Address(item["data"]))
                   for item in response.get("Answer", []) if item["type"] == 1]
            if ips:
                return ips
        except (OSError, ValueError, http.client.HTTPException, ERROR):
            continue
    raise ERROR(f"Could not resolve the PIA bootstrap host {host}.")


def probe(candidate):
    start = time.monotonic()
    try:
        with socket_to(candidate["ip"], 1337, 0.85):
            return time.monotonic() - start
    except OSError:
        return float("inf")


def ordered_candidates(regions, requested, api_pairs):
    if requested != "optimal":
        matches = [region for region in regions if region["id"] == requested]
        if not matches:
            raise ERROR("The selected PIA location is unavailable.")
        region = matches[0]
        return [(region, candidate) for candidate in region["servers"]["wg"][:5]]
    candidates = []
    for region in regions:
        if region.get("auto_region") and not region.get("geo"):
            candidates.append((region, region["servers"]["wg"][0]))
    if not candidates:
        candidates = [(region, region["servers"]["wg"][0]) for region in regions]
    allow_bootstrap(api_pairs + [(item["ip"], 1337) for _, item in candidates])
    with ThreadPoolExecutor(max_workers=32) as workers:
        times = list(workers.map(probe, (item for _, item in candidates)))
    reachable = [(elapsed, pair) for elapsed, pair in zip(times, candidates) if elapsed < float("inf")]
    if not reachable:
        raise ERROR("No PIA location responded to the Optimal latency probe.")
    return [pair for _, pair in sorted(reachable, key=lambda item: item[0])[:5]]


def connect_host(host, addresses, action):
    for address in addresses[:4]:
        try:
            return action(BootstrapHTTPS(host, address))
        except (OSError, http.client.HTTPException, ValueError, ERROR):
            continue
    raise ERROR(f"PIA did not respond at {host}. Check the network and PIA login.")


def token_for(payload, addresses):
    return connect_host(PIA["TOKEN_HOST"], addresses, lambda connection: PIA["token_for"](
        payload["user"], payload["password"], connection=connection))


def resolver_pairs():
    return [(address, 443) for address in RESOLVERS]


def validate_login(payload):
    allow_bootstrap(resolver_pairs())
    try:
        addresses = resolve_pia(PIA["TOKEN_HOST"])
        allow_bootstrap([(address, 443) for address in addresses])
        token_for(payload, addresses)
    finally:
        allow_bootstrap([])


def fetch_regions(addresses):
    return PIA["regions_from"](connect_host(PIA["LIST_HOST"], addresses,
        lambda connection: PIA["request"](connection, "GET",
            "/vpninfo/servers/v6", first_line=True)))


def catalog():
    allow_bootstrap(resolver_pairs())
    try:
        addresses = resolve_pia(PIA["LIST_HOST"])
        allow_bootstrap([(address, 443) for address in addresses])
        return PIA["catalog_from"](fetch_regions(addresses))
    finally:
        allow_bootstrap([])


def profile_for(payload):
    allow_bootstrap(resolver_pairs())
    with ThreadPoolExecutor(max_workers=2) as workers:
        token_ips, list_ips = workers.map(resolve_pia, (PIA["TOKEN_HOST"], PIA["LIST_HOST"]))
        api_pairs = [(address, 443) for address in token_ips + list_ips]
        allow_bootstrap(api_pairs)
        regions_request = workers.submit(fetch_regions, list_ips)
        token = token_for(payload, token_ips)
        regions = regions_request.result()
    candidates = ordered_candidates(regions, payload["region"], api_pairs)
    allow_bootstrap([(site["ip"], 1337) for _, site in candidates])
    keys = PIA["wireguard_keys"]()
    for region, site in candidates:
        try:
            config, dns = PIA["wireguard_config"]({"servers": {"wg": [site]}}, token,
                connection_factory=lambda name, ip: BootstrapHTTPS(name, ip, 1337, pia_ca=True),
                keys=keys)
            return PIA["system_profile"](config, dns), region["name"], PIA["catalog_from"](regions)
        except ERROR:
            continue
    raise ERROR("PIA WireGuard registration failed for the selected candidates.")


def set_peers(peers):
    batch = "flush set inet pia_guard peer\n"
    if peers:
        batch += "add element inet pia_guard peer { " + ", ".join(map(element, peers)) + " }\n"
    nft(batch)


def bring_up(config, peers):
    set_peers(peers)
    temporary = PROFILE.with_suffix(".new")
    temporary.write_text(config)
    temporary.replace(PROFILE)
    result = run(WGQUICK, "up", str(PROFILE), capture=True, check=False)
    if result.returncode:
        if Path(f"/sys/class/net/{IFACE}").exists():
            run(WGQUICK, "down", str(PROFILE), capture=True)
        raise ERROR("wg-quick could not bring up the PIA tunnel.")


def profile_endpoint(config):
    match = re.search(r"(?m)^Endpoint = (.+)$", config)
    if match is None:
        raise ERROR("The saved PIA profile has no WireGuard endpoint.")
    return endpoint(match[1])


def clean_missing_interface():
    # A deleted link removes its routes, but bypasses wg-quick's rule cleanup.
    # It adds the suppression rule immediately above its marked rule.
    for family in ("-4", "-6"):
        rules = json.loads(run(IP, "-j", family, "rule", "show", capture=True).stdout)
        for rule in rules:
            if (str(rule.get("table")) != "51820" or rule.get("fwmark") != hex(51820)
                    or "not" not in rule):
                continue
            priority = rule["priority"]
            if any(other["priority"] == priority - 1 and other.get("table") == "main"
                   and other.get("suppress_prefixlen") == 0 for other in rules):
                run(IP, family, "rule", "del", "pref", str(priority - 1),
                    "lookup", "main", "suppress_prefixlength", "0")
            run(IP, family, "rule", "del", "pref", str(priority), "not", "fwmark",
                "51820", "lookup", "51820")
    nft("destroy table ip wg-quick-piadesk\ndestroy table ip6 wg-quick-piadesk\n")


def reconnect():
    if not PROFILE.is_file() or STOPPED.exists():
        return
    now = time.time()
    present = PIA["interface_exists"]()
    if present:
        links = json.loads(run(IP, "-j", "link", "show", "dev", IFACE, capture=True).stdout)
        if "UP" in links[0]["flags"]:
            output = run(WG, "show", IFACE, "latest-handshakes", capture=True).stdout
            last = max((int(line.split()[1]) for line in output.splitlines()), default=0)
            if last and 0 <= now - last < HANDSHAKE_TIMEOUT:
                if RECONNECTING.exists():
                    RECONNECTING.unlink()
                    print("PIA WireGuard handshake recovered.", flush=True)
                return
            if not last and now - PROFILE.stat().st_mtime < STARTUP_GRACE:
                return
    if RECONNECTING.exists() and now - RECONNECTING.stat().st_mtime < RETRY_DELAY:
        return
    RECONNECTING.touch()
    print("PIA WireGuard recovery started.", flush=True)
    config = PROFILE.read_text()
    peer = profile_endpoint(config)
    if present:
        run(WGQUICK, "down", str(PROFILE), capture=True)
    else:
        clean_missing_interface()
    bring_up(config, [peer])


def switch(payload):
    # Prepare the replacement while the current tunnel is still up.
    try:
        config, region, locations = profile_for(payload)
    finally:
        allow_bootstrap([])
    peer = profile_endpoint(config)
    previous = None
    if Path(f"/sys/class/net/{IFACE}").exists():
        previous = (PROFILE.read_text(), current_peers())
        run(WGQUICK, "down", str(PROFILE), capture=True)
    elif PROFILE.is_file():
        clean_missing_interface()
    try:
        bring_up(config, [peer])
    except (OSError, subprocess.SubprocessError, ERROR) as error:
        if Path(f"/sys/class/net/{IFACE}").exists():
            raise ERROR("Could not clean up the replacement PIA tunnel.") from error
        if previous:
            try:
                bring_up(*previous)
            except (OSError, subprocess.SubprocessError, ERROR):
                if not Path(f"/sys/class/net/{IFACE}").exists():
                    PROFILE.unlink(missing_ok=True)
                    set_peers([])
                raise ERROR("The replacement and previous PIA tunnels could not be started.") from error
            raise ERROR("Could not start the replacement PIA tunnel. Restored the previous connection.") from error
        PROFILE.unlink(missing_ok=True)
        set_peers([])
        raise ERROR("Could not start the PIA tunnel.") from error
    STOPPED.unlink(missing_ok=True)
    RECONNECTING.unlink(missing_ok=True)
    return {"region": region, "locations": locations}


def disconnect():
    STOPPED.touch()
    RECONNECTING.unlink(missing_ok=True)
    if Path(f"/sys/class/net/{IFACE}").exists():
        run(WGQUICK, "down", str(PROFILE), capture=True)
    elif PROFILE.is_file():
        clean_missing_interface()
    PROFILE.unlink(missing_ok=True)
    STOPPED.unlink(missing_ok=True)
    set_peers([])


def disconnect_open():
    disconnect()
    if not OFF.exists():
        set_kill_switch(False)


def main():
    if os.geteuid() != 0 or len(sys.argv) != 2:
        raise ERROR("Administrator authorization is required.")
    os.umask(0o077)
    action = sys.argv[1]
    if action == "reconnect":
        try:
            lock = manager_lock(nonblocking=True)
        except BlockingIOError:
            return
        with lock:
            reconnect()
        return
    with manager_lock():
        if action in ("firewall", "check"):
            firewall(check=action == "check")
        elif action == "disconnect":
            disconnect()
        elif action == "disconnect-open":
            disconnect_open()
        elif action in ("kill-on", "kill-off"):
            set_kill_switch(action == "kill-on")
        elif action == "switch":
            payload = json.loads(sys.stdin.read(8192))
            if not re.fullmatch(r"[a-zA-Z0-9_-]{1,64}", payload["region"]):
                raise ERROR("Invalid region identifier.")
            print(json.dumps(switch(payload)))
        else:
            raise ERROR("Unsupported PIA operation.")


if __name__ == "__main__":
    try:
        main()
    except ERROR as error:
        print(error, file=sys.stderr)
        sys.exit(1)
    except (OSError, KeyError, ValueError, subprocess.SubprocessError):
        print("PIA system operation failed. The kill switch was not disabled.", file=sys.stderr)
        sys.exit(1)
