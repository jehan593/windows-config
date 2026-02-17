" --- General Settings ---
set number              " Show line numbers
set mouse=a             " Enable mouse support (helpful while learning)
set clipboard=unnamed " Use system clipboard (copy/paste from other apps)

" --- Search Settings ---
set ignorecase          " Ignore case when searching
set smartcase           " ...unless search contains a capital letter
set hlsearch            " Highlight all search results
set incsearch           " Show search results as you type

" --- Indentation ---
set expandtab           " Use spaces instead of tabs
set shiftwidth=4        " 1 tab = 4 spaces
set autoindent          " Copy indent from previous line

" --- UI ---
syntax on               " Enable syntax highlighting
set termguicolors       " Enable 24-bit RGB colors
colorscheme nord

set noswapfile            " Stop creating swap files
set nobackup             " Stop creating backup files
set undofile              " Maintain undo history between sessions
set undodir=$HOME/vimfiles/undodir " Store that history in one central place

set cursorline          " Highlight the line the cursor is on
set scrolloff=8         " Keep 8 lines above/below cursor (stops it hitting the edge)
set signcolumn=yes      " Always show the gutter (prevents text jumping when errors appear)
set splitright          " Vertical splits open to the right
set splitbelow          " Horizontal splits open at the bottom

set relativenumber      " Show relative line numbers
set wildmenu            " Visual autocomplete for command menu
set showmatch           " Highlight matching brackets