#!/bin/bash
###############################################################################
# NAME:            fleet-interlude.sh
# PURPOSE:         Fleet Interlude — a post-login tracker on newly enrolled
#                  Macs (swiftDialog via fleetd) that queues each software
#                  step through Fleet's device-authenticated API, using the
#                  host's rotating Fleet Desktop token.
#
# WHAT THIS DOES (high level)
#   - Resolves the Fleet server URL and reads /opt/orbit/identifier
#   - Builds the step list from STEPS (by title name or title ID) or, if
#     AUTO_DISCOVER=true, from every self-service title available to the host
#   - If fleetd did not unpack swiftDialog (typical after MDM
#     InstallEnterpriseApplication — orbit skips that TUF target unless
#     setup experience or MDM migration is running), downloads only
#     Fleet's swiftDialog TUF target into the same orbit path. Does not
#     reinstall fleetd.
#   - Opens the Fleet Interlude swiftDialog window, styled like Fleet's
#     native setup-experience page (Process / Status table).
#     BLUR_SCREEN=true kiosks with a blur; false (or --no-blur) is a
#     resizable, on-top window.
#     COLOR_MODE=light|dark|auto (or --color-mode / --dark / --light / --auto).
#   - POSTs /api/latest/fleet/device/{token}/software/install/{title_id}
#     for each title that is not already installed. SERIAL_STEPS=true POSTs
#     one title at a time, in STEPS order, so a later title can depend on an
#     earlier install. SERIAL_ON_FAIL=stop|skip controls a failed step.
#   - Polls GET /api/latest/fleet/device/{token}/software and the local
#     filesystem until each step is installed or failed, updating the window
#   - At start, skip-queue for macOS apps only when a live .app Info.plist
#     CFBundleIdentifier matches a bundle ID Fleet returned for that title.
#     Script packages follow Fleet install-result UUIDs (no  .app to find).
#
# WHAT THIS SCRIPT DOES *NOT* DO
#   - Does NOT replace Fleet's ADE Setup Assistant / native setup-experience
#     page. That UI is owned by fleetd. Fleet Interlude is a post-login tracker.
#   - Does NOT install software that is not self-service. The device install
#     API rejects titles with self_service=false.
#   - Does NOT raise privileges; fleetd already runs scripts as root.
#
# WHERE THIS RUNS
#   Fleet Interlude is a Fleet script, uploaded under Controls > Scripts.
#   Run it manually or from a policy automation.
#   fleetd executes the script as root. swiftDialog is launched into the
#   console user's GUI session.
#
#   Fleet runs shell scripts under /bin/sh unless a shebang is present. The
#   #!/bin/bash line above is load-bearing: this script uses arrays and
#   [[ ]] and will fail under sh. macOS bash is 3.2 — no associative arrays,
#   no mapfile.
#
# SOFTWARE TITLE IDS
#   Title IDs are per Fleet server. Prefer names in STEPS; they are resolved
#   at runtime from GET .../device/{token}/software?available_for_install=true.
#   Pin a numeric ID when two titles share a name.
#
# TIMING
#   Installing a handful of titles routinely exceeds Fleet's default
#   script_execution_timeout (300s). Live runs detach into a one-shot
#   LaunchDaemon (DETACH=true) so Fleet can record success while Fleet
#   Interlude keeps working. Raise agent_options.script_execution_timeout
#   if you set DETACH=false. SERIAL_STEPS=true waits for each title before
#   queueing the next; raise MAX_WAIT_SECONDS for long chains.
#
# LOGGING
#   In-process: stdout/stderr (Fleet Host details > Activity).
#   Detached worker: /var/log/fleet-interlude.log
#
# EXIT CODES
#   0 - success, including "already completed" and dry-run
#   1 - misconfiguration, not root, missing token/URL/Dialog, or no steps
#   2 - REQUIRE_CONSOLE_USER=true and no console user logged in
###############################################################################

set -euo pipefail

###############################################################################
# CONFIGURATION
#
# Fleet passes no arguments to scripts, so these are edited here before the
# script is uploaded. DRY_RUN must be "false" for the script to queue real
# installs. Leave it at "true" for canary and manual validation runs.
###############################################################################
DRY_RUN="false"

# When live, hand off to a one-shot LaunchDaemon so Fleet's script timeout
# cannot kill Fleet Interlude mid-install. Dry-runs always stay in-process.
DETACH="true"

# Re-run even if /var/db/fleet-interlude.done exists.
# Also accepted as --force on the command line.
FORCE="true"

# TEMPORARY: emit sanitized script-install diagnostics: Fleet status, install
# UUIDs, and result endpoint status. Set false after troubleshooting. Also
# accepted as --debug on the command line.
DEBUG_LOGGING="false"

# Abort instead of queueing silently when nobody is logged in.
REQUIRE_CONSOLE_USER="false"

# true: full-screen blur, window cannot be moved or resized (Fleet Interlude kiosk).
# false: no blur, --resizable (implies moveable), still --ontop.
# Override at run time with --no-blur (Fleet's script runner does not pass flags).
BLUR_SCREEN="false"

# Window color mode: light, dark, or auto (follow the user's macOS Appearance).
# Override at run time with --light, --dark, or --auto.
COLOR_MODE="auto"

# Leave empty to read FleetURL from the fleetd managed preferences (or the
# orbit LaunchDaemon). Set only to override.
FLEET_URL=""

TOKEN_FILE="/opt/orbit/identifier"
DIALOG_DIR="/opt/orbit/bin/swiftDialog/macos/stable"
DIALOG_BIN="${DIALOG_DIR}/Dialog.app/Contents/MacOS/Dialog"
# Same artifact orbit would unpack from Fleet's update CDN. Only this
# target — not orbit, osqueryd, or Fleet Desktop.
SWIFT_DIALOG_TUF_URL="https://updates.fleetdm.com/targets/swiftDialog/macos/stable/swiftDialog.app.tar.gz"

# If STEPS is empty and AUTO_DISCOVER=true, queue every self-service title
# available to this host. AUTO_DISCOVER is ignored when STEPS is non-empty.
AUTO_DISCOVER="false"

# Each entry is a software title name (resolved on the host) or a numeric
# title ID. Names must match Fleet software titles on this server (see Self-service).
# With SERIAL_STEPS=true this list is the dependency chain: step N+1 is not
# queued until step N succeeds (or is skipped, see SERIAL_ON_FAIL).
STEPS=(
    "Google Chrome"
    "Fleet Desktop"
    "some_pig.sh"
)

# false: POST every unfinished title up front (Fleet / orbit may run them
# concurrently). true: POST one title at a time in STEPS order so a later
# title's install label/query can see the earlier install. Also --serial /
# --parallel on manual runs. AUTO_DISCOVER still walks the catalog in the
# order returned; that is not a dependency graph.
SERIAL_STEPS="true"

# When SERIAL_STEPS=true and a step fails (install or queue):
#   stop - do not queue remaining steps; they stay Pending and the run ends
#   skip - leave the failed step Failed and queue the next
# Ignored when SERIAL_STEPS=false. Also --serial-on-fail stop|skip.
SERIAL_ON_FAIL="stop"

# Fallback for script-only titles when an older Fleet device-software response
# omits both the package filename and source="scripts".
SCRIPT_ONLY_TITLES=(
    "some_pig.sh"
)

POLL_INTERVAL_SECONDS=8
MAX_WAIT_SECONDS=3600
WAIT_FOR_CONSOLE_SECONDS=120
# Manual MDM enroll does not unpack swiftDialog. Do not sit here hoping
# orbit will; TUF install starts immediately so the window can open.
WAIT_FOR_DIALOG_SECONDS=0
COMPLETE_HOLD_SECONDS=20

# Window copy — Fleet native "Setting up your device" screen.
WINDOW_TITLE="Setting up your device..."
WINDOW_MESSAGE="Your computer is currently being configured by your organization. Please don't attempt to restart or shut down the computer unless prompted to do so."
WINDOW_TITLE_DONE="Configuration complete"
WINDOW_MESSAGE_DONE="Your computer has been successfully configured. Setup will continue momentarily."
WINDOW_TITLE_FAILED="Device setup failed"
WINDOW_MESSAGE_FAILED="Your organization requires that critical software be installed before you use your device. Please reach out to your IT admin for help."

# Header mark shown above the Fleet Interlude tracker. Change this HTTPS URL to use your
# organization's logo, or set it empty to omit the mark.
HEADER_LOGO_URL="${HEADER_LOGO_URL-https://fleetdm.com/images/permanent/fleet-mark-color-40x40@4x.png}"

DONE_MARK="/var/db/fleet-interlude.done"
STATE_DIR="/var/db/fleet-interlude"
WORKER_LABEL="com.fleet.interlude"
WORKER_PLIST="/Library/LaunchDaemons/${WORKER_LABEL}.plist"
WORKER_LOG="/var/log/fleet-interlude.log"
WORKER_SCRIPT="${STATE_DIR}/fleet-interlude.sh"

###############################################################################
# LOGGING
###############################################################################
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] $*"
}

trap 'log ERROR "Unexpected failure at line ${LINENO} (last command: ${BASH_COMMAND})"' ERR

###############################################################################
# HELPERS
###############################################################################
is_true() {
    [[ "${1:-}" == "true" ]]
}

