" --- Basic Setup ---
let mapleader = " "         " Set Space as the leader key
syntax on                   " Enable syntax highlighting
set termguicolors           " Enable 24-bit RGB colors
colorscheme nord            " Using the Nord theme (ensure it's installed)

" --- General Settings ---
set number                  " Show line numbers
set relativenumber          " Show relative line numbers for easier jumping
set mouse=a                 " Enable mouse support
set clipboard=unnamedplus   " Sync with system clipboard
set cursorline              " Highlight the current line
set scrolloff=8             " Keep 8 lines above/below cursor
set signcolumn=yes          " Prevent text jumping when errors appear

" --- Undo & Backup (The Safety Net) ---
set noswapfile              " No more .swp files
set nobackup                " No more backup files
set undofile                " Maintain undo history between sessions
set undodir=$HOME/vimfiles/undodir  " Store history in one place

" --- Search & Tabs ---
set ignorecase smartcase    " Intelligent case searching
set hlsearch                " Highlight search results
set incsearch               " Search as you type
set expandtab               " Use spaces instead of tabs
set shiftwidth=4            " 1 tab = 4 spaces
set autoindent              " Maintain indentation on new lines

" --- Windows & Splits ---
set splitright              " Vertical splits open to the right
set splitbelow              " Horizontal splits open at the bottom

" Fast split navigation (Ctrl + h/j/k/l)
inoremap jk <Esc>
nnoremap <C-h> <C-w>h
nnoremap <C-j> <C-w>j
nnoremap <C-k> <C-w>k
nnoremap <C-l> <C-w>l

" --- Custom Logic & Keybindings ---

" 1. Saving and Quitting (Your requested shortcuts)
nnoremap <leader>w :w<CR>          " Space + w: Save only
nnoremap <leader>wq :wq<CR>        " Space + w + q: Save and Quit
nnoremap <leader>q :q!<CR>         " Space + q: Quit WITHOUT saving (forced)

" 2. UI and Selection
nnoremap <leader><CR> :noh<CR>     " Space + Enter: Clear search highlights
vnoremap < <gv                     " Stay in visual mode after indenting left
vnoremap > >gv                     " Stay in visual mode after indenting right

" 3. Smart Deleting
nnoremap <leader>d "_d             " Space + d: 'True' delete (Black Hole)
vnoremap <leader>d "_d             " Space + d (Visual): 'True' delete
nnoremap x "_x                     " 'x' key: Delete char without overwriting clipboard