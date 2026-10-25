-- Stock config for Neovim inside pi-container.
-- run.sh copies this to ~/.config/pi-container/nvim/init.lua once, then mounts
-- that host directory read-write at /root/.config/nvim. Edit the host copy.
vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

vim.o.expandtab = true
vim.o.shiftwidth = 4
vim.o.tabstop = 4
vim.o.softtabstop = 4

vim.lsp.config('zls', {
  cmd = { 'zls' },
  filetypes = { 'zig' },
  root_markers = { 'build.zig', 'build.zig.zon', '.git' },
})
vim.lsp.enable('zls')
