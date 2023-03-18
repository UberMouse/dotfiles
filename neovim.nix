{ pkgs, ... }:

{
  programs.neovim = {
    enable = true;
    defaultEditor = true;
    viAlias = true;
    vimAlias = true;

    plugins = with pkgs.vimPlugins; [
      nerdtree
      syntastic
      vim-surround
      vim-commentary
      vim-gitgutter
      vim-indent-guides
      vim-endwise
      vim-fugitive
      vim-javascript
      vim-airline
    ];

    extraConfig = ''
      set autoindent
      set backspace=indent,eol,start
      set complete-=i
      set smarttab
      set expandtab
      set relativenumber
      set number
      set nrformats-=octal
      set shiftwidth=2
      set clipboard=unnamed
      set backspace=2
      set tabstop=2
      set ignorecase
      set smartcase
      set mouse=a
      set autoread
      set splitbelow
      set splitright
      set breakindent " preserves the indent level of wrapped lines
      set showbreak=↪ " illustrate wrapped lines
      set wrap        " wrapping with breakindent is tolerable
      set noswapfile
      set nobackup

      imap kj <ESC>
      nmap <space> <leader>
      xmap <space> <leader>
      
      nmap <leader>rr :redraw!<CR>
      
      " hjkl in insert mode
      inoremap <A-h> <left>
      inoremap <A-j> <down>
      inoremap <A-k> <up>
      inoremap <A-l> <right>
      
      " insert line before/after current line in normal mode
      nmap <leader>o o<esc>k
      nmap <leader>O O<esc>j
      
      
      " Reload our .vimrc
      nmap <leader>~ :source ~/.vimrc<CR>:redraw!<CR>:AirlineRefresh<CR>:echo "~/.vimrc reloaded!"<CR>
      
      " Write file
      nmap <leader>w :w<CR>
      
      " Delete buffer
      nmap <leader>q :q<CR>
      
      " Toggle wrap
      nmap <leader>W :set invwrap<CR>:set wrap?<CR>
      
      " Reindent the entire file
      nmap <leader>= gg=G``:echo "reindent global"<CR>
      
      " Fugitive mappings
      nmap <leader>gs :Gstatus<cr>
      nmap <leader>gc :Gcommit<cr>
      nmap <leader>gd :Gdiff<cr>
      
      " diff mappings
      nmap <leader>gg :diffget<cr>
      nmap <leader>gp :diffput<cr>
      nmap <leader>gu :diffupdate<cr>
      
      " Open new buffers
      nmap <leader>v  :rightbelow vsp<cr>
      nmap <leader>h   :rightbelow sp<cr>
      nmap <leader>o :only<cr>
      
      "splits
      nnoremap <C-J> <C-W><C-J>
      nnoremap <C-K> <C-W><C-K>
      nnoremap <C-L> <C-W><C-L>
      nnoremap <C-H> <C-W><C-H>
      
      " Yank text to the OS X clipboard
      noremap <leader>y "*y
      noremap <leader>yy "*Y

      " NERDTree
      nmap <leader>n :NERDTreeToggle<CR>
      let NERDTreeQuitOnOpen=1 
      let NERDTreeHighlightCursorline=1
      let NERDTreeIgnore = ['tmp', '.yardoc', 'pkg', 'node_modules']
    '';
  };
}