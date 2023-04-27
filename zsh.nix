{
  programs.zsh = {
    enable = true;
    autocd = true;
    enableSyntaxHighlighting = true;
    
    dirHashes = {
      kawaka = "$HOME/code/kawaka";
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
      gcc = "gnome-control-center network";
      tail-rimu-logs = "tail -f ~/.config/Koordinates/logs/*.log";
      get-latest-rimu-log = "echo ~/.config/Koordinates/logs/$(ls -Art ~/.config/Koordinates/logs | tail -n 1)";
      search-latest-rimu-log = "cat $(get-latest-rimu-log) | grep";
      hms = "home-manager switch --flake ~/dotfiles#taylor --cores 10 -j 10";
    };
    
    oh-my-zsh = {
      enable = true;
      custom = "$HOME/dotfiles/zsh-customizations";
      theme = "wild-cherry";
      plugins = [
        "git"
        "command-not-found"
        "git-flow"
      ];
    };
    
    initExtra = ''
      # Otherwise keyboard layout is weird :shrug:
      setxkbmap -layout us
      
      eval `keychain --eval --quiet --agents ssh id_ed25519`
      eval "$(github-copilot-cli alias -- "$0")"
    '';
  };
}
