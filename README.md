# reaper-updater

A small shell script that downloads and installs the latest Linux x86_64 version of [REAPER](https://www.reaper.fm) automatically.

Close REAPER. Run the script. Open REAPER. New version. That's the whole workflow.

## Background

This is a fork of [inyourfoss/reaper-updater](https://github.com/inyourfoss/reaper-updater) (GPL-2.0). The original script does the actual work, scraping the download page and calling the official installer, and credit for that belongs to the upstream author.

I forked it because I wanted to remove the last bit of friction from my update routine: notice a new REAPER release, run one command, done. No prompts, no paths to type, no clicking through dialogs.

A heads-up: I'm not a shell script veteran. I had a clear idea of what I wanted to change, and I used Claude Code (via VS Code) to help with the actual refactoring and to cross-check things against the official Cockos installer code. The script is about 300 lines, half of which are comments, and the only URL it talks to is hardcoded as `reaper.fm`. Read it before running it.

## What this fork changes

- **Argument parsing works now.** In the original, options with values like `-p /some/path` weren't getting consumed properly. Fixed.
- **Less noisy installer output.** The Cockos installer prints its own banner and an "install to X" line. Those collided with this script's step labels, so I pass `--quiet` to keep things tidy.
- **REAPER gets found automatically.** The script checks the two standard install locations (`~/opt` and `/opt`). If REAPER is there, no questions asked. If it's elsewhere, you get asked once.
  - **The path gets remembered.** Stored in `~/.config/reaper-updater/config`. You only ever see that prompt once.
- **It checks things before doing damage.** Missing tools, corrupt download, no write permission, etc. get caught with a clear error before anything irreversible happens.
- **Numbered step output.** `[1/7] Check dependencies`, etc. So you can tell where you are.
- **One real bug fix.** In the original, combining `-a` (keep the downloaded file) with a normal install didn't work, because the file got moved out of `/tmp` before unpacking. The archiving step now happens at the end.

The core logic (scrape the page, download, run the official installer) is unchanged from upstream.

## Features

- Detects REAPER automatically at the standard install locations
- Runs the official Cockos installer hands-off
- Optional flags to archive the downloaded file or only download
- Clear step output and error messages
- POSIX shell, tested with bash and dash

## Requirements

These need to be installed:

- `curl`
- `xmllint` (usually in `libxml2-utils` or `libxml2`)
- `tar`
- `bash` (the REAPER installer itself needs it)
- `xdg-user-dirs` (only when using `--archive` without a path, or `--get-only`)

On Debian/Ubuntu/Mint:

```sh
sudo apt install curl libxml2-utils tar xdg-user-dirs
```

On Arch:

```sh
sudo pacman -S curl libxml2 tar xdg-user-dirs
```

On Fedora:

```sh
sudo dnf install curl libxml2 tar xdg-user-dirs
```

## Installation

Clone and make it executable:

```sh
git clone https://github.com/void-patch/reaper-updater.git
cd reaper-updater
chmod +x reaper-updater.sh
```

I run it via an alias so I can just type `reaper-update` anywhere:

```sh
# in ~/.bashrc or ~/.zshrc
alias reaper-update='/path/to/reaper-updater.sh'
```

A symlink into your PATH works just as well:

```sh
ln -s "$(pwd)/reaper-updater.sh" ~/.local/bin/reaper-update
```

## Usage

If your REAPER is at one of the standard locations (`~/opt/REAPER` or `/opt/REAPER`), the script just runs:

```
$ ./reaper-updater.sh
Detected REAPER at /home/you/opt/REAPER
[1/7] Check dependencies
[2/7] Fetch current download link
    -> https://www.reaper.fm/files/7.x/reaper742_linux_x86_64.tar.xz
[3/7] Download tarball to /tmp
[4/7] Verify tarball integrity
[5/7] Extract tarball
[6/7] Install to /home/you/opt/REAPER
[7/7] Clean up /tmp

Done. REAPER is installed at: /home/you/opt/REAPER
```

If your REAPER is somewhere else, it asks once:

```
$ ./reaper-updater.sh

REAPER was not found at /home/you/opt or /opt.

If REAPER is installed in another location, enter that path below.
(The script expects to find <path>/REAPER/reaper there.)

Path [Enter for default /home/you/opt]: /home/you/Software
Saved install path to /home/you/.config/reaper-updater/config
[1/7] ...
```

From then on, the saved path is used silently.

## Options

| Option | What it does |
|--------|--------------|
| `-h`, `--help`, `help` | Show help |
| `-p`, `--path <PATH>` | Use this path just for this run (doesn't change the saved config) |
| `-a`, `--archive <PATH>` | Keep the downloaded file at `<PATH>` instead of deleting it. Without `<PATH>`, uses `~/Downloads`. |
| `-g`, `--get-only` | Just download, don't install |
| `--reconfigure` | Forget the saved path and ask again |

## How REAPER gets detected

When you run the script, it figures out where to install in this order:

1. Whatever you passed via `-p` (just for this run, not saved)
2. If you passed `--reconfigure`, the saved config gets wiped and you're asked again
3. The standard locations: `~/opt` first, then `/opt`
4. The saved config file at `~/.config/reaper-updater/config`
5. If none of the above worked, you get asked

A directory counts as a REAPER install if it contains the binary at `<path>/REAPER/reaper`. That's the same thing the official installer checks for.

## Configuration

When the script does have to ask for a path, it writes the answer to:

```
~/.config/reaper-updater/config
```

(More precisely, `$XDG_CONFIG_HOME/reaper-updater/config` if that variable is set.)

The file is a single line:

```sh
install_path="/home/you/Software"
```

You can edit it by hand, delete it, or run the script with `--reconfigure` to start over.

## What happens during an update

Roughly, in order:

1. Fetch the REAPER download page
2. Pull out the current Linux x86_64 download link from the HTML
3. Download the tarball to `/tmp`
4. Verify it's not corrupt
5. Unpack it
6. Run Cockos' official `install-reaper.sh` with your install path
7. Clean up `/tmp`

The script does NOT touch your REAPER configuration (`~/.config/REAPER/`), your plugins, or anything outside the install path. Your settings and projects stay where they are.

## Security

The script only talks to `https://www.reaper.fm`. The URL is hardcoded near the top of the script.

The thing doing the actual installation is `install-reaper.sh` from inside the official Cockos tarball. This wrapper just downloads and runs it.

If you want to see exactly what's happening, run it with `sh -x reaper-updater.sh` to trace every command as it executes.

## License

GPL-2.0, inherited from the upstream project. See `LICENSE`.

## Credits

- Upstream author: [inyourfoss](https://github.com/inyourfoss)
- This fork was developed with the help of Claude Code. I described what I wanted to change, Claude helped with the refactoring and verified the behaviour against the official Cockos installer. All changes were reviewed and tested before publishing.
