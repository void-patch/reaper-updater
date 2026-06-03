#!/bin/sh
###############################################################################
# reaper-updater.sh
# https://github.com/void-patch/reaper-updater
# 
# Fork of: https://github.com/inyourfoss/reaper-updater
# Original author: inyourfoss
# License: GPL-2.0 (inherited from upstream)
#
# Purpose:
#   Downloads the latest Linux x86_64 version of REAPER (https://reaper.fm)
#   and installs it automatically. Optionally archives the tarball or only
#   downloads it without installing.
#
# Differences from upstream:
#   - Rewritten argument parsing using shift (the original could not consume
#     option values like '-p /path' as separate arguments)
#   - Quiet, single-command operation: '--quiet' flag for the REAPER installer
#     suppresses its banner output so it does not duplicate our step labels
#   - Automatic install path detection: looks for an existing REAPER at the
#     two standard locations ~/opt and /opt (in that order) and uses it
#     without asking
#   - Persistent config in $XDG_CONFIG_HOME/reaper-updater/config for custom
#     install paths (asked once, remembered afterwards)
#   - Added preflight checks: dependencies, tarball integrity, write rights
#   - Numbered [N/M] step output and clearer error messages
#   - Bug fix: archive step now runs after install (upstream moved the tarball
#     out of /tmp before extraction, breaking '-a' combined with install)
#
# How it works:
#   1. Scrapes the download page via xmllint XPath for the Linux x86_64 link
#   2. Downloads the tarball to /tmp
#   3. Extracts it
#   4. Runs the bundled install-reaper.sh
#   5. Cleans up /tmp
#
# Install path detection (in order of precedence):
#   1. -p / --path <PATH>             one-off CLI override
#   2. --reconfigure                  forget saved path, prompt again
#   3. Standard locations             ~/opt then /opt, if REAPER is detected
#   4. Saved config file              if it points to a valid REAPER install
#   5. Prompt the user                asks where the user's REAPER lives
#
# Detection criterion:
#   A directory counts as a REAPER install if it contains the executable
#   <path>/REAPER/reaper.
#
# Note:
#   The official REAPER installer suggests '/opt' or '~/opt' as install
#   targets, with '~/opt' as the preferred user-level location. Both are
#   auto-detected by this script (in that priority order). For a fresh
#   install at a non-standard location, run the script once and answer
#   the prompt; the answer is remembered.
#
# Configuration:
#   When the script has to prompt (case 5), the answer is stored in
#   $XDG_CONFIG_HOME/reaper-updater/config so the prompt only happens once.
#   Use --reconfigure to reset it.
#
# Dependencies:
#   libxml2-utils (xmllint), curl, tar, bash (for the REAPER installer),
#   POSIX shell, xdg-user-dirs (only for --archive without path or --get-only)
#
# Tested with bash and dash.
#
# Usage examples:
#   ./reaper-updater.sh                       # Default install/update
#   ./reaper-updater.sh -p /opt/audio         # Custom path (one-off)
#   ./reaper-updater.sh -a ~/Downloads        # Install and keep tarball
#   ./reaper-updater.sh -g                    # Download only, no install
#   ./reaper-updater.sh --reconfigure         # Forget saved path
#   ./reaper-updater.sh --help                # Show help
###############################################################################

# ----------------------------- Global Variables ------------------------------
URL="https://www.reaper.fm"

# Standard locations that the official REAPER installer suggests by default,
# in priority order: user-level first, then system-wide.
# Per the official install-reaper.sh: '/opt' or '~/opt', with '~/opt'
# preferred since it does not require root.
DEFAULT_INSTALL_PATH="$HOME/opt"
DETECTION_PATHS="$HOME/opt /opt"

# XDG Base Directory compliant config location
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/reaper-updater"
CONFIG_FILE="$CONFIG_DIR/config"

# Step counter for status output
STEP=0
TOTAL_STEPS=0


# =============================================================================
#                                  FUNCTIONS
# =============================================================================

# Prints a numbered status message: [N/M] <text>
step() {
    STEP=$((STEP + 1))
    echo "[$STEP/$TOTAL_STEPS] $1"
}


# --- Install path detection --------------------------------------------------

# Returns 0 if the given path contains an actual REAPER installation.
# Criterion: the main executable <path>/REAPER/reaper exists and is runnable.
has_reaper_install() {
    [ -x "$1/REAPER/reaper" ]
}

# Loads install_path from the config file if it exists
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONFIG_FILE"
    fi
}

# Writes the current install_path to the config file
save_config() {
    mkdir -p "$CONFIG_DIR"
    printf 'install_path="%s"\n' "$install_path" > "$CONFIG_FILE"
    echo "Saved install path to $CONFIG_FILE"
}

