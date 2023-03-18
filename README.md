# Bootstrap a new system

1. Install Curl, Git & i3 `sudo apt install curl git i3`
2. Clone this repository `git clone git@github.com:UberMouse/dotfiles.git ~/dotfiles`
3. [Install Nix](https://github.com/DeterminateSystems/nix-installer)
4. Enable Flakes `mkdir -p ~/.config/nix && echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf`
5. Setup system, run in `~/dotfiles`: `nix run . switch`
6. Remove apt curl & git `sudo apt remove curl git`
7. Sign into VSCode and install extensions
8. Set Gnome Terminal font to Source Code Pro for Powerline
9. Set Zsh as default shell `sudo chsh -s /home/taylor/.nix-profile/bin/zsh`
10. Generate SSH key & add to GitHub