html_escape() {
    # bash 3.2: no ${var//} multiple reliably with newlines; names are single-line.
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

read_token() {
    if [[ ! -f "$TOKEN_FILE" ]]; then
        log ERROR "Token file not found at ${TOKEN_FILE}"
        return 1
    fi
    /usr/bin/tr -d '[:space:]' < "$TOKEN_FILE"
}

install_swift_dialog_from_tuf() {
    local tmpdir="" archive="" extracted=""
    tmpdir=$(/usr/bin/mktemp -d /private/var/tmp/fleet-interlude-dialog.XXXXXX) || return 1
    archive="${tmpdir}/swiftDialog.app.tar.gz"

    log INFO "Downloading swiftDialog TUF target from ${SWIFT_DIALOG_TUF_URL}"
    if ! /usr/bin/curl --fail --location --silent --show-error \
        --retry 3 --retry-delay 2 --max-time 120 \
        --output "$archive" "$SWIFT_DIALOG_TUF_URL"; then
        log ERROR "Failed to download swiftDialog from Fleet TUF"
        /bin/rm -rf "$tmpdir"
        return 1
    fi

    if ! /usr/bin/tar -xzf "$archive" -C "$tmpdir"; then
        log ERROR "Failed to extract swiftDialog TUF archive"
        /bin/rm -rf "$tmpdir"
        return 1
    fi

    if [[ -d "${tmpdir}/Dialog.app" ]]; then
        extracted="${tmpdir}/Dialog.app"
    else
        extracted=$(/usr/bin/find "$tmpdir" -name 'Dialog.app' -type d | /usr/bin/head -n 1)
    fi
    if [[ -z "$extracted" || ! -d "$extracted" ]]; then
        log ERROR "TUF archive did not contain Dialog.app"
        /bin/rm -rf "$tmpdir"
        return 1
    fi

    /bin/mkdir -p "$DIALOG_DIR"
    if [[ -e "${DIALOG_DIR}/Dialog.app" ]]; then
        /bin/rm -rf "${DIALOG_DIR}/Dialog.app"
    fi
    if ! /usr/bin/ditto "$extracted" "${DIALOG_DIR}/Dialog.app"; then
        log ERROR "Failed to install Dialog.app into ${DIALOG_DIR}"
        /bin/rm -rf "$tmpdir"
        return 1
    fi
    /usr/bin/xattr -dr com.apple.quarantine "${DIALOG_DIR}/Dialog.app" 2>/dev/null || true
    /bin/chmod -R a+rX "${DIALOG_DIR}/Dialog.app"
    if [[ -f "$DIALOG_BIN" ]]; then
        /bin/chmod a+x "$DIALOG_BIN"
    fi
    /bin/rm -rf "$tmpdir"

    if [[ ! -x "$DIALOG_BIN" ]]; then
        log ERROR "swiftDialog extracted but not executable at ${DIALOG_BIN}"
        return 1
    fi
    log INFO "Installed fleetd swiftDialog from TUF at ${DIALOG_BIN}"
    return 0
}

ensure_dialog() {
    local elapsed=0
    if [[ -x "$DIALOG_BIN" ]]; then
        return 0
    fi
    if [[ $WAIT_FOR_DIALOG_SECONDS -gt 0 ]]; then
        log INFO "Waiting up to ${WAIT_FOR_DIALOG_SECONDS}s for fleetd swiftDialog at ${DIALOG_BIN}"
        while [[ $elapsed -lt $WAIT_FOR_DIALOG_SECONDS ]]; do
            sleep 5
            elapsed=$((elapsed + 5))
            if [[ -x "$DIALOG_BIN" ]]; then
                log INFO "fleetd swiftDialog ready after ${elapsed}s"
                return 0
            fi
        done
    fi
    log INFO "fleetd did not unpack swiftDialog; installing from Fleet TUF"
    install_swift_dialog_from_tuf
}

discover_fleet_url() {
    local url=""
    if [[ -n "$FLEET_URL" ]]; then
        printf '%s' "${FLEET_URL%/}"
        return 0
    fi
    url=$(/usr/bin/defaults read "/Library/Managed Preferences/com.fleetdm.fleetd.config" FleetURL 2>/dev/null || true)
    if [[ -z "$url" && -f /Library/LaunchDaemons/com.fleetdm.orbit.plist ]]; then
        url=$(/usr/bin/plutil -extract EnvironmentVariables.ORBIT_FLEET_URL raw /Library/LaunchDaemons/com.fleetdm.orbit.plist 2>/dev/null || true)
    fi
    if [[ -z "$url" ]]; then
        log ERROR "Could not discover Fleet URL. Set FLEET_URL or install the fleetd config profile."
        return 1
    fi
    printf '%s' "${url%/}"
}

console_user() {
    /usr/bin/stat -f%Su /dev/console 2>/dev/null || true
}

is_human_console_user() {
    local user="$1"
    [[ -n "$user" && "$user" != "root" && "$user" != "loginwindow" && "$user" != "_mbsetupuser" ]]
}

# Effective light/dark for a macOS user. Root does not inherit the console
# user's appearance, so read that user's defaults (not our own).
console_user_appearance() {
    local target="${1:-}"
    local home="" style=""
    if [[ -z "$target" ]] || ! is_human_console_user "$target"; then
        echo light
        return 0
    fi
    home=$(/usr/bin/dscl . -read "/Users/${target}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}' || true)
    if [[ -n "$home" ]]; then
        style=$(/usr/bin/defaults read "${home}/Library/Preferences/.GlobalPreferences" AppleInterfaceStyle 2>/dev/null || true)
    fi
    if [[ -z "$style" ]]; then
        style=$(/usr/bin/sudo -u "$target" /usr/bin/defaults read -g AppleInterfaceStyle 2>/dev/null || true)
    fi
    case "$(printf '%s' "$style" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
        dark) echo dark ;;
        *) echo light ;;
    esac
}

# Sets RESOLVED_APPEARANCE to light or dark from COLOR_MODE.
resolve_color_mode() {
    local mode
    mode=$(printf '%s' "${COLOR_MODE:-auto}" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d '[:space:]')
    case "$mode" in
        dark|true|yes|1)
            RESOLVED_APPEARANCE="dark"
            ;;
        light|false|no|0)
            RESOLVED_APPEARANCE="light"
            ;;
        auto|"")
            RESOLVED_APPEARANCE=$(console_user_appearance "${CONSOLE_USER:-${user:-}}")
            ;;
        *)
            log WARN "Unknown COLOR_MODE='${COLOR_MODE}'; falling back to auto"
            RESOLVED_APPEARANCE=$(console_user_appearance "${CONSOLE_USER:-${user:-}}")
            ;;
    esac
}

json_software_tsv() {
    # Reads JSON_PATH, prints:
    # ASCII unit-separator-delimited fields, preserving empty values:
    # id<US>name<US>self_service<US>status<US>icon_url<US>bundle_ids<US>package_name<US>source<US>last_install_uuid<US>installed_paths
    # Bundle IDs and paths are whatever Fleet returned for this title — never
    # a local name table.
    # Perl JSON::PP is stock macOS and works from a LaunchDaemon. osascript JXA
    # deadlocks there (no Aqua session), which is why the worker log stopped
    # after "Device token file" with no dialog.
    /usr/bin/perl -e '
use strict;
use warnings;
use JSON::PP;
my $path = $ENV{JSON_PATH};
open my $fh, "<:raw", $path or die "$path: $!\n";
local $/;
my $data = JSON::PP->new->decode(<$fh>);
for my $s (@{$data->{software} || []}) {
    my $pkg = $s->{software_package} || {};
    my $vpp = $s->{app_store_app} || {};
    my $ss = exists $pkg->{self_service} ? $pkg->{self_service} : $vpp->{self_service};
    my $icon = defined $s->{icon_url} ? $s->{icon_url} : "";
    my $name = (defined $s->{display_name} && $s->{display_name} ne "")
        ? $s->{display_name} : (defined $s->{name} ? $s->{name} : "");
    my $status = defined $s->{status} ? $s->{status} : "";
    my $pkgname = defined $pkg->{name} ? $pkg->{name} : "";
    my $source = defined $s->{source} ? $s->{source} : "";
    my @bundles;
    my %seen;
    my $add = sub {
        my $b = shift;
        return unless defined $b && $b ne "";
        $b =~ s/[\t\x1f]/ /g;
        return if $seen{$b}++;
        push @bundles, $b;
    };
    $add->($s->{bundle_identifier});
    $add->($pkg->{bundle_identifier});
    $add->($vpp->{bundle_identifier});
    my @paths;
    my %pseen;
    if (ref($s->{installed_versions} || "") eq "ARRAY") {
        for my $iv (@{$s->{installed_versions}}) {
            $add->($iv->{bundle_identifier});
            if (ref($iv->{installed_paths} || "") eq "ARRAY") {
                for my $p (@{$iv->{installed_paths}}) {
                    next unless defined $p && $p ne "";
                    $p =~ s/[\t\x1f]/ /g;
                    $p =~ s/\|/ /g;
                    next if $pseen{$p}++;
                    push @paths, $p;
                }
            }
        }
    }
    # Newer Fleet versions place this under the installer type. Accept the
    # top-level form too so a tracker can finish against older Fleet servers.
    my $last = $pkg->{last_install} || $vpp->{last_install} || $s->{last_install} || {};
    $last = {} unless ref $last eq "HASH";
    # Script completion requires an install UUID. Do not use a VPP command
    # UUID or timestamp here: neither identifies a custom-package result.
    my $lastkey = $last->{install_uuid} || "";
    $name =~ s/[\t\x1f]/ /g;
    $icon =~ s/[\t\x1f]/ /g;
    $pkgname =~ s/[\t\x1f]/ /g;
    $source =~ s/[\t\x1f]/ /g;
    $lastkey =~ s/[\t\x1f]/ /g;
    printf "%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n",
        (defined $s->{id} ? $s->{id} : ""),
        $name, ($ss ? 1 : 0), $status, $icon,
        join(" ", @bundles), $pkgname, $source, $lastkey, join("|", @paths);
}
'
}

curl_opts() {
    CURL_OPTS=(-sS -g --max-time 30)
    if [[ -f /opt/orbit/fleet.pem ]]; then
        CURL_OPTS+=(--cacert /opt/orbit/fleet.pem)
    fi
}

fleet_request() {
    # fleet_request METHOD PATH [body_file]
    # Prints HTTP code. Response body always lands in $FLEET_BODY.
    local method="$1"
    local path="$2"
    local attempt token http
    curl_opts
    : > "$FLEET_BODY"
    for attempt in 1 2; do
        token=$(read_token) || return 1
        if is_true "$DEBUG_LOGGING"; then
            # fleet_request is normally called in command substitution. Keep
            # diagnostics on stderr so stdout remains the HTTP code only.
            log DEBUG "Fleet request: ${method} ${path} (attempt ${attempt})" >&2
        fi
        http=$(/usr/bin/curl "${CURL_OPTS[@]}" \
            -o "$FLEET_BODY" -w "%{http_code}" \
            -X "$method" \
            -H "Content-Type: application/json" \
            "${FLEET_URL}/api/latest/fleet/device/${token}${path}" || true)
        if is_true "$DEBUG_LOGGING"; then
            log DEBUG "Fleet response: ${method} ${path} -> HTTP ${http:-000}" >&2
        fi
        if [[ "$http" == "401" || "$http" == "403" ]]; then
            log WARN "Device token rejected (${http}); re-reading ${TOKEN_FILE} (attempt ${attempt})" >&2
            sleep 1
            continue
        fi
        printf '%s' "$http"
        return 0
    done
    printf '%s' "${http:-000}"
}

page_has_more() {
    JSON_PATH="$1" /usr/bin/perl -e '
use strict;
use warnings;
use JSON::PP;
my $path = $ENV{JSON_PATH};
open my $fh, "<:raw", $path or die "$path: $!\n";
local $/;
my $data = JSON::PP->new->decode(<$fh>);
print (($data->{meta} && $data->{meta}{has_next_results}) ? "yes" : "no");
'
}

json_install_result_status() {
    JSON_PATH="$1" /usr/bin/perl -e '
use strict;
use warnings;
use JSON::PP;
my $path = $ENV{JSON_PATH};
open my $fh, "<:raw", $path or exit 1;
local $/;
my $data = eval { JSON::PP->new->decode(<$fh>) } || {};
# The Fleet device-authenticated endpoint wraps the install result in
# {"results": {...}}. Older variants returned the result directly.
my $result = ref($data->{results}) eq "HASH" ? $data->{results} : $data;
print defined $result->{status} ? $result->{status} : "";
'
}

SCRIPT_INSTALL_RESULT_HTTP=""
SCRIPT_INSTALL_RESULT_STATUS=""
SCRIPT_INSTALL_RESULT_STATE="wait"

script_install_result_state() {
    # A custom/script package reports a new last_install.install_uuid when
    # Fleet has recorded the attempt. This endpoint tells us whether that
    # particular attempt succeeded, failed, or has not finished yet.
    local install_uuid="$1" http result_status
    http=$(fleet_request GET "/software/install/${install_uuid}/results")
    SCRIPT_INSTALL_RESULT_HTTP="$http"
    SCRIPT_INSTALL_RESULT_STATUS=""
    SCRIPT_INSTALL_RESULT_STATE="wait"
    if [[ "$http" != "200" ]]; then
        return 0
    fi
    result_status=$(json_install_result_status "$FLEET_BODY" || true)
    SCRIPT_INSTALL_RESULT_STATUS="$result_status"
    case "$result_status" in
        installed|success) SCRIPT_INSTALL_RESULT_STATE="success" ;;
        failed|failed_install) SCRIPT_INSTALL_RESULT_STATE="fail" ;;
    esac
    return 0
}

fetch_available_software_tsv() {
    local page=0 http tmp more tsv
    tsv="${WORKDIR}/software.next.tsv"
    : > "$tsv"
    while :; do
        tmp="${WORKDIR}/software-page-${page}.json"
        http=$(fleet_request GET "/software?available_for_install=true&self_service=true&per_page=100&page=${page}&order_key=name&order_direction=asc")
        /bin/mv -f "$FLEET_BODY" "$tmp"
        if [[ "$http" != "200" ]]; then
            log ERROR "GET device software failed (HTTP ${http})"
            /usr/bin/head -c 500 "$tmp" >&2 || true
            return 1
        fi
        JSON_PATH="$tmp" json_software_tsv >> "$tsv"
        more=$(page_has_more "$tmp")
        if [[ "$more" != "yes" ]]; then
            break
        fi
        page=$((page + 1))
        if [[ $page -gt 20 ]]; then
            log WARN "Stopped paginating software after 20 pages"
            break
        fi
    done
    /bin/mv -f "$tsv" "$SOFTWARE_TSV"
}

