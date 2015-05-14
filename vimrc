set nocompatible              " be iMproved, required
filetype off                  " required

" set the runtime path to include Vundle and initialize
set rtp+=~/.vim/bundle/Vundle.vim

call vundle#begin()

Plugin 'gmarik/Vundle.vim'

Plugin 'scrooloose/nerdtree'
Plugin 'scrooloose/syntastic'

Plugin 'tpope/vim-surround'
Plugin 'tpope/vim-commentary'
Plugin 'joequery/Stupid-EasyMotion'
Plugin 'airblade/vim-gitgutter'
Plugin 'nathanaelkane/vim-indent-guides'
Plugin 'tpope/vim-endwise'
Plugin 'tpope/vim-fugitive'
Plugin 'AndrewRadev/splitjoin.vim'
Plugin 'pangloss/vim-javascript'
Plugin 'mxw/vim-jsx'
Plugin 'Lokaltog/powerline'

Plugin 'vim-ruby/vim-ruby'
Plugin 'kchmck/vim-coffee-script'
Plugin 'mtscout6/vim-cjsx'
Plugin 'tpope/vim-rails'
Plugin 'KurtPreston/vim-autoformat-rails'

Plugin 'Shougo/unite.vim'

Plugin 'christoomey/vim-tmux-navigator'

Plugin 'bling/vim-airline'
Plugin 'freeo/vim-kalisi'

call vundle#end()            " required

"set terminal to 256 colors
set t_Co=256
syntax on
set background=dark
colorscheme kalisi

filetype plugin indent on    " required

" To ignore plugin indent changes, instead use:
"filetype plugin on
"
" Brief help
" :PluginList          - list configured plugins
" :PluginInstall(!)    - install (update) plugins
" :PluginSearch(!) foo - search (or refresh cache first) for foo
" :PluginClean(!)      - confirm (or auto-approve) removal of unused plugins
"
" see :h vundle for more details or wiki for FAQ
" Put your non-Plugin stuff after this line
"

let mapleader = ","

set guifont=Inconsolata\ 
let g:Powerline_symbols = 'fancy'
set encoding=utf-8
set t_Co=256
set fillchars+=stl:\ ,stlnc:\
set termencoding=utf-8
set relativenumber 
set number
set expandtab
set modelines=0
set shiftwidth=2
set clipboard=unnamed
set synmaxcol=512
set ttyscroll=10
set backspace=2
set encoding=utf-8
set tabstop=2
set wrap
set number
set nowritebackup
set noswapfile
set nobackup
set nowrap
set linebreak
set hlsearch
set ignorecase
set smartcase
set mouse=a
set ttyfast
set ttymouse=xterm2
set autoread 
set splitbelow
set splitright

if exists('+breakindent')
  set breakindent " preserves the indent level of wrapped lines
  set showbreak=↪ " illustrate wrapped lines
  set wrap        " wrapping with breakindent is tolerable
endif

if exists('$TMUX')
  let &t_SI = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=1\x7\<Esc>\\"
  let &t_EI = "\<Esc>Ptmux;\<Esc>\<Esc>]50;CursorShape=0\x7\<Esc>\\"
else
  let &t_SI = "\<Esc>]50;CursorShape=1\x7"
  let &t_EI = "\<Esc>]50;CursorShape=0\x7"
endif

" Airline.vim customizations
set noshowmode " Hide mode line text since it's already in Airline
let g:airline#extensions#tabline#enabled = 1

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

" Search for word under cursor in Dash.app
nmap <leader>d <Plug>DashSearch
nmap <leader>D <Plug>DashGlobalSearch

" Stupid Easy Motion mappings
map <C-w> <leader><leader>w
imap <C-w> <leader><leader>w
map <C-e> <leader><leader>W
imap <C-e> <leader><leader>W
map <A-f> <leader><leader>f
imap <A-f> <leader><leader>f

let NERDTreeQuitOnOpen=1 
let g:airline_theme='kalisi'
let g:airline_powerline_fonts = 1

autocmd StdinReadPre * let s:std_in=1

au BufNewFile * set noeol

" No show command
autocmd VimEnter * set nosc

" Move lines up/down
nnoremap <A-j> :m .+1<CR>==
nnoremap <A-k> :m .-2<CR>==
inoremap <A-j> <Esc>:m .+1<CR>==gi
inoremap <A-k> <Esc>:m .-2<CR>==gi
vnoremap <A-j> :m '>+1<CR>gv=gv
vnoremap <A-k> :m '<-2<CR>gv=gv

" open Unite in fuzzy search mode
nnoremap <Leader>f :Unite -start-insert file_rec<CR>
let s:file_rec_ignore_globs = ['node_modules/**']
call unite#custom#source('file_rec', 'ignore_globs', s:file_rec_ignore_globs)
call unite#custom#source('grep', 'ignore_globs', s:file_rec_ignore_globs)

" reload current file
nmap <leader>r :e!<CR>

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

" diff current file against last save
nmap <leader>dd :w !diff % -<CR>

" Preserve indentation while pasting text from the OS X clipboard
noremap <leader>p :set paste<CR>:put  *<CR>:set nopaste<CR>


" tmux shortcuts
map <leader>b :call Send_to_Tmux("bundle\n")<CR>
map <leader>c :call Send_to_Tmux("clear\n")<CR>

" NERDTree
nmap <leader>n :NERDTreeToggle<CR>
let NERDTreeHighlightCursorline=1
let NERDTreeIgnore = ['tmp', '.yardoc', 'pkg', 'node_modules']
