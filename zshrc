source ~/dotfiles/antigen.zsh

# Load the oh-my-zsh's library.
antigen use oh-my-zsh

# Bundles from the default repo (robbyrussell's oh-my-zsh).
antigen bundle git
antigen bundle command-not-found
antigen-bundle git-flow

# Syntax highlighting bundle.
antigen bundle zsh-users/zsh-syntax-highlighting

# Load the theme.
antigen theme https://gist.github.com/UberMouse/eb671f0d46879a3c3a91 wild-cherry

# Tell antigen that you're done.
antigen apply

source ~/dotfiles/env-vars
source ~/dotfiles/alias-general
source ~/dotfiles/functions
source ~/dotfiles/bookmarks.zsh

#setup rbenv autocomplete
if which rbenv > /dev/null; then eval "$(rbenv init -)"; fi

export NVM_DIR=~/.nvm
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"  # This loads nvm
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh
nvm use default

export PATH="/home/taylor/.pyenv/bin:$PATH"
eval "$(pyenv init -)"
eval "$(pyenv virtualenv-init -)"

# prevents history bleeding across tmux panes
setopt nosharehistory

# added by travis gem
[ -f ~/.travis/travis.sh ] && source ~/.travis/travis.sh

[ -f ~/dotfiles/local-zshrc ] && source ~/dotfiles/local-zshrc

bindkey ' ' magic-space

# added by travis gem
[ -f /Users/taylor/.travis/travis.sh ] && source /Users/taylor/.travis/travis.sh

# Added by Krypton
export GPG_TTY=$(tty)