lookup_title() {
    # Sets FOUND_ID FOUND_NAME FOUND_STATUS FOUND_ICON FOUND_SS FOUND_BUNDLE FOUND_PKG FOUND_SOURCE FOUND_LAST_INSTALL_KEY FOUND_PATHS
    local want="$1"
    FOUND_ID=""; FOUND_NAME=""; FOUND_STATUS=""; FOUND_ICON=""; FOUND_SS=""; FOUND_BUNDLE=""; FOUND_PKG=""; FOUND_SOURCE=""; FOUND_LAST_INSTALL_KEY=""; FOUND_PATHS=""
    local id name ss status icon bundle pkg source lastkey paths
    while IFS=$'\x1f' read -r id name ss status icon bundle pkg source lastkey paths; do
        [[ -z "${id:-}" ]] && continue
        if [[ "$want" == "$id" ]]; then
            FOUND_ID="$id"; FOUND_NAME="$name"; FOUND_STATUS="$status"
            FOUND_ICON="$icon"; FOUND_SS="$ss"
            FOUND_BUNDLE="${bundle:-}"; FOUND_PKG="${pkg:-}"; FOUND_SOURCE="${source:-}"; FOUND_LAST_INSTALL_KEY="${lastkey:-}"; FOUND_PATHS="${paths:-}"
            return 0
        fi
        if [[ "$(printf '%s' "$name" | /usr/bin/tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$want" | /usr/bin/tr '[:upper:]' '[:lower:]')" ]]; then
            FOUND_ID="$id"; FOUND_NAME="$name"; FOUND_STATUS="$status"
            FOUND_ICON="$icon"; FOUND_SS="$ss"
            FOUND_BUNDLE="${bundle:-}"; FOUND_PKG="${pkg:-}"; FOUND_SOURCE="${source:-}"; FOUND_LAST_INSTALL_KEY="${lastkey:-}"; FOUND_PATHS="${paths:-}"
            return 0
        fi
    done < "$SOFTWARE_TSV"
    return 1
}

# Live on-disk proof. Fleet status and installed_paths both lag a local
# delete, so they are not used as proof unless the plist still exists and
# the CFBundleIdentifier matches a bundle ID Fleet returned for this title.
# No per-app name/path table — that cannot ship to customers with different
# software catalogs.
#
# WKWebView cannot render .app / .icns as <img src>. Export a PNG, or use an
# https icon. Relative Fleet /api/.../icon URLs 404 when the title has no
# custom icon and show the broken-image glyph (the teal "?" in the tracker).
app_bundle_id() {
    local app="$1"
    [[ -f "$app/Contents/Info.plist" ]] || return 1
    /usr/bin/plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null || true
}

index_apps_dir() {
    local dir="$1" app bid
    [[ -d "$dir" ]] || return 0
    /usr/bin/find "$dir" -name '*.app' -prune -print0 2>/dev/null |
    while IFS= read -r -d '' app; do
        bid=$(app_bundle_id "$app") || true
        [[ -n "$bid" ]] || continue
        printf '%s\t%s\n' "$bid" "$app"
    done
}

index_installed_apps() {
    APPS_INDEX="${WORKDIR}/apps.tsv"
    {
        index_apps_dir /Applications
        if is_human_console_user "${CONSOLE_USER:-}"; then
            home_dir=$(/usr/bin/dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | /usr/bin/awk '{print $2}' || true)
            if [[ -n "$home_dir" ]]; then
                index_apps_dir "${home_dir}/Applications"
            fi
        fi
    } > "$APPS_INDEX"
}

# find_application BUNDLE_IDS [path|path|...]
# Prints the .app path if a live bundle matches one of the Fleet-supplied IDs.
find_application() {
    local bundles="${1:-}" paths="${2:-}" bid app want cand
    [[ -n "$bundles" ]] || return 1

    if [[ -n "$paths" ]]; then
        local oldifs="$IFS"
        IFS='|'
        set -- $paths
        IFS="$oldifs"
        for cand in "$@"; do
            [[ -d "$cand/Contents" ]] || continue
            bid=$(app_bundle_id "$cand") || true
            for want in $bundles; do
                if [[ "$bid" == "$want" ]]; then
                    printf '%s' "$cand"
                    return 0
                fi
            done
        done
    fi

    [[ -f "${APPS_INDEX:-}" ]] || return 1
    while IFS=$'\t' read -r bid app; do
        [[ -z "${bid:-}" || -z "${app:-}" ]] && continue
        [[ -d "$app/Contents" ]] || continue
        for want in $bundles; do
            if [[ "$bid" == "$want" ]]; then
                printf '%s' "$app"
                return 0
            fi
        done
    done < "$APPS_INDEX"
    return 1
}

export_app_icon_png() {
    local app="$1" dest="$2"
    local iconFile icns
    iconFile=$(/usr/bin/defaults read "$app/Contents/Info" CFBundleIconFile 2>/dev/null || true)
    iconFile="${iconFile%.icns}"
    icns=""
    if [[ -n "$iconFile" && -f "$app/Contents/Resources/${iconFile}.icns" ]]; then
        icns="$app/Contents/Resources/${iconFile}.icns"
    elif [[ -n "$iconFile" && -f "$app/Contents/Resources/${iconFile}" ]]; then
        icns="$app/Contents/Resources/${iconFile}"
    else
        icns=$(/usr/bin/find "$app/Contents/Resources" -maxdepth 1 -name '*.icns' 2>/dev/null | /usr/bin/head -1 || true)
    fi
    [[ -n "$icns" && -f "$icns" ]] || return 1
    /usr/bin/sips -s format png "$icns" --out "$dest" >/dev/null 2>&1 || return 1
    /bin/chmod 644 "$dest"
    return 0
}

download_http_icon() {
    local url="$1" dest="$2"
    local tmp http mime
    [[ -n "$url" ]] || return 1
    tmp="${dest}.dl"
    curl_opts
    http=$(/usr/bin/curl "${CURL_OPTS[@]}" --max-time 15 -L \
        -o "$tmp" -w "%{http_code}" \
        -H "Accept: image/*,*/*" \
        "$url" || true)
    if [[ "$http" != "200" || ! -s "$tmp" ]]; then
        /bin/rm -f "$tmp"
        return 1
    fi
    mime=$(/usr/bin/file -b --mime-type "$tmp" 2>/dev/null || true)
    case "$mime" in
        image/svg+xml)
            /bin/mv -f "$tmp" "${dest%.png}.svg"
            /bin/chmod 644 "${dest%.png}.svg"
            ICON_SAVED="${dest%.png}.svg"
            return 0
            ;;
        image/*)
            if /usr/bin/sips -s format png "$tmp" --out "$dest" >/dev/null 2>&1; then
                /bin/rm -f "$tmp"
            else
                /bin/mv -f "$tmp" "$dest"
            fi
            /bin/chmod 644 "$dest"
            ICON_SAVED="$dest"
            return 0
            ;;
    esac
    /bin/rm -f "$tmp"
    return 1
}

download_title_icon() {
    local id="$1" dest="$2"
    local token
    token=$(read_token) || return 1
    download_http_icon \
        "${FLEET_URL}/api/latest/fleet/device/${token}/software/titles/${id}/icon" \
        "$dest"
}

resolve_step_icon() {
    local id="$1" name="$2" api_icon="$3"
    local png="${ICON_DIR}/${id}.png" app abs_icon
    ICON_SAVED=""
    if app=$(find_application "${FOUND_BUNDLE:-}" "${FOUND_PATHS:-}") && export_app_icon_png "$app" "$png"; then
        printf 'file://%s' "$png"
        return 0
    fi
    abs_icon="$api_icon"
    if [[ "$abs_icon" == /* ]]; then
        abs_icon="${FLEET_URL}${abs_icon}"
    fi
    if [[ "$abs_icon" == https://* || "$abs_icon" == http://* ]]; then
        if download_http_icon "$abs_icon" "$png"; then
            printf 'file://%s' "$ICON_SAVED"
            return 0
        fi
    fi
    if download_title_icon "$id" "$png"; then
        printf 'file://%s' "$ICON_SAVED"
        return 0
    fi
    printf ''
}

is_script_package() {
    # Fleet software installer whose payload is a script, not an .app.
    case "$(printf '%s' "${1:-}" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
        *.sh|*.ps1|*.zsh|*.bash|*.py) return 0 ;;
        *) return 1 ;;
    esac
}

is_script_software() {
    # Script-only package names are not present in every device-software
    # response. Fleet identifies those entries with source="scripts"; a
    # configured title fallback supports older Fleet server responses.
    local pkg="${1:-}" source="${2:-}" name="${3:-}" configured
    if is_script_package "$pkg"; then
        return 0
    fi
    case "$(printf '%s' "$source" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
        script|scripts) return 0 ;;
    esac
    if [[ ${#SCRIPT_ONLY_TITLES[@]} -gt 0 ]]; then
        for configured in "${SCRIPT_ONLY_TITLES[@]}"; do
            if [[ "$(printf '%s' "$configured" | /usr/bin/tr '[:upper:]' '[:lower:]')" == \
                  "$(printf '%s' "$name" | /usr/bin/tr '[:upper:]' '[:lower:]')" ]]; then
                return 0
            fi
        done
    fi
    return 1
}

step_kind() {
    local i="$1"
    if is_script_software "${STEP_PACKAGES[$i]}" "${STEP_SOURCES[$i]}" "${STEP_NAMES[$i]}"; then
        printf 'script'
    else
        printf 'app'
    fi
}

step_process_label() {
    local i="$1"
    if is_script_software "${STEP_PACKAGES[$i]}" "${STEP_SOURCES[$i]}" "${STEP_NAMES[$i]}"; then
        printf 'Run %s' "${STEP_NAMES[$i]}"
    else
        printf 'Install %s' "${STEP_NAMES[$i]}"
    fi
}

status_label() {
    local st="$1" kind="${2:-app}"
    if [[ "$kind" == "script" ]]; then
        case "$st" in
            success) printf 'Ran' ;;
            wait) printf 'Running' ;;
            fail) printf 'Failed' ;;
            *) printf 'Pending' ;;
        esac
        return
    fi
    case "$st" in
        success) printf 'Installed' ;;
        wait) printf 'Installing' ;;
        fail) printf 'Failed' ;;
        *) printf 'Pending' ;;
    esac
}

status_rank() {
    # Map Fleet status to tracker state: pending|wait|success|fail
    case "${1:-}" in
        installed) echo success ;;
        pending_install|pending) echo wait ;;
        failed_install|failed) echo fail ;;
        *) echo pending ;;
    esac
}

# Skip queue only with on-disk bundle-ID proof when Fleet gave us IDs.
# Fleet "installed" after a local delete is pending so we re-queue.
# Script packages have no .app; they complete only after Fleet records a
# new install and reports its result.
initial_step_state() {
    local name="$1" fleet="$2" bundle="${3:-}" pkg="${4:-}" source="${5:-}" paths="${6:-}"
    if is_script_software "$pkg" "$source" "$name"; then
        echo pending
        return
    fi
    if [[ -n "$bundle" ]] && find_application "$bundle" "$paths" >/dev/null; then
        echo success
        return
    fi
    if [[ -n "$bundle" ]]; then
        case "$(status_rank "$fleet")" in
            fail) echo fail ;;
            wait) echo wait ;;
            *) echo pending ;;
        esac
        return
    fi
    case "$(status_rank "$fleet")" in
        fail) echo fail ;;
        wait) echo wait ;;
        success) echo success ;;
        *) echo pending ;;
    esac
}

###############################################################################
# HTML tracker — Fleet Interlude Process / Status table
###############################################################################
status_cell() {
    local st="$1" kind="${2:-app}" label
    label=$(status_label "$st" "$kind")
    case "$st" in
        success)
            printf '<span class="status-cell"><span class="glyph ok" aria-hidden="true"><svg viewBox="0 0 16 16" width="16" height="16"><circle cx="8" cy="8" r="8" fill="#3db67b"/><path d="M4.6 8.3l2.2 2.2 4.6-4.8" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg></span><span class="status-label">%s</span></span>' "$label"
            ;;
        wait)
            printf '<span class="status-cell"><span class="glyph spin-wrap" aria-hidden="true"><svg viewBox="0 0 16 16" width="16" height="16"><circle class="spin-track" cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="2"/><circle class="spin-arc" cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-dasharray="12 24"/></svg></span><span class="status-label">%s</span></span>' "$label"
            ;;
        fail)
            printf '<span class="status-cell"><span class="glyph bad" aria-hidden="true"><svg viewBox="0 0 16 16" width="16" height="16"><circle cx="8" cy="8" r="8" fill="#d66c7b"/><path d="M5.4 5.4l5.2 5.2M10.6 5.4l-5.2 5.2" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round"/></svg></span><span class="status-label">%s</span></span>' "$label"
            ;;
        *)
            printf '<span class="status-cell"><span class="glyph pending" aria-hidden="true"><svg viewBox="0 0 16 16" width="16" height="16"><circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.6"/></svg></span><span class="status-label">%s</span></span>' "$label"
            ;;
    esac
}

window_copy() {
    if { all_terminal || is_true "${SERIAL_STOPPED:-false}"; } && [[ "$(count_failed)" -gt 0 ]]; then
        CURRENT_TITLE="$WINDOW_TITLE_FAILED"
        CURRENT_MESSAGE="$WINDOW_MESSAGE_FAILED"
    elif all_terminal; then
        CURRENT_TITLE="$WINDOW_TITLE_DONE"
        CURRENT_MESSAGE="$WINDOW_MESSAGE_DONE"
    else
        CURRENT_TITLE="$WINDOW_TITLE"
        CURRENT_MESSAGE="$WINDOW_MESSAGE"
    fi
}

json_icon_src() {
    # Relative to view.html so icons work for both http://127.0.0.1/.../view.html
    # and file:///.../view.html. A leading /icons/... only works on the HTTP
    # server; file:// treats it as the disk root and the <img> is a blank square.
    local icon="${1:-}" path base
    if [[ "$icon" == file://* ]]; then
        path="${icon#file://}"
        base=$(/usr/bin/basename "$path")
        if [[ -n "$base" && -f "${ICON_DIR}/${base}" ]]; then
            printf 'icons/%s' "$base"
            return 0
        fi
        if [[ -n "$base" && -f "$path" ]]; then
            /bin/cp "$path" "${ICON_DIR}/${base}" 2>/dev/null || true
            /bin/chmod 644 "${ICON_DIR}/${base}" 2>/dev/null || true
            if [[ -f "${ICON_DIR}/${base}" ]]; then
                printf 'icons/%s' "$base"
                return 0
            fi
        fi
        printf ''
        return 0
    fi
    printf '%s' "$icon"
}

write_state_json() {
    local i tsv="${WORKDIR}/state.tsv" next="${WORKDIR}/state.next.json"
    window_copy
    : > "$tsv"
    i=0
    while [[ $i -lt ${#STEP_IDS[@]} ]]; do
        printf '%s\t%s\t%s\t%s\n' "${STEP_NAMES[$i]}" "${STEP_STATE[$i]}" "$(json_icon_src "${STEP_ICONS[$i]}")" "$(step_kind "$i")" >> "$tsv"
        i=$((i + 1))
    done
    TITLE="$CURRENT_TITLE" MSG="$CURRENT_MESSAGE" TSV="$tsv" OUT="$next" /usr/bin/perl -e '
use strict;
use warnings;
use JSON::PP;
my @steps;
open my $fh, "<:utf8", $ENV{TSV} or die $ENV{TSV};
while (<$fh>) {
    chomp;
    my ($name, $state, $icon, $kind) = split /\t/, $_, 4;
    $icon = "" unless defined $icon;
    $kind = "app" unless defined $kind && $kind ne "";
    push @steps, { name => $name, state => $state, icon => $icon, kind => $kind };
}
close $fh;
open my $out, ">:utf8", $ENV{OUT} or die $ENV{OUT};
print $out JSON::PP->new->encode({
    title => (defined $ENV{TITLE} ? $ENV{TITLE} : ""),
    message => (defined $ENV{MSG} ? $ENV{MSG} : ""),
    steps => \@steps,
});
'
    /bin/mv -f "$next" "${WORKDIR}/state.json"
    /bin/chmod 644 "${WORKDIR}/state.json"
}

write_html() {
    local i name icon st icon_tag kind
    local html="${1:-${WORKDIR}/view.html}"
    window_copy
    write_state_json
    {
        printf '%s\n' '<!DOCTYPE html>'
        printf '<html lang="en" class="theme-%s">\n' "$RESOLVED_APPEARANCE"
        cat <<'HDR'
<head>
<meta charset="utf-8">
<meta http-equiv="Cache-Control" content="no-cache">
<title>Setting up your device...</title>
<style>
  :root, html.theme-light {
    --content-inset: 40px; --page-header-top-inset: 24px;
    --bg: #ffffff; --text: #192147; --muted: #515774; --header: #8b8fa2;
    --border: #e2e4ea; --icon-bg: #f9fafc; --pending: #c5c7d1; --ok: #3db67b;
    --surface-outline: #e2e4ea; --surface-shadow: 0 1px 2px rgba(25, 33, 71, 0.06);
    color-scheme: light;
  }
  html.theme-dark {
    --bg: #1a1c21; --text: #e2e4ea; --muted: #c5c7d1; --header: #8b8fa2;
    --border: #3d4048; --icon-bg: #25272d; --pending: #515774; --ok: #3db67b;
    --surface-outline: #3d4048; --surface-shadow: 0 1px 2px rgba(0, 0, 0, 0.4);
    color-scheme: dark;
  }
  *, *::before, *::after { box-sizing: border-box; }
  html, body { min-height: 100%; margin: 0; padding: 0; background: var(--bg); color: var(--text);
    font-family: Inter, -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
  body { position: relative; min-width: 0; padding: var(--page-header-top-inset) 0 var(--content-inset); }
  .page-header { height: 28px; margin: 0 0 16px; padding: 0 var(--content-inset);
    display: flex; align-items: center; border-bottom: 1px solid var(--border); }
  .page-corner-logo { position: absolute; top: 12px; left: 12px; z-index: 1; display: block;
    width: 18px; height: 18px; object-fit: contain; }
  .card { width: calc(100% - 80px); margin: 0 auto; padding: 20px; background: var(--bg);
    border: 1px solid var(--surface-outline); border-radius: 8px; box-shadow: var(--surface-shadow); }
  h1 { font-size: 18px; font-weight: 700; line-height: 1.3; margin: 0 0 8px; color: var(--text); }
  .lede { font-size: 14px; line-height: 1.5; color: var(--muted); margin: 0 0 24px; max-width: 640px; }
  table { width: 100%; border: 1px solid var(--surface-outline); border-spacing: 0;
    border-collapse: separate; border-radius: 6px; box-shadow: var(--surface-shadow); overflow: hidden; }
  th { text-align: left; font-size: 12px; font-weight: 600; color: var(--header);
    padding: 10px 8px; border-bottom: 1px solid var(--border); }
  th.status-col { width: 160px; }
  td { font-size: 14px; color: var(--text); padding: 12px 8px; border-bottom: 1px solid var(--border);
    vertical-align: middle; }
  tr:last-child td { border-bottom: 1px solid var(--border); }
  .process { display: flex; align-items: center; gap: 10px; }
  .icon { width: 24px; height: 24px; border-radius: 4px; object-fit: contain; background: var(--icon-bg); flex-shrink: 0; }
  .icon.placeholder { display: flex; align-items: center; justify-content: center;
    font-size: 11px; font-weight: 600; color: var(--header); }
  .process-name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .status-cell { display: flex; align-items: center; gap: 8px; font-size: 14px; color: var(--muted); }
  .status-label { min-width: 7.5em; }
  .glyph { width: 16px; height: 16px; display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0; }
  .glyph.pending { color: var(--pending); }
  .spin-wrap .spin-track { stroke: var(--border); }
  .spin-wrap .spin-arc { stroke: var(--ok); }
  .spin-wrap svg {
    display: block;
    animation: interlude-spin 0.8s linear infinite;
    -webkit-animation: interlude-spin 0.8s linear infinite;
  }
  @keyframes interlude-spin { to { transform: rotate(360deg); } }
  @-webkit-keyframes interlude-spin { to { -webkit-transform: rotate(360deg); } }
</style>
</head>
<body>
HDR
        if [[ -n "$HEADER_LOGO_URL" ]]; then
            printf '<img class="page-corner-logo" src="%s" alt="Fleet Interlude">\n' "$(html_escape "$HEADER_LOGO_URL")"
        fi
        cat <<'HEADER'
<header class="page-header"></header>
<div class="card">
  <h1 id="title">
HEADER
        html_escape "$CURRENT_TITLE"
        cat <<'MID'
  </h1>
  <p class="lede" id="lede">
MID
        html_escape "$CURRENT_MESSAGE"
        cat <<'MID2'
  </p>
  <table>
    <thead>
      <tr><th>Process</th><th class="status-col">Status</th></tr>
    </thead>
    <tbody>
MID2
        i=0
        while [[ $i -lt ${#STEP_IDS[@]} ]]; do
            name=$(html_escape "$(step_process_label "$i")")
            st="${STEP_STATE[$i]}"
            kind=$(step_kind "$i")
            icon="$(json_icon_src "${STEP_ICONS[$i]}")"
            if [[ -n "$icon" ]]; then
                icon_tag="<img class=\"icon\" src=\"$(html_escape "$icon")\" alt=\"\">"
            else
                icon_tag="<div class=\"icon placeholder\">$(html_escape "$(printf '%s' "${STEP_NAMES[$i]}" | /usr/bin/cut -c1)")</div>"
            fi
            printf '<tr data-state="%s" data-kind="%s" data-icon="%s"><td><div class="process"><span id="icon-%s">%s</span><span class="process-name">%s</span></div></td><td id="status-%s">%s</td></tr>\n' \
                "$(html_escape "$st")" "$(html_escape "$kind")" "$(html_escape "$icon")" "$i" "$icon_tag" "$name" "$i" "$(status_cell "$st" "$kind")"
            i=$((i + 1))
        done
        cat <<'FTR'
    </tbody>
  </table>
</div>
<script>
(function () {
  function statusHTML(st, kind) {
    var label;
    if (kind === "script") {
      if (st === "success") label = "Ran";
      else if (st === "wait") label = "Running";
      else if (st === "fail") label = "Failed";
      else label = "Pending";
    } else {
      if (st === "success") label = "Installed";
      else if (st === "wait") label = "Installing";
      else if (st === "fail") label = "Failed";
      else label = "Pending";
    }
    if (st === "success") {
      return '<span class="status-cell"><span class="glyph ok" aria-hidden="true"><svg viewBox="0 0 16 16" width="16" height="16"><circle cx="8" cy="8" r="8" fill="#3db67b"/><path d="M4.6 8.3l2.2 2.2 4.6-4.8" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg></span><span class="status-label">' + label + '</span></span>';
    }
    if (st === "wait") {
      return '<span class="status-cell"><span class="glyph spin-wrap" aria-hidden="true"><svg viewBox="0 0 16 16" width="16" height="16"><circle class="spin-track" cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="2"/><circle class="spin-arc" cx="8" cy="8" r="6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-dasharray="12 24"/></svg></span><span class="status-label">' + label + '</span></span>';
    }
    if (st === "fail") {
      return '<span class="status-cell"><span class="glyph bad" aria-hidden="true"><svg viewBox="0 0 16 16" width="16" height="16"><circle cx="8" cy="8" r="8" fill="#d66c7b"/><path d="M5.4 5.4l5.2 5.2M10.6 5.4l-5.2 5.2" fill="none" stroke="#fff" stroke-width="1.8" stroke-linecap="round"/></svg></span><span class="status-label">' + label + '</span></span>';
    }
    return '<span class="status-cell"><span class="glyph pending" aria-hidden="true"><svg viewBox="0 0 16 16" width="16" height="16"><circle cx="8" cy="8" r="6.2" fill="none" stroke="currentColor" stroke-width="1.6"/></svg></span><span class="status-label">' + label + '</span></span>';
  }
  function letter(name) {
    return (name || "?").charAt(0);
  }
  function apply(data) {
    if (!data || !data.steps) return;
    var title = document.getElementById("title");
    var lede = document.getElementById("lede");
    if (title && data.title) {
      title.textContent = data.title;
      document.title = data.title;
    }
    if (lede && data.message) lede.textContent = data.message;
    var i;
    for (i = 0; i < data.steps.length; i++) {
      var step = data.steps[i];
      var statusEl = document.getElementById("status-" + i);
      var iconEl = document.getElementById("icon-" + i);
      if (!statusEl || !iconEl) continue;
      var row = statusEl.parentNode;
      if (row.getAttribute("data-state") !== step.state) {
        statusEl.innerHTML = statusHTML(step.state, step.kind || row.getAttribute("data-kind") || "app");
        row.setAttribute("data-state", step.state);
      }
      var icon = step.icon || "";
      if (row.getAttribute("data-icon") !== icon) {
        if (icon) {
          iconEl.innerHTML = '<img class="icon" src="' + icon.replace(/"/g, "") + '" alt="">';
        } else {
          iconEl.innerHTML = '<div class="icon placeholder">' + letter(step.name) + "</div>";
        }
        row.setAttribute("data-icon", icon);
      }
    }
  }
  function tick() {
    var req = new XMLHttpRequest();
    req.open("GET", "state.json?t=" + Date.now(), true);
    req.onreadystatechange = function () {
      if (req.readyState === 4 && req.status === 200) {
        try { apply(JSON.parse(req.responseText)); } catch (e) {}
      }
    };
    req.send();
  }
  setInterval(tick, 1000);
  tick();
})();
</script>
</body>
</html>
FTR
    } > "$html"
    HTML_FILE="$html"
    /bin/chmod 644 "$html"
}

start_ui_server() {
    local n=0
    HTTP_PID=""
    HTTP_URL=""
    HTTP_PORT=""
    while [[ $n -lt 6 ]]; do
        HTTP_PORT=$((50000 + RANDOM % 5000))
        ROOT="$WORKDIR" PORT="$HTTP_PORT" /usr/bin/perl -MIO::Socket::INET -e '
use strict;
use warnings;

my $root = $ENV{ROOT};
my $port = $ENV{PORT};
$SIG{TERM} = sub { exit 0 };
$SIG{INT} = sub { exit 0 };

my $server = IO::Socket::INET->new(
    LocalAddr => "127.0.0.1",
    LocalPort => $port,
    Proto     => "tcp",
    Listen    => 5,
    ReuseAddr => 1,
) or die "bind 127.0.0.1:$port: $!\n";

sub reply {
    my ($client, $status, $type, $body) = @_;
    $body = "" unless defined $body;
    print {$client} "HTTP/1.1 $status\r\n";
    print {$client} "Content-Type: $type\r\n";
    print {$client} "Content-Length: " . length($body) . "\r\n";
    print {$client} "Cache-Control: no-store\r\nConnection: close\r\n\r\n";
    print {$client} $body;
}

while (my $client = $server->accept()) {
    $client->autoflush(1);
    my $request = <$client> // "";
    while (my $line = <$client>) {
        last if $line =~ /^\r?\n$/;
    }

    if ($request !~ m{\AGET\s+/([A-Za-z0-9._/-]*)(?:\?[^ ]*)?\s+HTTP/}) {
        reply($client, "405 Method Not Allowed", "text/plain", "Method not allowed\n");
        close $client;
        next;
    }

    my $path = $1;
    $path = "view.html" if $path eq "";
    if ($path !~ m{\A(?:view\.html|state\.json|icons/[A-Za-z0-9._-]+)\z}) {
        reply($client, "404 Not Found", "text/plain", "Not found\n");
        close $client;
        next;
    }

    my $file = "$root/$path";
    my $fh;
    if (!-f $file || !open($fh, "<:raw", $file)) {
        reply($client, "404 Not Found", "text/plain", "Not found\n");
        close $client;
        next;
    }

    my $body = do { local $/; <$fh> };
    close $fh;
    my $type = $path =~ /\.json\z/ ? "application/json" :
               $path =~ /\.svg\z/  ? "image/svg+xml" :
               $path =~ /\.png\z/  ? "image/png" :
               $path =~ /\.jpe?g\z/ ? "image/jpeg" : "text/html; charset=utf-8";
    reply($client, "200 OK", $type, $body);
    close $client;
}
' > "${WORKDIR}/ui-server.log" 2>&1 &
        HTTP_PID=$!
        retry=0
        while [[ $retry -lt 20 ]]; do
            if /bin/kill -0 "$HTTP_PID" 2>/dev/null && \
                /usr/bin/curl --noproxy '*' -sS -o /dev/null --max-time 1 \
                    "http://127.0.0.1:${HTTP_PORT}/view.html" 2>/dev/null; then
                HTTP_URL="http://127.0.0.1:${HTTP_PORT}"
                log INFO "UI server ${HTTP_URL} (pid ${HTTP_PID})"
                return 0
            fi
            sleep 0.1
            retry=$((retry + 1))
        done
        /bin/kill "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
        HTTP_PID=""
        n=$((n + 1))
    done
    log WARN "Could not start a local UI server: $(/usr/bin/tr '\n' ' ' < "${WORKDIR}/ui-server.log" | /usr/bin/cut -c1-300)"
    return 1
}

push_dialog() {
    [[ "$dialogsEnabled" == "true" ]] || return 0
    printf '%s\n' "$1" >> "$COMMAND_FILE"
}

stop_dialog() {
    if [[ -n "${DIALOG_PID:-}" ]] && /bin/kill -0 "$DIALOG_PID" 2>/dev/null; then
        /bin/kill "$DIALOG_PID" 2>/dev/null || true
        wait "$DIALOG_PID" 2>/dev/null || true
    fi
    DIALOG_PID=""
}

launch_dialog() {
    [[ "$dialogsEnabled" == "true" ]] || return 0
    : > "$COMMAND_FILE"
    /bin/chmod 644 "$COMMAND_FILE"
    HTML_FILE="${WORKDIR}/view.html"
    write_html "$HTML_FILE"
    if [[ -z "${HTTP_URL:-}" ]]; then
        start_ui_server || true
    fi
    local web="$HTML_FILE"
    if [[ -n "${HTTP_URL:-}" ]]; then
        web="${HTTP_URL}/view.html"
    else
        web="file://${HTML_FILE}"
    fi
    DIALOG_ARGS=(
        --title none
        --message none
        --hideicon
        --appearance "$RESOLVED_APPEARANCE"
        --webcontent "$web"
        --commandfile "$COMMAND_FILE"
        --button1text "Close"
        --button1disabled
        --ontop
        --quitkey "]"
        --width 920
        --height 780
        --position centre
    )
    # --title none removes Dialog's title view. WKWebView then eats clicks, so
    # a fake HTML title bar cannot move the window. A native banner sits above
    # the webview and isMovableByWindowBackground can drag it. Without the
    # banner the webview runs to the window's top edge and its header is clipped.
    if [[ "$RESOLVED_APPEARANCE" == "dark" ]]; then
        DIALOG_ARGS+=(--bannerimage "colour=#25272d")
    else
        DIALOG_ARGS+=(--bannerimage "colour=#f6f7fb")
    fi
    DIALOG_ARGS+=(--bannerheight 36)
    if is_true "$BLUR_SCREEN"; then
        DIALOG_ARGS+=(--blurscreen)
    else
        DIALOG_ARGS+=(--resizable --moveable)
    fi
    set +e
    if is_human_console_user "${CONSOLE_USER:-}"; then
        uid=$(/usr/bin/id -u "$CONSOLE_USER")
        /bin/launchctl asuser "$uid" /usr/bin/sudo -u "$CONSOLE_USER" "$DIALOG_BIN" "${DIALOG_ARGS[@]}" \
            >/dev/null 2>&1 &
    else
        "$DIALOG_BIN" "${DIALOG_ARGS[@]}" \
            >/dev/null 2>&1 &
    fi
    DIALOG_PID=$!
    set -e
    sleep 0.5
    if ! /bin/kill -0 "$DIALOG_PID" 2>/dev/null; then
        log WARN "swiftDialog exited immediately; continuing without UI"
        dialogsEnabled="false"
        DIALOG_PID=""
        return 1
    fi
    log INFO "swiftDialog pid ${DIALOG_PID}"
}

refresh_dialog() {
    [[ "$dialogsEnabled" == "true" ]] || return 0
    window_copy
    local fp
    fp="${CURRENT_TITLE}|${STEP_STATE[*]}|${STEP_ICONS[*]}"
    if [[ "$fp" == "${DIALOG_FINGERPRINT:-}" ]]; then
        return 0
    fi
    DIALOG_FINGERPRINT="$fp"
    write_state_json
}

count_done() {
    local i=0 n=0
    while [[ $i -lt ${#STEP_STATE[@]} ]]; do
        if [[ "${STEP_STATE[$i]}" == "success" || "${STEP_STATE[$i]}" == "fail" ]]; then
            n=$((n + 1))
        fi
        i=$((i + 1))
    done
    printf '%s' "$n"
}

count_failed() {
    local i=0 n=0
    while [[ $i -lt ${#STEP_STATE[@]} ]]; do
        if [[ "${STEP_STATE[$i]}" == "fail" ]]; then
            n=$((n + 1))
        fi
        i=$((i + 1))
    done
    printf '%s' "$n"
}

all_terminal() {
    local i=0
    while [[ $i -lt ${#STEP_STATE[@]} ]]; do
        case "${STEP_STATE[$i]}" in
            success|fail) ;;
            *) return 1 ;;
        esac
        i=$((i + 1))
    done
    return 0
}

###############################################################################
# DETACH: one-shot LaunchDaemon so Fleet's 300s timeout cannot kill Fleet Interlude
###############################################################################
install_worker() {
    /bin/mkdir -p "$STATE_DIR"
    /bin/cp "$SCRIPT_PATH" "$WORKER_SCRIPT"
    /bin/chmod 755 "$WORKER_SCRIPT"
    local extra_args=""
    if ! is_true "$BLUR_SCREEN"; then
        extra_args="${extra_args}
        <string>--no-blur</string>"
    fi
    if is_true "$FORCE"; then
        extra_args="${extra_args}
        <string>--force</string>"
    fi
    if is_true "$DEBUG_LOGGING"; then
        extra_args="${extra_args}
        <string>--debug</string>"
    fi
    if is_true "$SERIAL_STEPS"; then
        extra_args="${extra_args}
        <string>--serial</string>"
    else
        extra_args="${extra_args}
        <string>--parallel</string>"
    fi
    extra_args="${extra_args}
        <string>--serial-on-fail</string>
        <string>${SERIAL_ON_FAIL}</string>"
    local mode
    mode=$(printf '%s' "${COLOR_MODE:-auto}" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d '[:space:]')
    case "$mode" in
        light|dark|auto|true|false|yes|no|1|0)
            extra_args="${extra_args}
        <string>--color-mode</string>
        <string>${mode}</string>"
            ;;
    esac
    cat > "$WORKER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${WORKER_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${WORKER_SCRIPT}</string>
        <string>--worker</string>${extra_args}
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>LaunchOnlyOnce</key>
    <true/>
    <key>AbandonProcessGroup</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${WORKER_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${WORKER_LOG}</string>
</dict>
</plist>
PLIST
    /bin/chmod 644 "$WORKER_PLIST"
    /bin/launchctl bootout system "$WORKER_PLIST" >/dev/null 2>&1 || true
    /bin/launchctl bootstrap system "$WORKER_PLIST"
    log INFO "Detached worker ${WORKER_LABEL}; further logs: ${WORKER_LOG}"
}

cleanup_worker() {
    /bin/launchctl bootout system "$WORKER_PLIST" >/dev/null 2>&1 || true
    /bin/rm -f "$WORKER_PLIST"
}

###############################################################################
# START
###############################################################################
SCRIPT_PATH="$0"
if [[ "$SCRIPT_PATH" != /* ]]; then
    SCRIPT_PATH="$(/bin/pwd)/$0"
fi

WORKER_MODE="false"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --worker) WORKER_MODE="true"; shift ;;
        --force) FORCE="true"; shift ;;
        --debug) DEBUG_LOGGING="true"; shift ;;
        --no-blur) BLUR_SCREEN="false"; shift ;;
        --serial) SERIAL_STEPS="true"; shift ;;
        --parallel) SERIAL_STEPS="false"; shift ;;
        --serial-on-fail)
            if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
                log ERROR "$1 requires a value: stop or skip"
                exit 1
            fi
            SERIAL_ON_FAIL="$2"
            shift 2
            ;;
        --serial-on-fail=*)
            SERIAL_ON_FAIL="${1#*=}"
            shift
            ;;
        --dark) COLOR_MODE="dark"; shift ;;
        --light) COLOR_MODE="light"; shift ;;
        --auto) COLOR_MODE="auto"; shift ;;
        --color-mode|--appearance)
            if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
                log ERROR "$1 requires a value: light, dark, or auto"
                exit 1
            fi
            COLOR_MODE="$2"
            shift 2
            ;;
        --color-mode=*|--appearance=*)
            COLOR_MODE="${1#*=}"
            shift
            ;;
        *)
            log WARN "Unknown argument: $1"
            shift
            ;;
    esac
done

SERIAL_ON_FAIL=$(printf '%s' "${SERIAL_ON_FAIL:-stop}" | /usr/bin/tr '[:upper:]' '[:lower:]' | /usr/bin/tr -d '[:space:]')
case "$SERIAL_ON_FAIL" in
    stop|skip) ;;
    *)
        log ERROR "SERIAL_ON_FAIL must be stop or skip (got '${SERIAL_ON_FAIL}')"
        exit 1
        ;;
esac
SERIAL_STOPPED="false"

log INFO "Starting fleet-interlude.sh (worker=${WORKER_MODE} dry_run=${DRY_RUN} blur=${BLUR_SCREEN} color_mode=${COLOR_MODE} serial=${SERIAL_STEPS} serial_on_fail=${SERIAL_ON_FAIL} debug=${DEBUG_LOGGING})"

if [[ $EUID -ne 0 ]]; then
    log ERROR "This script must run as root (fleetd)."
    exit 1
fi

if [[ -f "$DONE_MARK" ]] && ! is_true "$FORCE" && ! is_true "$DRY_RUN"; then
    log INFO "Already completed (${DONE_MARK}); exiting. Set FORCE=true to re-run."
    exit 0
fi

# Detach live runs that are still inside Fleet's script execution.
if ! is_true "$DRY_RUN" && is_true "$DETACH" && [[ "$WORKER_MODE" != "true" ]]; then
    install_worker
    exit 0
fi

if ! ensure_dialog; then
    log ERROR "swiftDialog is not at ${DIALOG_BIN} and TUF install failed"
    exit 1
fi

FLEET_URL=$(discover_fleet_url)
log INFO "Fleet URL: ${FLEET_URL}"
read_token >/dev/null
log INFO "Device token file: ${TOKEN_FILE}"

WORKDIR=$(/usr/bin/mktemp -d /private/var/tmp/fleet-interlude.XXXXXX)
chmod 755 "$WORKDIR"
ICON_DIR="${WORKDIR}/icons"
/bin/mkdir -p "$ICON_DIR"
/bin/chmod 755 "$ICON_DIR"
COMMAND_FILE="${WORKDIR}/dialog.commands"
FLEET_BODY="${WORKDIR}/fleet-body.json"
SOFTWARE_TSV="${WORKDIR}/software.tsv"
: > "$COMMAND_FILE"
/bin/chmod 644 "$COMMAND_FILE"
HTML_FILE="${WORKDIR}/view.html"
DIALOG_HTML_GEN=0
DIALOG_PID=""
HTTP_PID=""
HTTP_URL=""
CONSOLE_USER=""
RESOLVED_APPEARANCE="light"
APPS_INDEX="${WORKDIR}/apps.tsv"

cleanup() {
    if [[ -n "${DIALOG_PID:-}" ]] && /bin/kill -0 "$DIALOG_PID" 2>/dev/null; then
        echo "quit:" >> "$COMMAND_FILE" 2>/dev/null || true
        sleep 0.3
        /bin/kill "$DIALOG_PID" 2>/dev/null || true
    fi
    if [[ -n "${HTTP_PID:-}" ]] && /bin/kill -0 "$HTTP_PID" 2>/dev/null; then
        /bin/kill "$HTTP_PID" 2>/dev/null || true
    fi
    if [[ "$WORKER_MODE" == "true" ]]; then
        cleanup_worker
    fi
    /bin/rm -rf "$WORKDIR"
}
trap cleanup EXIT

STEP_IDS=(); STEP_NAMES=(); STEP_ICONS=(); STEP_STATE=()
STEP_PACKAGES=(); STEP_SOURCES=(); STEP_BASELINE_INSTALL_KEYS=(); STEP_TRACKED_INSTALL_UUIDS=(); STEP_QUEUED=()

add_step() {
    local id="$1" name="$2" icon="$3" state="$4" package="$5" source="$6" last_install_key="$7"
    local i=0
    while [[ $i -lt ${#STEP_IDS[@]} ]]; do
        if [[ "${STEP_IDS[$i]}" == "$id" ]]; then
            return 0
        fi
        i=$((i + 1))
    done
    STEP_IDS+=("$id")
    STEP_NAMES+=("$name")
    STEP_ICONS+=("$icon")
    STEP_STATE+=("$state")
    STEP_PACKAGES+=("$package")
    STEP_SOURCES+=("$source")
    STEP_BASELINE_INSTALL_KEYS+=("$last_install_key")
    STEP_TRACKED_INSTALL_UUIDS+=("")
    STEP_QUEUED+=("false")
}

# Paint STEPS immediately so the window does not wait on Fleet's catalog.
seed_placeholder_steps() {
    local want
    if [[ ${#STEPS[@]} -eq 0 ]]; then
        return 0
    fi
    for want in "${STEPS[@]}"; do
        add_step "pending:${want}" "$want" "" "pending" "" "" ""
    done
}

fill_step_from_title() {
    local i="$1"
    STEP_IDS[$i]="$FOUND_ID"
    STEP_NAMES[$i]="$FOUND_NAME"
    STEP_PACKAGES[$i]="$FOUND_PKG"
    STEP_SOURCES[$i]="$FOUND_SOURCE"
    STEP_BASELINE_INSTALL_KEYS[$i]="$FOUND_LAST_INSTALL_KEY"
    STEP_ICONS[$i]=$(resolve_step_icon "$FOUND_ID" "$FOUND_NAME" "$FOUND_ICON")
    STEP_STATE[$i]="$(initial_step_state "$FOUND_NAME" "$FOUND_STATUS" "$FOUND_BUNDLE" "$FOUND_PKG" "$FOUND_SOURCE" "$FOUND_PATHS")"
}

###############################################################################
# Console user — then open the window before any Fleet API call.
###############################################################################
user=$(console_user)
elapsed=0
while ! is_human_console_user "$user" && [[ $elapsed -lt $WAIT_FOR_CONSOLE_SECONDS ]]; do
    log INFO "Waiting for console user (found: '${user:-none}')..."
    sleep 1
    elapsed=$((elapsed + 1))
    user=$(console_user)
done

dialogsEnabled="true"
if ! is_human_console_user "$user"; then
    if is_true "$REQUIRE_CONSOLE_USER"; then
        log ERROR "No console user logged in and REQUIRE_CONSOLE_USER=true; exiting."
        exit 2
    fi
    log WARN "No console user logged in (found: '${user:-none}') - queueing installs without a dialog."
    dialogsEnabled="false"
else
    log INFO "Console user: ${user}"
fi
CONSOLE_USER="$user"
index_installed_apps
resolve_color_mode
log INFO "Window color mode: ${COLOR_MODE} (resolved ${RESOLVED_APPEARANCE})"
if ! is_true "$BLUR_SCREEN"; then
    log INFO "Dialog: no blur, resizable, on-top"
fi

if [[ ${#STEPS[@]} -gt 0 ]]; then
    seed_placeholder_steps
    if [[ "$dialogsEnabled" == "true" ]]; then
        window_copy
        DIALOG_FINGERPRINT="${CURRENT_TITLE}|${STEP_STATE[*]}|${STEP_ICONS[*]}"
        launch_dialog
        log INFO "Fleet Interlude window opened before software catalog"
    fi
fi

###############################################################################
# Resolve the step list
###############################################################################
log INFO "Fetching available software from Fleet..."
fetch_available_software_tsv
index_installed_apps
log INFO "Software catalog: $(/usr/bin/wc -l < "$SOFTWARE_TSV" | /usr/bin/tr -d ' ') title(s)"

if [[ ${#STEPS[@]} -gt 0 ]]; then
    i=0
    for want in "${STEPS[@]}"; do
        if ! lookup_title "$want"; then
            log WARN "No available software titled '${want}' for this host"
            STEP_STATE[$i]="fail"
            i=$((i + 1))
            continue
        fi
        if [[ "$FOUND_SS" != "1" ]]; then
            log WARN "Title ${FOUND_NAME} (id ${FOUND_ID}) is not self-service; the device install API will reject it."
            STEP_STATE[$i]="fail"
            i=$((i + 1))
            continue
        fi
        fill_step_from_title "$i"
        disk_path=$(find_application "$FOUND_BUNDLE" "$FOUND_PATHS" || true)
        if is_script_software "$FOUND_PKG" "$FOUND_SOURCE" "$FOUND_NAME"; then
            log INFO "Step: ${FOUND_NAME} (title_id=${FOUND_ID}, fleet_status=${FOUND_STATUS:-none}, kind=script source=${FOUND_SOURCE:-none}, package=${FOUND_PKG:-none}, baseline_install_key=${FOUND_LAST_INSTALL_KEY:-none})"
        elif [[ "$(status_rank "$FOUND_STATUS")" == "success" && -z "$disk_path" ]]; then
            log INFO "Step: ${FOUND_NAME} (title_id=${FOUND_ID}, fleet_status=${FOUND_STATUS:-none}, on_disk=missing; will queue)"
        else
            log INFO "Step: ${FOUND_NAME} (title_id=${FOUND_ID}, fleet_status=${FOUND_STATUS:-none}, on_disk=${disk_path:-no})"
        fi
        if [[ -z "${STEP_ICONS[$i]}" ]]; then
            log WARN "No icon for ${FOUND_NAME}; using letter placeholder"
        fi
        i=$((i + 1))
    done
elif is_true "$AUTO_DISCOVER"; then
    while IFS=$'\x1f' read -r id name ss status icon bundle pkg source lastkey paths; do
        [[ -z "${id:-}" ]] && continue
        [[ "$ss" != "1" ]] && continue
        FOUND_BUNDLE="${bundle:-}"
        FOUND_PKG="${pkg:-}"
        FOUND_SOURCE="${source:-}"
        FOUND_LAST_INSTALL_KEY="${lastkey:-}"
        FOUND_PATHS="${paths:-}"
        resolved_icon=$(resolve_step_icon "$id" "$name" "$icon")
        add_step "$id" "$name" "$resolved_icon" "$(initial_step_state "$name" "$status" "$FOUND_BUNDLE" "$FOUND_PKG" "$FOUND_SOURCE" "$FOUND_PATHS")" "$FOUND_PKG" "$FOUND_SOURCE" "$FOUND_LAST_INSTALL_KEY"
        disk_path=$(find_application "$FOUND_BUNDLE" "$FOUND_PATHS" || true)
        log INFO "Discovered: ${name} (title_id=${id}, fleet_status=${status:-none}, on_disk=${disk_path:-no}, bundle_ids=${FOUND_BUNDLE:-none})"
    done < "$SOFTWARE_TSV"
else
    log ERROR "STEPS is empty and AUTO_DISCOVER is false; nothing to queue."
    exit 1
fi

if [[ ${#STEP_IDS[@]} -eq 0 ]]; then
    log ERROR "No installable steps resolved. This host has no self-service titles available to install."
    exit 1
fi
log INFO "${#STEP_IDS[@]} step(s) in Fleet Interlude"

# ~/Applications is only indexed after we know the console user. Re-check
# skip-queue so we do not reinstall something already in the user folder.
i=0
while [[ $i -lt ${#STEP_IDS[@]} ]]; do
    if [[ "${STEP_STATE[$i]}" != "success" && "${STEP_STATE[$i]}" != "fail" ]] && lookup_title "${STEP_IDS[$i]}"; then
        if ! is_script_software "${STEP_PACKAGES[$i]}" "${STEP_SOURCES[$i]}" "${STEP_NAMES[$i]}" && \
                disk_path=$(find_application "$FOUND_BUNDLE" "$FOUND_PATHS"); then
            log INFO "On disk after console-user index: ${STEP_NAMES[$i]} (${disk_path})"
            STEP_STATE[$i]="success"
        fi
    fi
    i=$((i + 1))
done

if [[ "$dialogsEnabled" == "true" && -z "${DIALOG_PID:-}" ]]; then
    window_copy
    DIALOG_FINGERPRINT="${CURRENT_TITLE}|${STEP_STATE[*]}|${STEP_ICONS[*]}"
    launch_dialog
fi
refresh_dialog

###############################################################################
# Queue installs. The window is already open (placeholder STEPS) so this
# only updates status. SERIAL_STEPS=true queues one unfinished title at a time.
###############################################################################
queue_title() {
    local id="$1" name="$2" http
    case "$id" in
        ''|*[!0-9]*)
            log WARN "Queue ${name}: skip non-numeric title id '${id}'"
            return 1
            ;;
    esac
    if is_true "$DRY_RUN"; then
        log INFO "[DRY-RUN] Would POST software/install/${id} (${name})"
        return 0
    fi
    http=$(fleet_request POST "/software/install/${id}")
    case "$http" in
        202|200)
            log INFO "Queued ${name} (title_id=${id}, HTTP ${http})"
            ;;
        409)
            log INFO "${name} already queued (HTTP 409)"
            ;;
        *)
            log WARN "Queue ${name} (title_id=${id}) failed HTTP ${http}: $(/usr/bin/head -c 300 "$FLEET_BODY" | /usr/bin/tr '\n' ' ')"
            return 1
            ;;
    esac
    return 0
}

mark_step_queued() {
    local i="$1"
    STEP_QUEUED[$i]="true"
    if is_true "$DRY_RUN"; then
        : # simulated in the poll loop
    else
        STEP_STATE[$i]="wait"
    fi
}

serial_next_index() {
    local i=0
    while [[ $i -lt ${#STEP_IDS[@]} ]]; do
        case "${STEP_STATE[$i]}" in
            success|fail) ;;
            *)
                printf '%s' "$i"
                return 0
                ;;
        esac
        i=$((i + 1))
    done
    return 1
}

serial_has_in_flight() {
    local i=0
    while [[ $i -lt ${#STEP_IDS[@]} ]]; do
        if [[ "${STEP_STATE[$i]}" == "wait" ]]; then
            return 0
        fi
        if [[ "${STEP_QUEUED[$i]}" == "true" && \
                "${STEP_STATE[$i]}" != "success" && \
                "${STEP_STATE[$i]}" != "fail" ]]; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

queue_next_serial_step() {
    local i name
    i=$(serial_next_index) || return 1
    name="${STEP_NAMES[$i]}"
    log INFO "Serial: queueing ${name} (step $((i + 1)) of ${#STEP_IDS[@]})"
    if queue_title "${STEP_IDS[$i]}" "$name"; then
        mark_step_queued "$i"
        return 0
    fi
    STEP_STATE[$i]="fail"
    return 1
}

# Queue the next unfinished title, or stop the chain after a failure.
# Immediate queue failures loop here so skip mode can try the next step
# without waiting a poll interval.
advance_serial_queue() {
    local guard=0
    while [[ $guard -lt ${#STEP_IDS[@]} ]]; do
        guard=$((guard + 1))
        if serial_has_in_flight; then
            return 0
        fi
        if ! serial_next_index >/dev/null; then
            return 0
        fi
        if [[ "$(count_failed)" -gt 0 && "$SERIAL_ON_FAIL" == "stop" ]]; then
            SERIAL_STOPPED="true"
            log WARN "Serial: stopping after a failed step (SERIAL_ON_FAIL=stop); remaining steps stay pending"
            return 0
        fi
        if queue_next_serial_step; then
            return 0
        fi
        if [[ "$SERIAL_ON_FAIL" == "stop" ]]; then
            SERIAL_STOPPED="true"
            log WARN "Serial: stopping after a failed queue (SERIAL_ON_FAIL=stop); remaining steps stay pending"
            return 0
        fi
        log WARN "Serial: skipping failed step (SERIAL_ON_FAIL=skip)"
    done
}

i=0
while [[ $i -lt ${#STEP_IDS[@]} ]]; do
    if [[ "${STEP_STATE[$i]}" == "success" ]]; then
        log INFO "Already on disk: ${STEP_NAMES[$i]}"
    fi
    i=$((i + 1))
done

if is_true "$SERIAL_STEPS"; then
    log INFO "Serial queue: one title at a time (SERIAL_ON_FAIL=${SERIAL_ON_FAIL})"
    advance_serial_queue
else
    i=0
    while [[ $i -lt ${#STEP_IDS[@]} ]]; do
        if [[ "${STEP_STATE[$i]}" == "success" || "${STEP_STATE[$i]}" == "fail" ]]; then
            i=$((i + 1))
            continue
        fi
        if queue_title "${STEP_IDS[$i]}" "${STEP_NAMES[$i]}"; then
            mark_step_queued "$i"
        else
            STEP_STATE[$i]="fail"
        fi
        i=$((i + 1))
    done
fi

refresh_dialog

###############################################################################
# Poll until terminal or timeout
###############################################################################
start_ts=$(/bin/date +%s)
sim_index=0

while ! all_terminal && ! is_true "$SERIAL_STOPPED"; do
    now=$(/bin/date +%s)
    if [[ $((now - start_ts)) -ge $MAX_WAIT_SECONDS ]]; then
        log WARN "Timed out after ${MAX_WAIT_SECONDS}s; leaving remaining steps pending"
        break
    fi

    if is_true "$DRY_RUN"; then
        if is_true "$SERIAL_STEPS"; then
            advance_serial_queue
            i=0
            while [[ $i -lt ${#STEP_IDS[@]} ]]; do
                if [[ "${STEP_QUEUED[$i]}" == "true" && \
                        "${STEP_STATE[$i]}" != "success" && \
                        "${STEP_STATE[$i]}" != "fail" ]]; then
                    STEP_STATE[$i]="wait"
                    refresh_dialog
                    sleep 2
                    STEP_STATE[$i]="success"
                    log INFO "[DRY-RUN] Simulated install: ${STEP_NAMES[$i]}"
                    break
                fi
                i=$((i + 1))
            done
        elif [[ $sim_index -lt ${#STEP_IDS[@]} ]]; then
            # Advance one step at a time so the window looks like a live run.
            if [[ "${STEP_STATE[$sim_index]}" != "success" && "${STEP_STATE[$sim_index]}" != "fail" ]]; then
                STEP_STATE[$sim_index]="wait"
                refresh_dialog
                sleep 2
                STEP_STATE[$sim_index]="success"
                log INFO "[DRY-RUN] Simulated install: ${STEP_NAMES[$sim_index]}"
            fi
            sim_index=$((sim_index + 1))
        fi
        refresh_dialog
        sleep 1
        continue
    fi

    if is_true "$DEBUG_LOGGING"; then
        log DEBUG "Poll cycle: refreshing Fleet software catalog"
    fi
    if ! fetch_available_software_tsv; then
        log WARN "Poll cycle: Fleet software refresh failed; retaining the prior catalog"
    elif is_true "$DEBUG_LOGGING"; then
        log DEBUG "Poll cycle: Fleet software catalog refreshed"
    fi
    index_installed_apps
    i=0
    while [[ $i -lt ${#STEP_IDS[@]} ]]; do
        if [[ "${STEP_STATE[$i]}" == "success" || "${STEP_STATE[$i]}" == "fail" ]]; then
            i=$((i + 1))
            continue
        fi
        # Serial mode must not let Fleet status on unqueued titles flip them
        # to Installing; that would look like in-flight work and stall the chain.
        if is_true "$SERIAL_STEPS" && [[ "${STEP_QUEUED[$i]}" != "true" ]]; then
            i=$((i + 1))
            continue
        fi
        if lookup_title "${STEP_IDS[$i]}"; then
            disk_path=""
            if is_true "$DEBUG_LOGGING"; then
                log DEBUG "${STEP_NAMES[$i]}: poll metadata (fleet_status=${FOUND_STATUS:-none}, source=${FOUND_SOURCE:-none}, package=${FOUND_PKG:-none}, initial_source=${STEP_SOURCES[$i]:-none}, initial_package=${STEP_PACKAGES[$i]:-none})"
            fi
            if is_script_software "${STEP_PACKAGES[$i]}" "${STEP_SOURCES[$i]}" "${STEP_NAMES[$i]}" || \
                    is_script_software "$FOUND_PKG" "$FOUND_SOURCE" "$FOUND_NAME"; then
                # No .app exists for a script package. Its install UUID changes
                # only after Fleet records a new execution, so compare it with
                # the value captured before this run queued the script. A
                # previous result's Fleet status must not settle this run.
                result_http="not-queried"
                result_status="not-queried"
                if [[ "${STEP_QUEUED[$i]}" == "true" && \
                        -n "$FOUND_LAST_INSTALL_KEY" && \
                        "$FOUND_LAST_INSTALL_KEY" != "${STEP_BASELINE_INSTALL_KEYS[$i]}" ]]; then
                    if [[ -z "${STEP_TRACKED_INSTALL_UUIDS[$i]}" ]]; then
                        STEP_TRACKED_INSTALL_UUIDS[$i]="$FOUND_LAST_INSTALL_KEY"
                        log INFO "${STEP_NAMES[$i]}: observed new install_uuid=${FOUND_LAST_INSTALL_KEY}"
                    fi
                    script_install_result_state "${STEP_TRACKED_INSTALL_UUIDS[$i]}"
                    new_state="$SCRIPT_INSTALL_RESULT_STATE"
                    result_http="${SCRIPT_INSTALL_RESULT_HTTP:-none}"
                    result_status="${SCRIPT_INSTALL_RESULT_STATUS:-none}"
                else
                    new_state="wait"
                fi
                if is_true "$DEBUG_LOGGING"; then
                    log DEBUG "${STEP_NAMES[$i]}: script poll (fleet_status=${FOUND_STATUS:-none}, baseline_install_uuid=${STEP_BASELINE_INSTALL_KEYS[$i]:-none}, current_install_uuid=${FOUND_LAST_INSTALL_KEY:-none}, tracked_install_uuid=${STEP_TRACKED_INSTALL_UUIDS[$i]:-none}, result_http=${result_http}, result_status=${result_status:-none}, tracker_state=${new_state})"
                fi
            elif [[ -n "$FOUND_BUNDLE" ]] && disk_path=$(find_application "$FOUND_BUNDLE" "$FOUND_PATHS"); then
                new_state="success"
            elif [[ -n "$FOUND_BUNDLE" ]]; then
                new_state=$(status_rank "$FOUND_STATUS")
                # Fleet "installed" is the installer result, not disk proof.
                # Keep Installing until the bundle is on disk, or fail.
                if [[ "$new_state" == "success" ]]; then
                    new_state="wait"
                fi
                if [[ "$new_state" == "pending" && "${STEP_STATE[$i]}" == "wait" ]]; then
                    new_state="wait"
                fi
            else
                new_state=$(status_rank "$FOUND_STATUS")
                if [[ "$new_state" == "pending" && "${STEP_STATE[$i]}" == "wait" ]]; then
                    new_state="wait"
                fi
            fi
            old_state="${STEP_STATE[$i]}"
            if [[ "$new_state" != "$old_state" ]]; then
                if is_script_software "${STEP_PACKAGES[$i]}" "${STEP_SOURCES[$i]}" "${STEP_NAMES[$i]}" || \
                        is_script_software "$FOUND_PKG" "$FOUND_SOURCE" "$FOUND_NAME"; then
                    log INFO "${STEP_NAMES[$i]}: ${old_state} -> ${new_state} (fleet=${FOUND_STATUS:-none}, kind=script, install_key=${FOUND_LAST_INSTALL_KEY:-none})"
                else
                    log INFO "${STEP_NAMES[$i]}: ${old_state} -> ${new_state} (fleet=${FOUND_STATUS:-none}, on_disk=${disk_path:-no}, bundle_ids=${FOUND_BUNDLE:-none})"
                fi
                STEP_STATE[$i]="$new_state"
            fi
            if [[ -z "${STEP_ICONS[$i]}" || ( "$new_state" == "success" && "$old_state" != "success" ) ]]; then
                resolved_icon=$(resolve_step_icon "${STEP_IDS[$i]}" "${STEP_NAMES[$i]}" "$FOUND_ICON")
                if [[ -n "$resolved_icon" ]]; then
                    STEP_ICONS[$i]="$resolved_icon"
                fi
            fi
        elif is_true "$DEBUG_LOGGING"; then
            log DEBUG "${STEP_NAMES[$i]}: title_id=${STEP_IDS[$i]} absent from current Fleet catalog"
        fi
        i=$((i + 1))
    done
    if is_true "$SERIAL_STEPS"; then
        advance_serial_queue
    fi
    refresh_dialog
    sleep "$POLL_INTERVAL_SECONDS"
done

###############################################################################
# Finish
###############################################################################
failed=0
i=0
while [[ $i -lt ${#STEP_IDS[@]} ]]; do
    if [[ "${STEP_STATE[$i]}" == "fail" ]]; then
        failed=$((failed + 1))
        log WARN "Failed: ${STEP_NAMES[$i]} (title_id=${STEP_IDS[$i]})"
    elif [[ "${STEP_STATE[$i]}" != "success" ]]; then
        log WARN "Still pending: ${STEP_NAMES[$i]} (title_id=${STEP_IDS[$i]})"
    fi
    i=$((i + 1))
done

refresh_dialog
push_dialog "button1text: Close"
push_dialog "button1: enable"

if [[ "$failed" -eq 0 ]] && all_terminal; then
    if ! is_true "$DRY_RUN"; then
        /usr/bin/touch "$DONE_MARK"
        log INFO "Wrote ${DONE_MARK}"
    else
        log INFO "[DRY-RUN] Would write ${DONE_MARK}"
    fi
    log INFO "All ${#STEP_IDS[@]} step(s) completed."
else
    if is_true "$SERIAL_STOPPED"; then
        log WARN "Serial run stopped after a failure; remaining steps were not queued"
    fi
    log WARN "Finished with ${failed} failed step(s); not writing ${DONE_MARK}"
fi

# Hold the window so the user can read the final state, then drop the blur.
if [[ "$dialogsEnabled" == "true" && -n "$DIALOG_PID" ]]; then
    sleep "$COMPLETE_HOLD_SECONDS"
    push_dialog "blurscreen: disable"
    push_dialog "quit:"
    wait "$DIALOG_PID" 2>/dev/null || true
    DIALOG_PID=""
fi

log INFO "Done."
exit 0
