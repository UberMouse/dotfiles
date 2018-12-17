call plug#begin('~/.config/nvim/plugged')

Plug 'scrooloose/nerdtree'
Plug 'w0rp/ale'
Plug 'sbdchd/neoformat'

Plug 'tpope/vim-surround'
Plug 'tpope/vim-commentary'
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-sleuth'
Plug 'joequery/Stupid-EasyMotion'
Plug 'airblade/vim-gitgutter'

Plug 'pangloss/vim-javascript', {'for': 'javascript'}
Plug 'vim-ruby/vim-ruby', {'for': ['ruby', 'eruby']}
Plug 'mxw/vim-jsx', {'for': 'javascript'}
Plug 'tpope/vim-rails'
Plug 'leafgarland/typescript-vim'
Plug 'Quramy/tsuquyomi'
Plug 'Shougo/vimproc.vim', {'do' : 'make'}
Plug 'junegunn/fzf', { 'dir': '~/.fzf', 'do': './install --all' }
" Plug 'Valloric/YouCompleteMe', { 'do': './install.py' }

Plug 'christoomey/vim-tmux-navigator'

Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'
Plug 'Lokaltog/powerline'

Plug 'freeo/vim-kalisi'
Plug 'rhysd/committia.vim'
Plug 'wakatime/vim-wakatime'

call plug#end()

" vim-javascript
let g:javascript_conceal_function   = "ƒ"
let g:javascript_enable_domhtmlcss  = 1

" vim-ruby
let g:jsx_ext_required = 0

let g:tsuquyomi_use_local_typescript = 1

filetype plugin indent on

syntax on

set background=dark
colorscheme kalisi
let g:airline_theme='kalisi'
let g:airline_powerline_fonts = 1

let mapleader = ","

highlight ExtraWhitespace ctermbg=red guibg=red
match ExtraWhitespace /\s\+$/
autocmd BufWinEnter * match ExtraWhitespace /\s\+$/
autocmd InsertEnter * match ExtraWhitespace /\s\+\%#\@<!$/
autocmd InsertLeave * match ExtraWhitespace /\s\+$/
autocmd BufWinLeave * call clearmatches()

set guifont=Inconsolata\
let g:Powerline_symbols = 'fancy'

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

" Airline.vim customizations
set noshowmode " Hide mode line text since it's already in Airline
let g:airline#extensions#tabline#enabled = 1

filetype plugin on
set omnifunc=syntaxcomplete#Complete

if !exists("g:gui_oni")
  autocmd FileType typescript call SetTypescriptConfiguration()
endif

function SetTypescriptConfiguration()
  nmap <buffer> <leader>gd <Plug>(TsuDefinition)
  nmap <buffer> <leader>gr <Plug>(TsuReferences)
  nmap <buffer> <leader>rt <Plug>(TsuquyomiRenameSymbol)
  nmap <buffer> <leader>st : <C-u>echo tsuquyomi#hint()<CR>
endfunction
imap kj <ESC>
nmap <space> <leader>
xmap <space> <leader>
inoremap <C-x> <C-x><C-o>

nmap <leader>rr :redraw!<CR>

if !exists("g:gui_oni")
  nmap <leader>rc :Neoformat<CR>
endif

" hjkl in insert mode
inoremap <A-h> <left>
inoremap <A-j> <down>
inoremap <A-k> <up>
inoremap <A-l> <right>

" insert line before/after current line in normal mode
nmap <leader>o o<esc>k
nmap <leader>O O<esc>j

" Write file
nmap <leader>w :w<CR>

" Delete buffer
nmap <leader>q :q<CR>

" Toggle wrap
nmap <leader>W :set invwrap<CR>:set wrap?<CR>

" Reindent the entire file
nmap <leader>= gg=G``:echo "reindent global"<CR>

" Stupid Easy Motion mappings
map <C-w> <leader><leader>w
imap <C-w> <leader><leader>w
map <C-e> <leader><leader>W
imap <C-e> <leader><leader>W
map <A-f> <leader><leader>f
imap <A-f> <leader><leader>f

let NERDTreeQuitOnOpen=1

" Move lines up/down
nnoremap <A-j> :m .+1<CR>==
nnoremap <A-k> :m .-2<CR>==
inoremap <A-j> <Esc>:m .+1<CR>==gi
inoremap <A-k> <Esc>:m .-2<CR>==gi
vnoremap <A-j> :m '>+1<CR>gv=gv
vnoremap <A-k> :m '<-2<CR>gv=gv

" reload current file
nmap <leader>r :e!<CR>

" Open new buffers
nmap <leader>v  :rightbelow vsp<cr>
nmap <leader>h   :rightbelow sp<cr>

"splits
if has('nvim')
  nmap <BS> <C-H>
endif
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

if !exists("g:gui_oni")
  nmap <leader>n :NERDTreeToggle<CR>
  let NERDTreeHighlightCursorline=1
  let NERDTreeIgnore = ['tmp', '.yardoc', 'pkg', 'node_modules']

  nmap <leader>f :FZF<CR>
endif

set ttimeout
set ttimeoutlen=100

set incsearch
" Use <C-L> to clear the highlighting of :set hlsearch.
if maparg('<C-L>', 'n') ==# ''
  nnoremap <silent> <C-L> :nohlsearch<CR><C-L>
endif

set laststatus=2
set ruler
set showcmd
set wildmenu

if !&scrolloff
  set scrolloff=1
endif
if !&sidescrolloff
  set sidescrolloff=5
endif
set display+=lastline

if &encoding ==# 'latin1' && has('gui_running')
  set encoding=utf-8
endif

if &listchars ==# 'eol:$'
  set listchars=tab:>\ ,trail:-,extends:>,precedes:<,nbsp:+
endif

if v:version > 703 || v:version == 703 && has("patch541")
  set formatoptions+=j " Delete comment character when joining commented lines
endif

if has('path_extra')
  setglobal tags-=./tags tags-=./tags; tags^=./tags;
endif

set autoread
set fileformats+=mac

if &history < 1000
  set history=1000
endif
if &tabpagemax < 50
  set tabpagemax=50
endif
if !empty(&viminfo)
  set viminfo^=!
endif
set sessionoptions-=options

" Load matchit.vim, but only if the user hasn't installed a newer version.
if !exists('g:loaded_matchit') && findfile('plugin/matchit.vim', &rtp) ==# ''
  runtime! macros/matchit.vim
endif

inoremap <C-U> <C-G>u<C-U>

let g:committia_hooks = {}
function! g:committia_hooks.edit_open(info)
    " Additional settings
    setlocal spell

    " If no commit message, start with insert mode
    if a:info.vcs ==# 'git' && getline(1) ==# ''
        startinsert
    end

    " Scroll the diff window from insert mode
    " Map <C-n> and <C-p>
    imap <buffer><C-f> <Plug>(committia-scroll-diff-down-page)
    imap <buffer><C-b> <Plug>(committia-scroll-diff-up-page)
endfunction
" vim:set ft=vim et sw=2:
