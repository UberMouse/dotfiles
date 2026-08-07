---
name: kolide-launcher
# check-only: the pin is a flake-input rev (no version string anywhere), and
# it must NEVER be auto-bumped — this is a ROOT-privileged system service.
mode: check-only
version_check: gh api repos/kolide/nix-agent/commits/main --jq '.sha[0:12]'
version_file: flake.lock
---

# Check Process (never auto-update)

This spec tracks the `kolide-launcher` FLAKE INPUT, not a package directory.
It is pinned to a deliberate rev in `flake.nix` because it runs as a root
system service — "whatever main is on flake-update day" is not an acceptable
supply chain for root code (see the comment on `inputs.kolide-launcher`).

But a pin with no owner never gets asked about, and for a security agent the
risk runs the other way too: an eternally stale root service misses upstream
security fixes. This spec exists so the weekly run keeps asking.

1. Get the currently pinned rev:
   ```bash
   jq -r '.nodes."kolide-launcher".locked.rev' flake.lock
   ```

2. Compare with `version_check`'s answer (upstream main). If they differ,
   summarize what moved:
   ```bash
   gh api "repos/kolide/nix-agent/compare/<pinned>...main" \
     --jq '.commits[] | .sha[0:8] + "  " + (.commit.message | split("\n")[0])'
   ```

3. **Report the summary to the user and STOP.** Never bump the rev yourself.
   If the user approves, the bump is: replace the rev in
   `inputs.kolide-launcher.url` in `flake.nix`, then `nix flake update
   kolide-launcher`.

4. If nothing moved: note "kolide-launcher pin matches upstream main" and
   move on.
