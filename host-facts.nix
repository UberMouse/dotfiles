# HARDWARE FACTS for this host, declared once. Everything here is a
# hand-copied machine fact of exactly the kind CLAUDE.md bans from living
# inline at its consumption sites: before this file the boot disk appeared in
# two files in two encodings ("/dev/sda 200M" in cgroups.nix, "8:0" in
# nixos.nix's io.latency writer) and the core count existed only inside a
# CPUQuota percentage -- a second host on NVMe would have silently no-opped
# both I/O knobs. Consumers must DERIVE from these values, never restate
# them; anything derivable at runtime (major:minor from /sys/class/block)
# is derived there instead of copied here.
#
# The memory numbers live separately in memory-policy.nix: they encode a
# tuned cross-tree POLICY invariant with its own assertion, not a raw fact.
let
  rootDisk = "/dev/sda";
  cpuCores = 16;
in
{
  inherit rootDisk cpuCores;
  # Kernel name ("sda"), for /sys/class/block lookups at runtime.
  rootDiskName = baseNameOf rootDisk;
}