# Prompts the user for the install path. The phrasing assumes the user
# already has REAPER somewhere (since this is an updater); falling back to
# the default also works for a fresh install.
prompt_install_path() {
    echo ""
    echo "REAPER was not found at $HOME/opt or /opt."
    echo ""
    echo "If REAPER is installed in another location, enter that path below."
    echo "(The script expects to find <path>/REAPER/reaper there.)"
    echo ""
    printf "Path [Enter for default %s]: " "$DEFAULT_INSTALL_PATH"
    read -r user_input
    if [ -z "$user_input" ]; then
        install_path="$DEFAULT_INSTALL_PATH"
    else
        # Expand ~ manually since 'read' does not expand it
        case "$user_input" in
            "~"|"~/"*) user_input="$HOME${user_input#~}" ;;
        esac
        install_path="$user_input"
    fi
    save_config
}

# Determines the install path according to the precedence rules in the header
resolve_install_path() {
    # 1. CLI override always wins
    if [ -n "$install_path_override" ]; then
        install_path="$install_path_override"
        return
    fi

    # 2. --reconfigure: forget any saved path and re-prompt
    if [ -n "$reconfigure" ]; then
        rm -f "$CONFIG_FILE"
        install_path=""
        prompt_install_path
        return
    fi

    # 3. Try the standard locations in priority order (~/opt, then /opt)
    for candidate in $DETECTION_PATHS; do
        if has_reaper_install "$candidate"; then
            install_path="$candidate"
            echo "Detected REAPER at $install_path/REAPER"
            return
        fi
    done

    # 4. Try the saved config path
    load_config
    if [ -n "$install_path" ] && has_reaper_install "$install_path"; then
        echo "Detected REAPER at $install_path/REAPER (from config)"
        return
    fi

    # 5. Either first install or REAPER was moved/uninstalled: ask the user
    install_path=""
    prompt_install_path
}


# --- Pre-flight checks -------------------------------------------------------

# Check 1: all required CLI tools must be available
check_dependencies() {
    missing=""
    for cmd in curl xmllint tar bash; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        echo "Error: missing dependencies:$missing" >&2
        echo "Install them via your distribution's package manager." >&2
        exit 1
    fi
}

# Check 2: verify tarball integrity after download
verify_tarball() {
    if ! tar -tf /tmp/reaper*.tar.xz >/dev/null 2>&1; then
        echo "Error: tarball /tmp/reaper*.tar.xz is corrupt or incomplete." >&2
        exit 1
    fi
}

# Check 3: install path must exist (or be creatable) and writable
check_install_path_writable() {
    if ! mkdir -p "$install_path" 2>/dev/null; then
        echo "Error: cannot create install path: $install_path" >&2
        echo "Check permissions or choose a different path via -p" >&2
        exit 1
    fi
    if [ ! -w "$install_path" ]; then
        echo "Error: no write permission for install path: $install_path" >&2
        exit 1
    fi
}


# --- Core operations ---------------------------------------------------------

# Scrapes the download page for the Linux x86_64 tarball link
get_dl_path() {
    xpath_string="//img[@class='downloadbutton']/parent::a[contains(@href,'linux_x86_64')]/@href"
    curl -s "$URL/download.php" \
        | xmllint --html --xpath "$xpath_string" - 2>/dev/null \
        | cut -d'=' -f2 \
        | tr -d "\""
}

# POSIX substring check: returns 0 if $1 is contained in $2
string_contain() {
    _ret=1
    case $2 in
        *$1*) _ret=0 ;;
    esac
    return $_ret
}

# Downloads the REAPER tarball into /tmp.
# Aborts with an error if curl fails (network, 404, etc.)
reaper_dl() {
    _pwd=$(pwd)
    if ! ( cd /tmp && curl -OL --fail "$dl_link" ); then
        echo "Error: download failed ($dl_link)" >&2
        echo "Check your network or whether the URL is still valid." >&2
        cd "$_pwd" 2>/dev/null
        exit 1
    fi
    cd "$_pwd" || exit 1
}

# Extracts the tarball into /tmp
reaper_unpack() {
    if ! tar -xaf /tmp/reaper*.tar.xz --directory=/tmp; then
        echo "Error: extraction failed." >&2
        exit 1
    fi
}

# Runs the REAPER installer shipped inside the tarball.
# --integrate-user-desktop adds menu entry and MIME associations
# --quiet suppresses the installer's banner and "install to <path>" message
# (the installer is already non-interactive when --install is passed; --quiet
#  just makes the output cleaner so it does not duplicate our step labels)
reaper_install() {
    if ! bash /tmp/reaper_linux_x86_64/install-reaper.sh \
            --install "$install_path" \
            --integrate-user-desktop \
            --quiet; then
        echo "Error: REAPER installer exited with non-zero status." >&2
        exit 1
    fi
}

