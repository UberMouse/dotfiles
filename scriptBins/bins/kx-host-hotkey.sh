# kx-host-hotkey -- fire the voice-assistant hotkey on the Windows VMware HOST.
#
# VMware grabs the keyboard while the VM has focus, so the host's pynput
# listener never sees the Shift+F3 chord; i3 binds it to this script, which
# plumbs the press back over HTTP. Port 8004 is the host-side listener; the
# reciprocal VM-inbound port 8003 is opened in nixos.nix's firewall.
#
# The host's LAN address is MACHINE-LOCAL STATE, not config: it is
# DHCP-assigned, and this repo is public -- the tracked tree carries no LAN
# addresses. Seed the file once (current address, from the host: `ipconfig`):
#
#   mkdir -p ~/.config/kx && echo 192.168.x.x > ~/.config/kx/host-ip
IP_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/kx/host-ip"
if [ ! -r "$IP_FILE" ]; then
  msg="no host IP at $IP_FILE - write the VMware host's LAN address there (see kx-host-hotkey's header)"
  notify-send -u critical "kx-host-hotkey" "$msg" 2>/dev/null || echo "kx-host-hotkey: $msg" >&2
  exit 1
fi
read -r host_ip < "$IP_FILE"
# -f so a dead listener is an exit code, not a silent 404 body; the chord
# matches the host side (lshift+f3) for muscle-memory parity.
exec curl -fsS -m 2 -X POST -H 'Content-Type: application/json' \
  -d '{"kind":"short"}' "http://${host_ip}:8004/hotkey"
