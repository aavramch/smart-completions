# smart-completions
*Dynamic completions for Clink*

Extending [Clink](https://github.com/chrisant996/clink) with completions that ~~will~~ should always be up-to-date. These scripts discover subcommands and flags at completion-time by parsing command's own --help output. Because the structure is discovered, rather than hardcoded, these scripts keep working when new subcommands appear or flags are added/renamed.

## Included completions

* **Docker** (`docker.lua`) discovers Docker commands, options, and common
  resource names such as containers, images, and networks.
* **WSL** (`wsl.lua`) discovers the switches supported by the installed
  `wsl.exe` and completes installed distribution names. It handles both normal
  text and the UTF-16LE output produced by some WSL versions when redirected.

## Install
1. Clone this repo to a folder of your choice `<DIR>` (for example,
   `%LOCALAPPDATA%\clink\smart-completions`) and run
   `clink installscripts <DIR>`. Alternatively, copy individual `.lua` files
   to the profile directory reported by `clink info`, or to its
   `completions` subdirectory for on-demand loading.
2. Restart the shell (or use Clink's `clink-reload` binding, `Ctrl-X Ctrl-R`
   by default).

**_Clink_** truly revolutionized the outdated Windows command shell. Please support the project at [https://github.com/chrisant996/clink](https://github.com/chrisant996/clink)✨
