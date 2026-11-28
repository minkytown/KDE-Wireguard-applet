# KDE WireGuard applet

A Plasma 6 panel applet for Private Internet Access on Bazzite. Version 2 uses
Kommynct's Bash WireGuard backend at
[5a5ce04](https://github.com/Kommynct/walker-vpn/commit/5a5ce04bdfadbec3327f5af44c724a4d77ba395b),
with the existing searchable Plasma interface. There is no Python, Walker,
Elephant, Waybar, NixOS module or Vopono dependency.

## Install or upgrade

Download and extract the release bundle, then run as your Plasma desktop user:

```sh
./install.sh
```

Requires Plasma 6 with Plasma5Support, KDialog, Flatpak, WireGuard tools,
nftables, systemd-resolved, jq, socat, GNU grep, GNU awk, xdg-dbus-proxy,
dbus-daemon, curl, util-linux, GLib tools and sudo. The installer checks these
before making changes. Close routed Flatpak apps before upgrading. Administrator
authorization is needed to install the system services.

Existing widgets retain their package ID and panel position. On a fresh install,
add **KDE Wireguard applet** through Plasma's Add Widgets menu. Use **PIA →
PIA Credentials…** to save a login if one was not imported. The backend encrypts
credentials with systemd's host key in root-only `/var/lib/walker-vpn` storage.
An existing PIA KWallet login is imported when available. Credentials never appear in command
arguments. Sign out and in after installation to apply the native command path
to the desktop session.

Upgrading restores the previous client's managed launchers and Flatpak network
permissions, disables its services and firewall, and reapplies saved VPN-only
and excluded policies to the new backend. It then removes the retired system
files, Vopono binaries, duplicate user helper, caches and broken shortcuts.
The panels use the single system helper at `/usr/local/bin/walker-vpn`.

During migration, the previous registry is backed up under
`~/.config/pia-wireguard/apps.json.pre-bash-backend`. After success, one copy
remains at `~/.local/state/walker-vpn/legacy-migration.completed.json` and the
old configuration directory is removed. Pending choices are saved in
`~/.local/state/walker-vpn/legacy-migration.json`; retry `./install.sh` if an
upgrade is interrupted. An existing encrypted backend login is retained on
reinstallation; wallet import is only attempted when no login has been saved.

## Panel controls

Choose a country or location, or **Optimal** for the fastest reachable location.
The bounded list supports search. **Disconnect** stops recovery, tears down the
host tunnel and opens the kill switch. A dropped tunnel keeps the armed firewall
in place while the ten-second maintenance timer attempts recovery.

The **System kill switch** blocks ordinary host and forwarded internet traffic
outside the tunnel, including IPv6 and DNS. Connecting arms it by default;
explicitly turning it off prevents automatic arming for the remainder of that
boot. A failed connection keeps automatically armed protection on; use Disconnect
or explicitly turn the switch off to restore ordinary networking. **Degraded**
means the firewall needs attention. Excluded applications are
an explicit exception to the system kill switch.

**Reconnect on reboot** is off by default. When enabled, it remembers the current
location and registers a fresh tunnel using the encrypted login before desktop
sign-in. A dedicated boot guard arms the kill switch before NetworkManager can
start networking, and recovery registers the tunnel afterward. Disconnect clears the
saved boot location; connecting again resumes boot recovery if the toggle stays
on. With this option off, the host tunnel and kill switch reset on reboot, as in
the upstream backend. The saved account login remains available.

## App routing

**App routing…** keeps the searchable list and left-side switches from the
original applet and adds native desktop applications. If an app is running when
you change its route or VPN location, a dialog offers **Close and reopen app**
or **Cancel**. Save your work before accepting. The app must exit before the
policy changes; it is then reopened with the new route. Cancel keeps the
current app and route. If the app cannot close, the change is refused and its
previous route remains.

- **VPN-only:** enable **VPN required**. The location selector follows the host
  VPN by default, or chooses a dedicated **Optimal** or named PIA location.
  A dedicated app tunnel works independently of the host tunnel. Host-following
  apps require the host VPN; a manual Disconnect prevents launch recovery until
  you explicitly connect again.
- **Excluded:** enable **Exclude from VPN** to use the physical IPv4 uplink and
  its DNS even while the host VPN or kill switch is active. Restart these apps
  after changing network uplinks.
- Turning the active switch off restores the previous launcher and network
  setting. The two routes are mutually exclusive.

Normal desktop launchers and their actions retain the saved policy. Native
command shims apply when found through the managed command path. Explicit
absolute native executable paths follow the host policy. Flatpaks receive a
network override and use their managed launcher for routing; raw
`/usr/bin/flatpak run` has loopback-only networking for managed apps. The normal
`flatpak run` command uses the installed routing wrapper, while preserving the original
desktop-bus and portal behavior. Use the managed launcher or that normal command.
An explicit absolute executable path bypasses a command wrapper.

On Bazzite, forwarded app veth interfaces receive a temporary firewalld trusted-zone binding. The applet’s own firewall still blocks host access and pins traffic to the selected uplink. Cleanup removes the binding.

Protected app namespaces restrict direct socket traffic. Native apps use the
upstream filtered session bus; Flatpaks keep their original portal behavior.
Magnet links and torrent files use qBittorrent's managed desktop handler,
independently of the browser's VPN routing setting. External applications opened
through desktop services follow their own configured routing policy.
See [SECURITY.md](SECURITY.md) for the trust boundaries.

## Troubleshooting and recovery

The executable and service names retain `walker-vpn` for backend compatibility;
the Walker application is never invoked or required.

```sh
walker-vpn status
systemctl status walker-vpn.socket walker-vpn-maintain.timer
journalctl -u 'walker-vpn@*.service' -u walker-vpn-maintain.service -n 80
walker-vpn kill-off
sudo systemctl start walker-vpn-emergency-open.service
```

To remove: close routed apps, run `walker-vpn restore --all`, disconnect through
the panel, then disable `walker-vpn.socket` and `walker-vpn-maintain.timer` and
remove the applet. Before disabling the boot guard, remove
`/etc/systemd/system/NetworkManager.service.d/50-walker-vpn-guard.conf` and reload
systemd. Remove the `/usr/local/bin/flatpak` routing symlink when removing the
backend. Remove the user `walker-vpn-links.socket` and the Plasma
`~/.config/plasma-workspace/env/pia-routing.sh` environment file as well.

## Development

```sh
bash tests/run.sh
# Real firewall/namespace tests in disposable network and mount namespaces:
bash tests/transport-kernel.sh
```

The suite checks credential framing, routing priorities, launcher preservation,
Flatpak updates, repeated launches, app cleanup, desktop bus filtering,
link handling, timezone selection, the Plasma adapter and legacy migration.
The kernel fixture requires unprivileged user namespaces and dnsmasq.
Live PIA connectivity still needs a valid account and network access.

The integration and upstream backend are MIT licensed; see [LICENSE](LICENSE)
and [UPSTREAM](UPSTREAM). `lib/pia-ca.crt` is PIA's public CA certificate.
