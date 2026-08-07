{
  pkgs,
  unstable-pkgs,
  lib,
  config,
  ...
}:

{
  programs.zsh = {
    enable = true;
    autocd = true;
    dotDir = config.home.homeDirectory;

    dirHashes = {
      kawaka = "$HOME/code/kawaka";
    };

    syntaxHighlighting = {
      enable = true;
    };

    shellAliases = {
      l = "ls -ahG";
      e = "nvim";
      szsh = "source ~/.zshrc";
      gmt = "git machete traverse";
      gms = "git machete status";
      gma = "git machete add";
      gmc = "git machete delete-unmanaged";
      gmd = "git machete discover";
      buildT = "rush build -T .";
      buildt = "rush build -t .";
      buildo = "rush build -o";
      fbuildT = "rush fast-build -T .";
      fbuildt = "rush fast-build -t .";
      fbuildo = "rush fast-build -o";
      # NOT `gcc`: that alias shadowed the real gcc compiler installed in
      # home.packages, so `gcc` in a shell opened GNOME settings instead.
      netcfg = "gnome-control-center network";
      tail-rimu-logs = "tail -f ~/.config/Koordinates/logs/*.log";
      get-latest-rimu-log = "echo ~/.config/Koordinates/logs/$(ls -Art ~/.config/Koordinates/logs | tail -n 1)";
      search-latest-rimu-log = "cat $(get-latest-rimu-log) | grep";
      hms = "sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10";
      show-trace = "npx playwright@${unstable-pkgs.playwright-test.version} show-trace";
      heft = "node_modules/.bin/heft";
      xclip = "xclip -selection clipboard";
      rf = "rm common/temp/rush*lock";
      test-storybook = "rush test-storybook --include-phase-deps -o";
      yolo-claude = "claude --allow-dangerously-skip-permissions";
      package-scripts = "cat package.json | jq .scripts";
    };

    oh-my-zsh = {
      # No `custom` dir: the prompt comes entirely from powerlevel10k below.
      # The old zsh-customizations/ theme dir was pre-p10k residue, deleted
      # 2026-08-07 (it also hardcoded the checkout path, $HOME/dotfiles).
      enable = true;
      plugins = [
        "git"
        "command-not-found"
        "git-flow"
        "direnv"
      ];
    };

    plugins = [
      {
        name = "powerlevel10k-config";
        src = ./p10k;
        file = "p10k.zsh";
      }
      {
        name = "zsh-powerlevel10k";
        src = "${pkgs.zsh-powerlevel10k}/share/zsh-powerlevel10k/";
        file = "powerlevel10k.zsh-theme";
      }
    ];

    initContent = lib.mkMerge [
      (lib.mkBefore ''
        # Enable Powerlevel10k instant prompt. Should stay close to the top of ~/.zshrc.
        # Initialization code that may require console input (password prompts, [y/n]
        # confirmations, etc.) must go above this block; everything else may go below.
        if [[ -r "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh" ]]; then
          source "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh"
        fi

        export PLAYWRIGHT_BROWSERS_PATH="${unstable-pkgs.playwright-driver.browsers}"
        export KAWAKA_SKIP_PLAYWRIGHT_FIREFOX="1"
        export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD="1"
        export PATH="$PATH:$HOME/.pnpm-packages/bin:$HOME/.local/bin"

        function kill-all {
          ps -ef | grep [$1] | awk '{print $2}' | xargs kill -9
        }
      '')
      (lib.mkAfter ''
        # Shared by every rush helper below: the walk-up-to-rush.json and the
        # JSONC-strip-then-jq incantation used to be copy-pasted four times
        # (and could drift independently). _rush_jsonc's perl strip is
        # textual -- a literal "//" inside a JSON string would be mangled --
        # accepted for the same reason rush-logs.sh accepts it.
        _rush_root() {
          local dir="$PWD"
          while [[ "$dir" != "/" ]]; do
            [[ -f "$dir/rush.json" ]] && { print -r -- "$dir"; return 0; }
            dir="$(dirname "$dir")"
          done
          return 1
        }
        _rush_jsonc() {
          perl -0777 -pe 's|/\*.*?\*/||gs; s|^\s*//[^\n]*||gm; s|\r||g' "$1"
        }
        _rush_packages() {
          local root="$1"
          _rush_jsonc "$root/rush.json" | jq -r '.projects[].packageName'
        }

        _rush_completion() {
          compadd -- $(rush tab-complete --position ${"$"}{CURSOR} --word "${"$"}{BUFFER}" 2>>/dev/null)
        }
        compdef _rush_completion rush

        _rush_logs_completion() {
          local rush_root
          rush_root="$(_rush_root)" || return

          case $CURRENT in
            2)
              local -a packages
              packages=( $(_rush_packages "$rush_root") )
              compadd -- "${"$"}{packages[@]}"
              ;;
            3)
              local -a phases
              phases=( $(_rush_jsonc "$rush_root/common/config/rush/command-line.json" | jq -r '.phases[].name | sub("^_phase:";"")') )
              compadd -- "${"$"}{phases[@]}"
              ;;
          esac
        }
        compdef _rush_logs_completion rush-logs

        navigate-to() {
          if [[ $# -lt 1 ]]; then
            echo "Usage: navigate-to <package-name>"
            return 1
          fi

          local rush_root
          if ! rush_root="$(_rush_root)"; then
            echo "Error: Could not find rush.json in any parent directory"
            return 1
          fi

          local project_folder
          project_folder=$(_rush_jsonc "$rush_root/rush.json" | jq -r --arg pkg "$1" '.projects[] | select(.packageName == $pkg) | .projectFolder')

          if [[ -z "$project_folder" ]]; then
            echo "Error: Package '$1' not found in rush.json"
            return 1
          fi

          cd "$rush_root/$project_folder"
        }

        _navigate_to_completion() {
          local rush_root
          rush_root="$(_rush_root)" || return

          local -a packages
          packages=( $(_rush_packages "$rush_root") )
          compadd -- "${"$"}{packages[@]}"
        }
        compdef _navigate_to_completion navigate-to
      '')
    ];
  };
}
