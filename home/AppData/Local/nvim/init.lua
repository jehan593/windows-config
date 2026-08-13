-- 1. Globals
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- 2. Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
    vim.fn.system({
        "git", "clone", "--filter=blob:none",
        "https://github.com/folke/lazy.nvim.git",
        "--branch=stable", lazypath,
    })
end
vim.opt.rtp:prepend(lazypath)

-- 3. Plugins
require("lazy").setup({
    -- Colorscheme
    {
        "gbprod/nord.nvim",
        priority = 1000,
        config = function()
            require("nord").setup({})
            vim.cmd.colorscheme("nord")
        end,
    },

    -- Telescope (fuzzy finder)
    {
        "nvim-telescope/telescope.nvim",
        tag = "0.1.8",
        dependencies = { "nvim-lua/plenary.nvim" },
        config = function()
            require("telescope").setup({})
        end,
    },
})

-- 4. Options
vim.opt.number         = true
vim.opt.relativenumber = true
vim.opt.cursorline     = true
vim.opt.scrolloff      = 8
vim.opt.tabstop        = 4
vim.opt.shiftwidth     = 4
vim.opt.expandtab      = true
vim.opt.clipboard      = "unnamedplus"
vim.opt.termguicolors  = true
vim.opt.wrap           = false
vim.opt.ignorecase = true   -- case-insensitive search
vim.opt.smartcase  = true   -- ...unless you type uppercase
vim.opt.hlsearch   = true   -- highlight all matches
vim.opt.incsearch  = true   -- show matches as you type

-- 5. Keymaps
vim.keymap.set("i", "jk", "<Esc>")
vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<CR>")
vim.keymap.set("n", "<leader>q",  "<cmd>qa!<CR>", { desc = "Quit All" })
vim.keymap.set("n", "<leader>wq", "<cmd>wq<CR>",  { desc = "Save and Quit" })

-- Telescope
local telescope_builtin = require("telescope.builtin")
vim.keymap.set("n", "<leader>ff", telescope_builtin.find_files, { desc = "Find Files" })
vim.keymap.set("n", "<leader>fg", telescope_builtin.live_grep,  { desc = "Live Grep" })
vim.keymap.set("n", "<leader>fb", telescope_builtin.buffers,    { desc = "Find Buffers" })
vim.keymap.set("n", "<leader>fh", telescope_builtin.help_tags,  { desc = "Help Tags" })