{
  programs.zsh = {
    enable = true;
    autocd = true;
    
    shellAliases = {
      l = "ls -ahG";
      szsh = "source ~/.zshrc";
      gmt = "git machete traverse";
      gms = "git machete status";
      gma = "git machete add";
      gmc = "git machete delete-unmanaged";
      gmd = "git machete discover";
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
    '';
  };
}