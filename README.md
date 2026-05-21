# smart-completions
*Dynamic completions for Clink*

Extending [Clink](https://github.com/chrisant996/clink) with completions that ~~will~~ should always be up-to-date. These scripts discover subcommands and flags at completion-time by parsing command's own --help output. Because the structure is discovered, rather than hardcoded, these scripts keep working when new subcommands appear or flags are added/renamed.

## Install
1. Clone this repo to a folder of your choice <DIR> (e.g. %LOCALAPPDATA%\clink\smart-completions) and use `clink installscripts <DIR>`
* Or just copy individual files to %CLINK_PROFILE%\scripts
2. Restart the shell

**_Clink_** truly revolutionized the outdated Windows command shell. Please support the project at [https://github.com/chrisant996/clink](https://github.com/chrisant996/clink)✨
