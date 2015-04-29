source ~/dotfiles/antigen.zsh

# Load the oh-my-zsh's library.
antigen use oh-my-zsh

# Bundles from the default repo (robbyrussell's oh-my-zsh).
antigen bundle git
antigen bundle command-not-found

# Syntax highlighting bundle.
antigen bundle zsh-users/zsh-syntax-highlighting

# Load the theme.
antigen theme https://gist.github.com/UberMouse/eb671f0d46879a3c3a91 wild-cherry

# Tell antigen that you're done.
antigen apply

source ~/dotfiles/env-vars
source ~/dotfiles/alias-general

function gi() { curl http://www.gitignore.io/api/\$@ ;}
#setup rbenv autocomplete
if which rbenv > /dev/null; then eval "$(rbenv init -)"; fi

export NVM_DIR="/Users/taylor/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"  # This loads nvm
