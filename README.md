# KDE Wireguard applet

An independent KDE Plasma 6 applet for Private Internet Access on Bazzite.
It manages a system-wide WireGuard tunnel, a persistent nftables kill switch,
automatic reconnection, and per-app routing for Flatpaks.

## Install

Download the `kde-wireguard-applet-*.tar.gz` installer bundle from the
[latest GitHub release](https://github.com/minkytown/KDE-Wireguard-applet/releases/latest)
and extract it. The release page has step-by-step instructions and a SHA-256
checksum.

Use a recent Bazzite KDE image with Plasma 6, Plasma5Support, KWallet, KDialog,
Flatpak, WireGuard tools, nftables, and an active systemd-resolved service.
The system Python needs the `dbus` and `gi` modules with the GioUnix typelib.
The installer checks the command-line and Python dependencies before installing.
The integration was developed on Bazzite with [Vopono 1.0.2](https://github.com/jamesmcm/vopono/releases/tag/1.0.2).

Download a standalone Vopono CLI binary for your architecture from that release,
make it executable, and open Konsole in the extracted applet folder. Run the
installer as the account that runs Plasma.

```sh
chmod +x /path/to/vopono
./install.sh /path/to/vopono
```

The installer uses administrator authorization to install the system services
and permits one desktop account to use the control socket. A fresh install
enables the system kill switch. Ordinary internet access pauses until you
connect or turn the switch off. Both location discovery and PIA login work
with the switch on.

Enter Plasma edit mode and choose **Add Widgets**. Add **KDE Wireguard applet** to
each panel where you want it. Open the applet, choose **PIA Credentials…**,
then select a location. To update an existing installation, close routed apps,
disconnect, and run the installer from the new release bundle.

## Connect and switch locations

Select **PIA** beside any panel clock. Search by country or location, or choose
**Optimal** to try the lowest-latency eligible locations first. **PIA
Credentials…** verifies your VPN login and saves it in KDE Wallet. **Disconnect**
takes the host tunnel down before disabling the kill switch so ordinary internet
access resumes. It also works when the tunnel is already down and the switch
is on.
Use **System kill switch** to control host-wide blocking. Turning it off allows
ordinary host networking when disconnected. The setting persists across
reboots, and each protected Flatpak retains its separate network policy.

Routine connections and app launches use the socket-activated
`pia-control.socket` systemd service. Installation requires one-time KDE
administrator authorization. The socket accepts requests from the authorized
desktop account, and Vopono launches apps as that account. The service keeps
temporary WireGuard keys and profiles in root-owned runtime storage. When
the kill switch is active, the service makes narrowly scoped requests to
validate wallet credentials and register the tunnel.

The systemd reconnect timer checks the active WireGuard profile every ten
seconds. It restarts a missing or down interface and retries when WireGuard
handshakes have gone stale. **Disconnect** cancels this recovery. Recovery uses
the existing endpoint and key during the current boot. If the endpoint stays
unavailable, select another location in the applet. A replacement that fails
during WireGuard setup triggers an attempt to restore the previous tunnel.
While the system kill switch is on, ordinary traffic remains blocked when the
tunnel is down and excluded Flatpaks retain their direct route.

## VPN-only Flatpaks

Open **PIA → App routing… → VPN-only** and turn on **VPN required** beside an app. Quit
the app before changing its setting. Afterward use its usual Plasma application
launcher. qBittorrent's normal launcher retains its torrent and magnet-link
associations. Turning the switch off restores the prior launcher and network
permissions, including unrelated Flatpak overrides.

A command that starts the protected Flatpak directly, such as a plain
`flatpak run`, has loopback only. The Plasma launcher starts it in Vopono's
WireGuard namespace with a private PIA DNS file and an independent nftables
output policy. That policy blocks direct traffic to the veth uplink and allows
only marked WireGuard packets to reach its peer there. Ordinary native launches
follow the system-wide policy. A user can deliberately override their own
Flatpak permissions, and an app can ask the user to open a URL in another app.

Connect the main VPN before opening a protected app when the system kill switch
is on. Vopono then runs the app's separate tunnel through the host VPN. If the
host tunnel is unavailable, the protected launcher reports the error and keeps
the app offline.

## Apps excluded from the VPN

Open **PIA → App routing… → Excluded** and enable **Exclude from VPN** beside
a Flatpak. Open it from its usual launcher. IPv4 for the app can leave only on
the selected physical network interface, including when the host VPN is active.
It uses the physical interface’s DNS. Excluded apps are an explicit exception
to the system kill switch and stay offline if the physical connection is unavailable.
The VPN-only and excluded settings are mutually exclusive. Turning either setting off restores
the prior launcher and Flatpak permissions.

## Firewall and troubleshooting

The system-wide `inet pia_guard` nftables table activates before NetworkManager
at boot. When the switch is on, it blocks host and forwarded internet traffic outside `piadesk`,
including DNS and IPv6. It permits loopback, IPv4 DHCP, the marked WireGuard
peer, narrowly scoped temporary PIA setup traffic, and traffic between each
excluded app’s veth and its selected physical interface. The setup helper uses
Cloudflare DNS-over-HTTPS to resolve only the PIA bootstrap hostnames.

Inspect launch errors with `journalctl -u 'pia-control@*.service' -n 80`.
Confirm the system service is ready with `systemctl is-active pia-control.socket`.
Refresh the cached location list with
`~/.local/share/pia-vopono/pia-vopono locations-refresh`.
The panel status reflects the guard service and its configured switch setting.
A privileged global nftables flush can remove the active rules independently.
Restarting `pia-guard.service` reloads it.

## Recovery and removal

Turn the per-app switches off before removing the PIA desktop client, so it can
restore each app's previous launcher and permissions. Disconnect in the applet
before removing the system service. The following local administrator commands
deliberately restore ordinary host networking.

```sh
sudo systemctl disable --now pia-reconnect.timer pia-control.socket pia-guard.service
sudo rm -f /etc/systemd/system/NetworkManager.service.d/50-pia-guard.conf \
  /etc/systemd/system/pia-control.socket.d/50-desktop-account.conf \
  /etc/systemd/system/pia-{control.socket,control@.service,guard.service,reconnect.service,reconnect.timer}
sudo systemctl daemon-reload
sudo nft destroy table inet pia_guard
sudo ip -4 rule del pref 101 fwmark 0x504941 lookup main
```

Remove the PIA widgets in Plasma edit mode, then remove the package with
`kpackagetool6 --type Plasma/Applet --remove local.pia.wireguard.routing`.

## Development

```sh
python3 -m unittest discover -s tests -v
bash -n install.sh
bash -n guard/install
```

The automated checks exercise source syntax, initial location discovery, and
socket authorization using mocks. Live firewall and application isolation
tests require a Bazzite KDE session with an active network connection.

The integration code is MIT licensed. `pia-ca.crt` is the public PIA
certificate used by the [official manual connection scripts](https://github.com/pia-foss/manual-connections/blob/master/ca.rsa.4096.crt).
Vopono is installed separately under its upstream license.
