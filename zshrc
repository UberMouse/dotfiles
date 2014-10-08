source ~/dots/dotfiles/antigen/antigen.zsh

# Load the oh-my-zsh's library.
antigen use oh-my-zsh

# Bundles from the default repo (robbyrussell's oh-my-zsh).
antigen bundle git
antigen bundle heroku
antigen bundle command-not-found

# Syntax highlighting bundle.
antigen bundle zsh-users/zsh-syntax-highlighting

# Load the theme.
antigen theme https://gist.github.com/UberMouse/e69d92a78f07c2fc957a agnoster

# Tell antigen that you're done.
antigen apply

function gi() { curl http://www.gitignore.io/api/\$@ ;}
