# Oyen.nvim

named after my favourite penguin, oyen.

## Default Config

```lua
{
    max_history_size = 30,
    popup_timeout = 1000,
    popup_max_display = 5,
    path_display = {
        enabled = true,
        mode = "default",
        project_roots = {
            "pom.xml",
            "build.gradle",
            ".git",
            "package.json",
            "Cargo.toml",
            "Makefile",
            ".project",
            ".luacheckrc",
        },
    },
    separator = " 󰇘 ",
    keymaps = {
        next = "<C-n>",
        prev = "<C-p>",
        change_mode = "<leader><leader>",
    },
    popup = {
        title = "Oyen",
        title_pos = "center",
        border = "rounded",
    },
}

```
