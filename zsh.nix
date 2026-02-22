{ pkgs, unstable-pkgs, lib, ... }:

{
  programs.zsh = {
    enable = true;
    autocd = true;

    dirHashes = { kawaka = "$HOME/code/kawaka"; };

    syntaxHighlighting = { enable = true; };

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
      gcc = "gnome-control-center network";
      tail-rimu-logs = "tail -f ~/.config/Koordinates/logs/*.log";
      get-latest-rimu-log =
        "echo ~/.config/Koordinates/logs/$(ls -Art ~/.config/Koordinates/logs | tail -n 1)";
      search-latest-rimu-log = "cat $(get-latest-rimu-log) | grep";
      hms =
        "sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10";
      show-trace = "npx playwright@${unstable-pkgs.playwright-test.version} show-trace";
      heft = "node_modules/.bin/heft";
      xclip = "xclip -selection clipboard";
      rf = "rm common/temp/rush*lock";
      rushx = "node /home/taylorl/code/kawaka/common/scripts/install-run-rushx.js";
      rush-pnpm = "node /home/taylorl/code/kawaka/common/scripts/install-run-rush-pnpm.js";
      test-storybook = "rush test-storybook --include-phase-deps -o";
      yolo-claude = "claude --allow-dangerously-skip-permissions";
    };

    oh-my-zsh = {
      enable = true;
      custom = "$HOME/dotfiles/zsh-customizations";
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
        export PATH="$PATH:/home/taylorl/.pnpm-packages/bin:/home/taylorl/.local/bin"
        export CLAUDE_CODE_DISABLE_1M_CONTEXT=1
        export CLAUDE_CODE_DISABLE_AUTO_MEMORY=0

        function kill-all {
          ps -ef | grep [$1] | awk '{print $2}' | xargs kill -9
        }
      '')
      (lib.mkAfter ''
        rush() {
          node /home/taylorl/code/kawaka/common/scripts/install-run-rush.js "$@"
        }

        _rush_completion() {
          compadd -- $(rush tab-complete --position ${"$"}{CURSOR} --word "${
            "$"
          }{BUFFER}" 2>>/dev/null)
        }
        compdef _rush_completion rush

        _rush_logs_completion() {
          local dir="$PWD" rush_root=""
          while [[ "$dir" != "/" ]]; do
            [[ -f "$dir/rush.json" ]] && { rush_root="$dir"; break; }
            dir="$(dirname "$dir")"
          done
          [[ -z "$rush_root" ]] && return

          case $CURRENT in
            2)
              local -a packages
              packages=( $(perl -0777 -pe 's|/\*.*?\*/||gs; s|^\s*//[^\n]*||gm; s|\r||g' "$rush_root/rush.json" | jq -r '.projects[].packageName') )
              compadd -- "${"$"}{packages[@]}"
              ;;
            3)
              local -a phases
              phases=( $(perl -0777 -pe 's|/\*.*?\*/||gs; s|^\s*//[^\n]*||gm; s|\r||g' "$rush_root/common/config/rush/command-line.json" | jq -r '.phases[].name | sub("^_phase:";"")') )
              compadd -- "${"$"}{phases[@]}"
              ;;
          esac
        }
        compdef _rush_logs_completion rush-logs
      '')
    ];
  };
}
