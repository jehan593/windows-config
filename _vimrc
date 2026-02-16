" ==============================================================================
" 1. THE BASICS & LOOKS
" ==============================================================================
syntax on
set termguicolors
colorscheme nord
set background=dark

set number          " Show line numbers
set relativenumber  " HELPFUL: Makes jumping to lines (e.g., 5j) much faster
set mouse=a         " Mouse support
set clipboard=unnamed " System clipboard sync
set cursorline      " Highlight the line the cursor is on
set noshowmode      " Hide the default '-- INSERT --' (cleaner if you use a status line)

" ==============================================================================
" 2. BETTER TABS & INDENTATION
" ==============================================================================
set tabstop=4
set shiftwidth=4
set expandtab
set smartindent     " Better auto-indenting for C-like languages
set autoindent      " Match indent of previous line

" ==============================================================================
" 3. SEARCH & NAVIGATION
" ==============================================================================
set hlsearch
set incsearch
set ignorecase
set smartcase
set scrolloff=8     " Keep 8 lines above/below cursor (stops it hitting the edge)

" THE 'SPACE' FIX: Clear highlights with space
nnoremap <space> :nohlsearch<CR>