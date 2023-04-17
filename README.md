# Bootstrap a new system

1. Install Curl, Git & i3 `sudo apt install curl git i3 docker`
2. Clone this repository `git clone git@github.com:UberMouse/dotfiles.git ~/dotfiles`
3. [Install Nix](https://github.com/DeterminateSystems/nix-installer)
4. Enable Flakes `mkdir -p ~/.config/nix && echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf`
5. Setup system `nix run home-manager/master switch --flake ~/dotfiles#taylor --cores 10 -j 10 -b bk`
6. Remove apt curl & git `sudo apt remove curl git`
7. Set Zsh as default shell `sudo bash -c "echo $(which zsh) >> /etc/shells" && sudo chsh -s "$(which zsh)" "$(whoami)"` 
8. Log-off and log back in setting window manager to i3
9. Sign into VSCode and install extensions
10. Set Gnome Terminal font to Source Code Pro for Powerline
11. Generate SSH key & add to GitHub