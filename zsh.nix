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
      gcc = "gnome-control-center network";
      tail-rimu-logs = "tail -f ~/.config/Koordinates/logs/*.log";
      get-latest-rimu-log =
        "echo ~/.config/Koordinates/logs/$(ls -Art ~/.config/Koordinates/logs | tail -n 1)";
      search-latest-rimu-log = "cat $(get-latest-rimu-log) | grep";
      hms =
        "sudo nixos-rebuild switch --flake ~/dotfiles#ubermouse --cores 10 -j 10";
      show-trace = "npx playwright show-trace";
      heft = "node_modules/.bin/heft";
      xclip = "xclip -selection clipboard";
    };

    oh-my-zsh = {
      enable = true;
      custom = "$HOME/dotfiles/zsh-customizations";
      theme = "wild-cherry";
      plugins = [ "git" "command-not-found" "git-flow" ];
    };

    initExtra = ''
      # Otherwise keyboard layout is weird :shrug:
      setxkbmap -layout us

      eval `keychain --eval --quiet --agents ssh id_ed25519`

      function kill-all {
        ps -ef | grep [$1] | awk '{print $2}' | xargs kill -9
      }

      (( ${"$"}{+commands[rush]} )) && {
        _rush_completion() {
          compadd -- $(rush tab-complete --position ${"$"}{CURSOR} --word "${
            "$"
          }{BUFFER}" 2>>/dev/null)
        }
        compdef _rush_completion rush
      }
    '';
  };
}