# Removes the tarball and the extracted directory from /tmp
reaper_remove() {
    rm -f /tmp/reaper*.tar.xz
    rm -rf /tmp/reaper_linux_x86_64
}

# Moves the tarball to the archive path.
# Supports both absolute paths and ~ notation (when passed quoted).
reaper_archive() {
    if string_contain '~' "$1"; then
        rel_to_home=$(echo "$1" | tr -d "~")
        target="$HOME$rel_to_home"
    else
        target="$1"
    fi
    mkdir -p "$target"
    if ! mv /tmp/reaper*.tar.xz "$target"; then
        echo "Error: could not move tarball to $target" >&2
        exit 1
    fi
}


# --- Help --------------------------------------------------------------------

show_help() {
    printf '
USAGE:
  ./reaper-updater.sh [options]

DESCRIPTION:
  Downloads and installs the latest Linux x86_64 version of REAPER.

  The script auto-detects an existing REAPER installation at the standard
  locations ~/opt/REAPER and /opt/REAPER. If found nothing has to be
  configured.

  If REAPER lives elsewhere, the script asks once and stores the path in
  %s for future runs.

OPTIONS:
  -h, --help, help
      Show this help

  -p, --path <PATH>
      One-off install path override. Does NOT modify the saved config.

  -a, --archive <PATH>
      Keep the downloaded tarball at <PATH> instead of deleting it.
      Without <PATH>, ~/Downloads is used.

  -g, --get-only
      Download only, do not install.
      Saves to ~/Downloads (or the path given with -a).

  --reconfigure
      Forget the saved install path and prompt again.

EXAMPLES:
  ./reaper-updater.sh
  ./reaper-updater.sh --path /opt/audio
  ./reaper-updater.sh --path /opt/audio --archive ~/Downloads
  ./reaper-updater.sh --get-only
  ./reaper-updater.sh --reconfigure
' "$CONFIG_FILE"
}


# =============================================================================
#                              ARGUMENT PARSING
# =============================================================================

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|help)
            show_help
            exit 0
        ;;
        -p|--path)
            if [ -z "$2" ]; then
                echo "Error: $1 requires a path argument" >&2
                exit 1
            fi
            install_path_override="$(echo "$2" | tr -s '/')"
            shift 2
        ;;
        -a|--archive)
            if [ -n "$2" ] && [ "${2#-}" = "$2" ]; then
                archive_path="$2"
                shift 2
            else
                archive_path="$(xdg-user-dir DOWNLOAD)"
                shift 1
            fi
        ;;
        -g|--get-only)
            [ -z "$archive_path" ] && archive_path="$(xdg-user-dir DOWNLOAD)"
            download_only=0
            shift 1
        ;;
        --reconfigure)
            reconfigure=0
            shift 1
        ;;
        *)
            echo "Unknown option: $1" >&2
            echo "See help: $0 --help" >&2
            exit 1
        ;;
    esac
done


# =============================================================================
#                                MAIN PROGRAM
# =============================================================================

# Validate dependencies first (before doing anything else)
check_dependencies

# Resolve install path according to precedence rules
resolve_install_path

# Strip trailing slash
install_path="${install_path%/}"

# Pre-compute total steps for [N/M] output
# Base: deps print, link, download, verify, cleanup = 5
TOTAL_STEPS=5
[ -z "$download_only" ] && TOTAL_STEPS=$((TOTAL_STEPS + 2))
[ -n "$archive_path" ] && TOTAL_STEPS=$((TOTAL_STEPS + 1))

step "Check dependencies"

step "Fetch current download link"
dl_path=$(get_dl_path)
if [ -z "$dl_path" ]; then
    echo "Error: could not determine the download link." >&2
    echo "Has the page structure of $URL changed?" >&2
    exit 1
fi
dl_link="$URL/$dl_path"
echo "    -> $dl_link"

# Clean any leftovers from previous runs (silent, not a numbered step)
reaper_remove

step "Download tarball to /tmp"
reaper_dl

step "Verify tarball integrity"
verify_tarball

if [ -z "$download_only" ]; then
    step "Extract tarball"
    reaper_unpack

    check_install_path_writable

    step "Install to $install_path/REAPER"
    reaper_install
fi

if [ -n "$archive_path" ]; then
    step "Move tarball to $archive_path"
    reaper_archive "$archive_path"
fi

step "Clean up /tmp"
reaper_remove

echo ""
if [ -z "$download_only" ]; then
    echo "Done. REAPER is installed at: $install_path/REAPER"
else
    echo "Done. Tarball is located at: $archive_path"
fi
