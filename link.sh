directory=$(dirname -- $(readlink -fn -- "$0"))

ln -fs `directory`/vimrc ~/.vimrc
ln -fs `directory`/gvimrc ~/.gvimrc
ln -fs `directory`/rspec ~/.rspec
ln -fs `directory`/zshrc ~/.zshrc
ln -fs `directory`/tmux.conf ~/.tmux.conf
ln -fs `directory`/nvimrc ~/.nvimrc
