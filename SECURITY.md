# Security model

KDE WireGuard applet protects direct IP traffic from apps started through a managed launcher. Its privileged service owns the network namespaces and installs the firewall before handing execution to the desktop user. VPN-only apps use the host tunnel or a separate WireGuard tunnel. Excluded apps use the selected physical uplink. Per-app routing currently allows IPv4 egress. IPv6 egress is blocked in managed namespaces.

## Trust boundaries

- The configured desktop account owns the control socket and can change routing preferences. Software with that account’s permissions can request the same changes or invoke unmanaged launch paths.
- A network namespace confines direct network connections. Local IPC, desktop portals, and other host services can perform operations from their own namespaces. The native D-Bus proxy limits session services available to routed apps. Flatpak continues to enforce its sandbox permissions.
- Native apps that exit immediately after a denied D-Bus name request retry on a private session bus. That bus has no host service activation or desktop integration. The app keeps its assigned network namespace.
- The desktop link socket is owned by the user and accepts HTTP and HTTPS URLs and existing absolute local directory paths. The desktop opens the target using its configured browser or file manager, so the handler’s own routing policy applies. Ordinary files and remote file URIs stay with the routed app’s opener. The socket does not run commands supplied by routed apps.
- The root-owned runtime registry associates repeat launches with the original app’s route and namespace. Policy changes require the app to stop. Shared leases keep the namespace in place during repeat launches. Detached processes keep it alive until they exit.
- A dedicated VPN location gives the app a namespace with only loopback and WireGuard. The WireGuard UDP socket stays in the host namespace. The armed firewall checks the WireGuard mark, local UDP port, peer IPv4 address, and peer UDP port for both host and dedicated transports.
- Saved PIA credentials are encrypted with a machine credential key. WireGuard private keys and generated profiles belong to the privileged service. Client requests and startup failures avoid logging credential values or provider configuration.

## Checks

A launch requires a separate mount and network namespace, the expected interface, DNS configuration, and the namespace’s default-drop output chain. Host routing rules stop forwarded app traffic when its selected routing table has no route. This applies to excluded apps using the main table and VPN-only apps using the host tunnel. The Flatpak launcher also checks for the expected network interface and resolver configuration from inside its sandbox. The regression tests cover shortcut migration, MIME arguments, route mismatch rejection, and detached-process lifetime.

The maintenance timer can rebuild a missing or incomplete host firewall table from runtime state. An armed switch reports degraded while its required firewall layout is missing. KDE WireGuard applet enables IPv4 forwarding on its own host-side app links and host WireGuard interface. Excluded app startup enables IPv4 forwarding on the selected physical uplink. It leaves host-wide and unrelated interface forwarding settings alone. A privileged firewall flush can remove host kill-switch enforcement until that rebuild completes.

Testing the kernel, Flatpak, systemd, and PIA implementations themselves is outside the scope of this project.

On Bazzite, each forwarded app's host-side veth is registered in firewalld's
runtime trusted zone after the namespace firewall, host input block, pinned
source/uplink rules and route-denial rule are installed. This allows forwarding
through Fedora's additional firewall layer. Cleanup removes that interface
binding. No physical interface or host-wide firewalld policy is made trusted.

Boot reconnect is guarded before NetworkManager starts networking. Its required
oneshot service fails closed if firewall initialization fails. A failed provider
registration or tunnel replacement does not automatically disarm protection.
Panel status uses a recent service heartbeat or a fresh control query.

D-Bus and portal behavior remain unchanged from the upstream implementation.
Incoming magnet and torrent-file launches use their managed desktop handler and
preserve arguments into qBittorrent's protected namespace, regardless of the
browser's own routing setting. A host service or external application opened
through IPC follows its own network policy; network namespaces do not force
that separate process to inherit the sender's route.
Use the managed launcher or normal `flatpak run` wrapper. Explicit native
executable paths bypass command wrappers and follow the host policy.

The desktop account or an administrator can deliberately edit overrides,
policies, binaries or firewall rules. This is protection against accidental
routing mistakes, not a boundary against malicious software with that account's
control access. Local file operations and permitted IPC services retain their
own host behavior. Cold-boot ordering is checked with systemd's dependency
validator; a reboot is required to verify a particular machine's full boot path.
