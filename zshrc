source ~/dotfiles/antigen.zsh

# Load the oh-my-zsh's library.
antigen use oh-my-zsh

# Bundles from the default repo (robbyrussell's oh-my-zsh).
antigen bundle git
antigen bundle command-not-found
antigen bundle git-flow

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

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# prevents history bleeding across tmux panes
setopt nosharehistory

[ -f ~/dotfiles/local-zshrc ] && source ~/dotfiles/local-zshrc

bindkey ' ' magic-space

# Added by Krypton
export GPG_TTY=$(tty)
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

_rush_bash_complete()
{
  local word=${COMP_WORDS[COMP_CWORD]}

  local completions
  completions="$(rush tab-complete --position "${COMP_POINT}" --word "${COMP_LINE}" 2>/dev/null)"
  if [ $? -ne 0 ]; then
    completions=""
  fi

  COMPREPLY=( $(compgen -W "$completions" -- "$word") )
}

complete -f -F _rush_bash_complete rush

# pnpm
export PNPM_HOME="/home/ubermouse/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
# pnpm end

eval `keychain --eval --agents ssh id_ed25519`
