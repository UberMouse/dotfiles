# Resource-pool policy for Claude Code worktree builds and the agents fleet:
# the worktrees.slice pool, its agents subslice, the claude-ui slice, and the
# three services that govern them (pressure monitor, governor, semaphore
# controller). Split out of home.nix 2026-08-07 — this is a self-contained
# subsystem, and it was 55% of that file. The MEMORY NUMBERS live in
# ../memory-policy.nix, shared with the desktop floor in nixos.nix.
{
  pkgs,
  lib,
  unstable-small-pkgs,
  ...
}:
let
  memory = import ./memory-policy.nix;
in
{
  # Claude Code worktree build-daemon resource pool (monorepo-jobs).
  #
  # Global resource pool shared by every worktree's build work. The
  # worktree-setup hook places each worktree's `mj watch` daemon -- and adopts
  # the whole Claude session (claude-<name>.scope) via cgroup ancestry -- into
  # that worktree's OWN slice (worktrees-<name>.slice), a child of this pool, so
  # EVERYTHING the session spawns (Grep tool, MCP, subagents, builds) is budgeted.
  # cgroup v2 hierarchy enforces:
  #   * this pool's caps are a hard ceiling on the WHOLE subtree (all worktrees
  #     combined) -> the OS always keeps headroom;
  #   * each worktree slice's equal weight shares this pool fairly (one busy
  #     worktree gets it all; several busy split it evenly; idle ones cost
  #     nothing), and a worktree's daemon + ad-hoc runs share its single share.
  #
  # Machine-specific policy for this 16-core / 27 GiB host. To re-budget, change
  # ONLY the two numbers below. The committed hook hardcodes no numbers of its
  # own and no-ops entirely if this slice is absent.
  systemd.user.slices.worktrees = {
    Unit = {
      Description = "Claude Code worktree build-daemon resource pool (monorepo-jobs)";
      Documentation = "file:.claude/hooks/worktree-setup.sh";
    };
    Slice = {
      # Hard CPU ceiling on the whole subtree: 12 of 16 cores. Leaves 4 cores
      # for the OS, editor, and browser no matter how many worktrees are
      # building at once.
      CPUAccounting = true;
      CPUQuota = "1200%";

      # Soft memory throttle. This 27 GiB host is memory-OVERSUBSCRIBED when a
      # browser + N parallel worktree builds run (fleet working set ~14 GiB), so
      # this one number seesaws between two failure modes and neither fully wins:
      #   * too HIGH (16G): a peak exhausts global RAM, the kernel reclaims and
      #     swaps out Xorg -> brief whole-machine FREEZE (memory PSI full ~25%,
      #     cpu PSI full 0% -- CPU is never the problem);
      #   * too LOW (12G): the pool sits at its ceiling in perpetual reclaim-
      #     throttle, every allocation gets a penalty delay -> everything CRAWLS
      #     (memory PSI full ~32%, high breached 1700+ times).
      # 20G/22G was tried 2026-07-17..07-21 as a THROUGHPUT bet (let the pool hold
      # more resident now that memory.min=8G stops Xorg being the reclaim victim).
      # REVERTED to 16G/18G 2026-07-21 on decisive evidence: at a 20G ceiling the
      # pool's `memory.events high` counter read **0** in every single forensic
      # snapshot -- the throttle NEVER fired, not once. On a 27 GiB box that also
      # owes the desktop an 8 GiB floor, the machine runs out of RAM at ~19G pool
      # usage, i.e. BEFORE the pool can reach its own limit. A ceiling above what
      # the box can physically deliver is not a limit at all, so global reclaim
      # won the race every time and the desktop paid for it in allocation latency
      # (7 stalls, desktop memory PSI full 13-40%, free RAM 172-525 MiB). At 16G
      # that same counter logged 16000-24000 events per incident -- that is the
      # pool absorbing its own pressure, which is the entire point.
      #
      # 18G/20G FROM 2026-08-06, and the margin is the whole argument. The run-out
      # point is (MemTotal - the desktop's 8G floor): on the 27 GiB figure above
      # that is ~19G, which is why a 20G ceiling could never fire. This host
      # actually reports MemTotal 29.19 GiB (the "27 GiB" above was always
      # approximate), so run-out sits at ~21.2G and an 18G ceiling keeps ~3.2 GiB
      # of margin beneath it -- the throttle can still engage before global
      # reclaim does, which is exactly what 20G lost. It is a smaller margin than
      # 16G bought, so this is the loosest setting the box can take, not a step on
      # the way to a looser one. The 20G/22G revert above stands as the warning.
      #
      # HONESTY ABOUT WHY IT WAS SET: this was applied in anticipation of a VM RAM
      # increase that had NOT yet landed. MemTotal was still 29.19 GiB at the time
      # (unchanged, no offline memory blocks, vmw_balloon loaded but delivering
      # nothing -- VMware needs a power-off, not a reboot). So the margin arithmetic
      # above is for the SMALL box, deliberately: it has to hold on 29.19 GiB, and
      # it gets roomier, not tighter, once the extra RAM appears.
      #
      # THE TEST IS UNCHANGED and it is the one this comment has always specified:
      # watch `memory.events high`. Non-zero after a build storm means the pool is
      # absorbing its own pressure. A reading of 0 means the ceiling has gone loose
      # again and this change should be reverted to 16G/18G, exactly as 20G was.
      #
      # MemoryMax MOVES WITH IT, and must. At MemoryHigh=MemoryMax there is no
      # throttle band at all: the pool would step from unthrottled straight to an
      # OOM kill with no reclaim zone between them, deleting the very mechanism the
      # paragraphs above credit for keeping stalls in-pool. 20G preserves the same
      # 2 GiB backstop gap that 16G/18G had.
      #
      # The "16G freezes / 12G crawls" seesaw recorded above is now stale on BOTH
      # ends: the 16G freeze predates memory.min=8G (2026-07-17), and the 12G crawl
      # was a live set-property trial (never committed -- git only ever had 16G or
      # 20G) that predates both memory.min AND the kswapd headroom added 07-21
      # (watermark_scale_factor 125->300, see nixos.nix). Both of those change what
      # happens when the pool throttles: it now reclaims into zram against a box
      # with a real free-page buffer, instead of against one already at the wall.
      # 16 + 8 = 24 on 27 GiB leaves genuine headroom for kernel + page cache.
      #
      # MemoryMax=20G is the runaway backstop: a pathological fleet gets one
      # OOM-killed build (contained in-pool; earlyoom already prefers build
      # workers) rather than the whole box swapping to death.
      # cgroup-pressure-monitor.service captures forensics + auto-diagnoses each
      # remaining stall so we keep tuning from data. Watch `memory.events high`:
      # if it is 0 after a build storm, the ceiling is too loose again.
      MemoryAccounting = true;
      MemoryHigh = memory.poolHigh;
      MemoryMax = memory.poolMax;

      # Hard write cap on the pool's disk I/O. This host's I/O scheduler is
      # mq-deadline, which IGNORES io.weight (only BFQ honours it) -- so an
      # ABSOLUTE io.max is the only thing that actually bounds a parallel-build
      # I/O storm (an io PSI full ~42% stall was traced to exactly this: builds
      # saturating the virtual-disk queue while Xorg waits behind them). Validated
      # live that this throttles BUFFERED writes too (ext4 cgroup-writeback),
      # which is what builds do -- unlike io.weight. 200 MB/s leaves virtual-disk
      # queue headroom; io.latency=50ms on the graphical session scope (nixos.nix)
      # gives Xorg's I/O priority on top. sda is SSD-backed on the host (the VM
      # misreports rotational=1). Tune from cgroup-pressure-monitor snapshots.
      IOAccounting = true;
      IOWriteBandwidthMax = "/dev/sda 200M";
    };
  };

  # Container slice for the Claude background-agent fleet, a child of the pool
  # above. NOT a throttle: it carries no MemoryHigh of its own, so the fleet is
  # governed only by the pool's 18G high (and the desktop's 8G memory.min floor).
  # It exists to (a) give the fleet a distinct, observable bucket under the pool
  # -- the "agents" line in wt-cgroup-status -- and (b) be the placement target
  # for claude-agents-reattach, which re-homes the cc-daemon and every worker it
  # forks into worktrees-agents.slice/fleet.
  #
  # WHY NO CAP (history). A 4G MemoryHigh lived here 2026-07-21..07-24 to page
  # out idle `claude bg-spare` standby heaps (~1.8 GB of a dozen cold spares)
  # without costing build speed -- back when this slice held ONLY agent standby.
  # It was removed 2026-07-24 once the design changed to run the *active* fleet
  # here: the cc-daemon + live agents + their MCP servers + agent-spawned
  # monorepo-jobs build daemons, all re-homed by claude-agents-reattach. Against
  # that ~7-8 GB active working set the 4G soft cap pinned the slice at its
  # ceiling -- memory PSI full ~60%, 38k high-breach events, 2.3 GB forced into
  # swap -- so the fleet crawled while the pool above it sat at only 4 of 16 GB.
  # A sub-cap below the pool is the wrong tool once agents ARE the pool's primary
  # tenant: the pool's own 18G high is the single agent+build budget, and its
  # MemoryMax=20G still backstops a runaway subtree with one contained OOM.
  #
  # The `claude agents` UI is deliberately kept OUT of this slice (and the whole
  # pool) so it stays responsive under memory pressure; only the daemon and the
  # work it invokes live here. Fork inheritance means that split cannot be
  # inherited from an out-of-pool UI, so claude-agents.sh pulls the daemon in
  # once at launch via claude-agents-reattach. See both scripts for the details.
  systemd.user.slices."worktrees-agents" = {
    Unit = {
      Description = "Claude agents fleet (worktrees pool child)";
      Documentation = "file:scriptBins/bins/claude-agents-reattach.sh";
    };
    Slice = {
      MemoryAccounting = true;
    };
  };

  # Home for the `claude agents` FleetView TUI itself. Keeping it OUT of the pool
  # (above) stops it being memory-throttled, but exemption is not priority, and
  # 2026-07-31 showed the difference matters: with the pool's memory stalls fixed
  # and the desktop flat at 0.00% memory PSI, the UI was still visibly laggy. Its
  # own scope told the story -- cpu.pressure full avg10 climbing 1.7 -> 6.0% with
  # memory AND io pressure both a flat 0.00 in every window. It was stalling on
  # CPU alone, an axis nothing in the pressure/governor work touches.
  #
  # The cause was that a bare `tmux-spawn-*.scope` grants nothing. The desktop
  # session has memory.min=8G + io.latency=50ms; the pool has its own budget and
  # io.max; the UI had memory.min=0, no io.latency, and cpu.weight=100 -- the
  # SAME weight as a slice running twelve cores of typechecks. It was the least
  # protected interactive thing on the box, competing at par with the fleet while
  # the kernel burned ~68% of the machine in reclaim/zram.
  #
  # CPUWeight is the right instrument rather than a quota: it is work-conserving,
  # so the pool still gets the whole box when the UI is idle, and the UI only
  # wins the scheduler when it actually has work -- which for a TUI is exactly
  # the redraw it is currently losing.
  #
  # MemoryHigh EXISTS TO CONTAIN A FORK LEAK, not to bound the TUI (which runs
  # ~200 MB). The cc-daemon is forked BY the UI and so inherits this slice until
  # claude-agents-reattach re-homes it into worktrees-agents.slice. That window
  # is normally seconds, but if the reattach ever fails the whole agent fleet
  # would inherit CPUWeight=5000 and outrank the desktop 50:1 -- strictly worse
  # than the bug this slice fixes. Today the same leak lands in a NEUTRAL tmux
  # scope and is merely unbudgeted; landing it in a PRIVILEGED one is a new
  # hazard, so cap it: a leaked fleet hits this ceiling almost immediately and
  # throttles loudly instead of silently starving the desktop. 2G is 10x the
  # TUI's real footprint, so it can never bind in normal operation.
  systemd.user.slices."claude-ui" = {
    Unit = {
      Description = "Claude agents FleetView UI (interactive, out of pool)";
      Documentation = "file:scriptBins/bins/claude-agents.sh";
    };
    Slice = {
      CPUWeight = 5000;
      MemoryAccounting = true;
      MemoryMin = "512M";
      MemoryHigh = "2G";
      IOAccounting = true;
    };
  };

  # Memory/IO pressure monitor. Watches system PSI and, whenever the machine
  # actually stalls (full-avg10 >= 20%), captures a forensic snapshot (per-cgroup
  # memory, top procs by RSS, pool stats, swap) + a desktop alert so a transient
  # freeze/slowdown can be investigated after the fact -- a `ps` run after the
  # event shows nothing. Runs in the user session (NOT worktrees.slice) so it can
  # always capture even while the pool is throttled. Because the machine is
  # memory-oversubscribed this is how we tune MemoryHigh from data, not guesses.
  #
  # CGPM_INVESTIGATE=1 makes each stall also spawn a headless, DIAGNOSE-ONLY
  # `claude -p` (Opus) that reads the snapshot (inlined, no tools) and writes a
  # root-cause analysis + notifies -- "ping Claude on hang". It never touches the
  # system. Snapshots, analyses + events.log land in ~/.local/state/cgroup-pressure/.
  systemd.user.services.cgroup-pressure-monitor = {
    Unit.Description = "cgroup v2 memory/IO pressure monitor (forensic snapshots + claude diagnosis on stall)";
    Install.WantedBy = [ "default.target" ];
    Service = {
      # User services get a bare PATH; give the script the tools it shells out to
      # (incl. claude + git for the auto-diagnosis).
      Environment = [
        "PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.procps
            pkgs.gawk
            pkgs.gnused
            pkgs.util-linux
            pkgs.findutils
            pkgs.libnotify
            pkgs.git
            unstable-small-pkgs.claude-code
          ]
        }"
        "CGPM_INVESTIGATE=1"
        "CGPM_CLAUDE=${unstable-small-pkgs.claude-code}/bin/claude"
        "CGPM_MODEL=opus"
        "CGPM_INVESTIGATE_COOLDOWN=1800"
      ];
      ExecStart = "${pkgs.bash}/bin/bash ${./scripts/cgroup-pressure-monitor.sh}";
      Restart = "always";
      RestartSec = 10;
      Nice = 10;
    };
  };

  # The ACTUATOR half of the pressure system -- the monitor above only observes.
  #
  # WHY. Between 2026-07-17 and 07-28 the monitor accumulated 129 snapshots and
  # ~40 Claude analyses, and changed nothing: each one is a report ABOUT a freeze
  # already endured. Meanwhile the supply-side knobs are exhausted. Every stall
  # on record shows io_full_avg10 = 0.00 and cpu full = 0.00 -- it is memory,
  # every time -- with the desktop sitting BELOW its 8G memory.min (so memory.min
  # held; its pages were never evicted) and stalling anyway in *direct reclaim*
  # because global free RAM collapsed to 200-500 MiB. memory.min guarantees the
  # pages you already hold; it cannot manufacture free ones. Committed_AS runs
  # ~126% of CommitLimit (45.8 / 36.3 GiB, 07-28): the box is not mis-partitioned,
  # it is oversubscribed, and nothing bounds DEMAND. This service is the first
  # thing here that acts on the demand side.
  #
  # Three duties, cheapest first, each escalating only if the last failed:
  #   A. reclaim the fleet's COLD pages (idle `claude bg-spare` standby heaps --
  #      ~2.9 GB of 16 spares measured 07-28) via memory.reclaim. Measured live:
  #      512 MB freed in 0.18 s with no zram growth, i.e. the pages were clean
  #      and simply dropped. The point is not that RAM appears from nowhere --
  #      MemAvailable already counted them -- but that the reclaim happens HERE,
  #      proactively, instead of inline in the desktop's page-fault path, which
  #      is exactly the direct-reclaim stall being eliminated. memory.high was
  #      tried on this slice 07-21..07-24 and reverted (it pinned the ACTIVE
  #      fleet at its ceiling); memory.reclaim is one-shot with no standing
  #      allocation penalty, so it does not repeat that mistake.
  #   B. cap concurrent BUILD scopes while memory is tight, freezing the excess
  #      so N run at full speed instead of six thrashing together and all
  #      crawling. Victims rotate so none starves; the cap disengages the moment
  #      pressure clears. True spawn-time admission control belongs in
  #      ~/code/kawaka/.claude/hooks/worktree-setup.sh (a different repo), so
  #      this gates EXECUTION instead -- which also covers already-running work.
  #   C. if the desktop stalls anyway: reclaim, re-measure, and only then brake
  #      the single largest build scope for a few seconds.
  #
  # Only mj-<name>.scope (the monorepo-jobs build daemon) is ever frozen. The
  # worktree slice ABOVE it also adopts the interactive Claude session, so
  # freezing the slice would pause a session the user may be mid-conversation
  # with; freezing the mj-* scope inside it pauses only the build. The agents
  # fleet and the desktop session scope are never frozen -- the fleet is
  # reclaimed from, never paused.
  #
  # DUTIES B AND C WERE DEAD CODE 2026-07-28..07-31 and this is worth knowing
  # before trusting any conclusion drawn in that window. list_build_scopes()
  # skipped empty leaves with `[ -s cgroup.procs ]`, but cgroup.procs is a kernfs
  # seq_file that always stats as size 0 -- so the test was unconditionally false,
  # the candidate list was ALWAYS empty, and the governor silently ran only its
  # two cheap duties (reclaim + sweep). `grep -c 'CGGOV|FREEZE' governor.log` read
  # 0 across the entire file. 07-31 was the worst day on record (42 stall events
  # vs a prior peak of 28) and 184 of its 188 stall detections logged "no build
  # scope to brake (pressure is not from builds)" while 21 freezable scopes --
  # including one at 5.0 GB -- sat right there in the pool. That message was the
  # bug reporting itself as a finding, and it is why 07-28's "act on stalls"
  # change did not move the trend: the actuator never actuated. Fixed 07-31 by
  # reading a pid instead of stat'ing the file.
  #
  # Consequence for tuning: every stall analysis in ~/.local/state/cgroup-pressure
  # from 07-28 to 07-31 describes a machine with NO working demand-side control,
  # so their unanimous "lower MemoryHigh to 11-12G" recommendation was reasoning
  # about a system that does not exist any more. Re-measure before acting on it.
  #
  # Set CGGOV_DRYRUN=1 to log every decision while touching nothing.
  # Log lines are tagged CGGOV:
  #   grep -E 'CGGOV\|(RECLAIM|FREEZE|THAW|CAP|STALL|STATE|START|STOP|DRYRUN)' \
  #     ~/.local/state/cgroup-pressure/governor.log
  systemd.user.services.cgroup-governor = {
    Unit.Description = "cgroup v2 memory governor (proactive reclaim + build concurrency cap + stall brake)";
    Install.WantedBy = [ "default.target" ];
    Service = {
      Environment = [
        "PATH=${
          lib.makeBinPath [
            pkgs.coreutils
            pkgs.procps
            pkgs.gawk
            pkgs.gnused
            pkgs.util-linux
            pkgs.findutils
          ]
        }"
      ];
      ExecStart = "${pkgs.bash}/bin/bash ${./scripts/cgroup-governor.sh}";
      # The governor guarantees thaw three ways internally (per-freeze deadline,
      # EXIT trap, startup sweep) but none survive SIGKILL. ExecStopPost is the
      # fourth and runs however the service dies, so a build can never be left
      # frozen -- the one failure mode here that would not self-correct.
      ExecStopPost = "${pkgs.bash}/bin/bash ${./scripts/cgroup-thaw-all.sh}";
      Restart = "always";
      RestartSec = 10;
      # Must stay responsive under exactly the pressure it exists to relieve, so
      # it runs at a better nice than the monitor (Nice=10, which only has to
      # write files). 0 is as good as it gets: this user's RLIMIT_NICE is 0, so a
      # NEGATIVE nice is refused outright and would fail the unit at startup.
      Nice = 0;
    };
  };

  # Machine-global build admission semaphore -- the DEMAND-side half.
  #
  # The governor above gates EXECUTION (freeze the Nth build once it is already
  # running and already holding its memory). This gates ADMISSION (do not let the
  # Nth build start). The governor's own header explains why it settled for the
  # weaker lever -- "true admission control gates at spawn, but the spawn point
  # is [...] a different repo" -- and this service is that lever, reached by
  # publishing a semaphore any repo can take a slot from instead of trying to
  # reach into the spawn site itself.
  #
  # WHY BOTH STILL EXIST. Freezing cannot shrink a peak, because a frozen cgroup
  # keeps every anon page resident -- that is why governor.log shows a ~20 s
  # FREEZE/THAW "cap rotation" that never converges. Admission control cannot
  # shrink a peak that has ALREADY formed either, since it only governs what
  # starts next. They cover different halves of the timeline: this service stops
  # the storm assembling, the governor brakes one that assembled anyway (from
  # work that predates the semaphore, or from tenants that never take slots at
  # all -- the agents fleet, MCP servers, browsers). Once the semaphore has a
  # measured track record the governor's freeze duty is the natural thing to
  # retire; it should NOT be retired before then, on the evidence that duties B
  # and C were silently dead for three days in July and the trend got worse.
  #
  # Sizing, from 429 samples of worktrees.slice at 10 s (2026-08-03, 80 min):
  # p50 12.57G / p90 15.08G / max 16.00G against a 16G MemoryHigh, mean 11.93G
  # (73% -- healthy), memory PSI p50 0.0% / p90 16.6% / max 81.1%. Median
  # pressure is ZERO: this box is not short of RAM on average, only during the
  # ~10% of the time when independent worktrees burst together. Defaults are
  # tuned to that shape and all overridable by env; see the script header.
  #
  # Log lines are tagged BUILDSEM:
  #   grep -E 'BUILDSEM\|(START|STOP|TIGHTEN|LOOSEN|SETTLE|ACQUIRED|TIMEOUT)' \
  #     ~/.local/state/cgroup-pressure/build-semaphore.log
  systemd.user.services.build-semaphore-controller = {
    Unit.Description = "Build admission semaphore controller (pressure-adaptive slot count)";
    Install.WantedBy = [ "default.target" ];
    Service = {
      ExecStart = "${pkgs.python313}/bin/python3 ${./scripts/build-semaphore-controller.py}";
      Restart = "always";
      RestartSec = 10;
      # Same reasoning as the governor: it has to keep making decisions during
      # the pressure it exists to relieve.
      Nice = 0;
      # No ExecStopPost cleanup is needed, and that is a property of the design
      # rather than an omission: the controller restricts capacity by HOLDING
      # flocks, and the kernel drops every flock when the process dies. However
      # this unit exits -- clean stop, crash, SIGKILL, OOM -- capacity returns to
      # maximum on its own. The failure mode is "no throttling", never "stuck
      # throttled", which is the correct direction for a build system to fail in.
    };
  };
}
