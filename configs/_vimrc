" --- Basic Setup ---
let mapleader = " "
syntax on
if has('termguicolors')
    set termguicolors
endif
colorscheme nord

" --- General Settings ---
set number
set relativenumber
set mouse=a
if has('win32')
    set clipboard=unnamed
else
    set clipboard=unnamedplus
endif
set cursorline
set scrolloff=8
set signcolumn=yes

" --- Undo & Backup ---
set noswapfile
set nobackup
set undofile
set undodir=$HOME/vimfiles/undodir
if !isdirectory($HOME.'/vimfiles/undodir')
    call mkdir($HOME.'/vimfiles/undodir', 'p')
endif

" --- Search & Tabs ---
set ignorecase smartcase
set hlsearch
set incsearch
set expandtab
set tabstop=4
set shiftwidth=4
set autoindent

" --- Windows & Splits ---
set splitright
set splitbelow

nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l

" --- Keybindings ---
inoremap jk <Esc>

" Saving and Quitting
nnoremap <leader>w :w<CR>
nnoremap <leader>wq :wq<CR>
nnoremap <leader>q :q!<CR>

" UI and Selection
nnoremap <leader><CR> :noh<CR>
vnoremap < <gv
vnoremap > >gv

" Smart Deleting
nnoremap <leader>d "_d
vnoremap <leader>d "_d
nnoremap x "_x