directory="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

ln -fs ${directory}/rspec ~/.rspec
ln -fs ${directory}/zshrc ~/.zshrc
ln -fs ${directory}/tmux.conf ~/.tmux.conf
ln -fs ${directory}/skhdrc ~/.skhdrc
ln -fs ${directory}/chunkwmrc ~/.chunkwmrc
mkdir -p ~/.config/nvim
ln -fs ${directory}/nvimrc ~/.config/nvim/init.vim
