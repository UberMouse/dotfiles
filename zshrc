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

export NVM_DIR="/Users/taylor/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"  # This loads nvm
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# prevents history bleeding across tmux panes
setopt nosharehistory  

function rubocop_git_modified() {
  watch 'rubocop $(git status -uno --porcelain | awk -v ORS=" " "{if((\$1 == \"M\" || \$1 == \"A\") && match(\$2, /.*\.rb/)) print \$2}")'
}

# added by travis gem
[ -f ~/.travis/travis.sh ] && source ~/.travis/travis.sh

[ -f ~/dotfiles/local-zshrc ] && source ~/dotfiles/local-zshrc
