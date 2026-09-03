#!/usr/bin/env bash
#
# Shared foundations: locale, dependency preflight, failure, logging.
#
# Sourced by every bot. Sources nothing itself, so a bot's `. ` lines say
# exactly what it depends on.
#
# Nothing here is specific to Bluesky or Mastodon.

# Guard against double-sourcing, which would reset the redaction list
if [ -n "${BOTLIB_CORE_LOADED:-}" ]; then
    return 0
fi
BOTLIB_CORE_LOADED=1

# Name of the running bot, used in log lines. Set by load_secrets, but default
# to the script's directory so that logging works before secrets are loaded --
# including from exit_error, which may fire during preflight.
BOT_NAME="${BOT_NAME:-$(basename "$(dirname "${BASH_SOURCE[1]:-$0}")")}"

# Where log files are written. Under the harness this moves into the sandbox,
# so a test run never appends to the real log.
if [ -n "${HARNESS_CAPTURE:-}" ]; then
    BOT_LOG_DIR="${BOT_LOG_DIR:-${HARNESS_CAPTURE}/logs}"
else
    BOT_LOG_DIR="${BOT_LOG_DIR:-${HOME}/.local/state/botlib}"
fi

# Values to strip from log lines. load_secrets appends every credential it
# loads; see redact().
BOTLIB_REDACT_VALUES=""

# Pin a UTF-8 locale, since several bots count characters rather than bytes:
# ${#text} sizes a post against the platforms' character limits, and truncation
# appends a multi-byte ellipsis. Under the C locale bash counts bytes instead,
# which would over-truncate. Cron runs with a bare environment on Ubuntu, so
# the locale cannot be assumed to be inherited.
#
# C.UTF-8 is built into glibc and so is always present on Ubuntu without
# locale-gen, and macOS accepts it too. Fall back to en_US.UTF-8 on any system
# that lacks it.
pin_utf8_locale() {
    if locale -a 2>/dev/null | grep -qxi 'C\.UTF-*8'; then
        export LC_ALL="C.UTF-8"
    else
        export LC_ALL="en_US.UTF-8"
    fi
}

# Replace any known credential, and any bearer token, with <REDACTED>.
#
# Redaction is by value rather than by pattern: the loaded secrets are known,
# so a token interpolated into an error message is caught, which a pattern
# looking for `Bearer ...` would miss. The bearer pattern is kept as well, for
# tokens the library never loaded -- a service JWT, say, minted mid-run.
redact() {
    local text="$1"
    local value

    # Bearer tokens first, since a value-based pass would leave the keyword
    text=$(printf '%s' "$text" | sed -E 's/(Bearer)[[:space:]]+[A-Za-z0-9._~+\/=-]+/\1 <REDACTED>/g')

    # Then every credential the library knows about. Split on newline, since
    # a credential may contain any other character.
    local IFS=$'\n'
    for value in $BOTLIB_REDACT_VALUES; do
        # Skip empties and implausibly short values: redacting a 3-character
        # secret would mangle ordinary words in the message
        if [ "${#value}" -lt 8 ]; then
            continue
        fi
        # Substitute literally. Bash's ${var//search/replace} does no pattern
        # interpretation on the search term when it is quoted, so a token
        # containing regex metacharacters is handled correctly -- unlike sed.
        text="${text//"$value"/<REDACTED>}"
    done

    printf '%s' "$text"
}

# Register a value to be stripped from all subsequent log output
add_redaction() {
    if [ -n "${1:-}" ]; then
        BOTLIB_REDACT_VALUES="${BOTLIB_REDACT_VALUES}${1}"$'\n'
    fi
}

# Append one line to the bot's log file. Failure to write is swallowed: a
# read-only or missing log directory must not take down a bot that is otherwise
# able to post.
log_to_file() {
    local level="$1"
    local message="$2"

    mkdir -p "$BOT_LOG_DIR" 2>/dev/null || return 0

    printf '%s %s %-5s %s\n' \
        "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        "$BOT_NAME" \
        "$level" \
        "$message" \
        >> "${BOT_LOG_DIR}/${BOT_NAME}.log" 2>/dev/null || true
}

# Post to Slack, best-effort.
#
# Skipped entirely under the harness: the curl shim records every request, so a
# webhook call would appear in the goldens and change them. Logging is
# deliberately invisible to the request contract.
log_to_slack() {
    local message="$1"

    [ -n "${HARNESS_CAPTURE:-}" ] && return 0
    [ -n "${SLACK_WEBHOOK_URL:-}" ] || return 0

    local payload
    payload=$(jq -n --arg text "[${BOT_NAME}] ${message}" '{text: $text}') || return 0

    # --max-time so a hanging webhook cannot stall a cron job indefinitely.
    # All output discarded, and the failure recorded on disk rather than
    # raised: Slack being down is not the bot's problem.
    if ! curl -s -f --max-time 10 \
        -X POST -H 'Content-Type: application/json' \
        -d "$payload" "$SLACK_WEBHOOK_URL" > /dev/null 2>&1; then
        log_to_file "WARN" "Slack delivery failed"
    fi

    return 0
}

# Informational events go to disk only. Nine bots posting several times daily
# would make a Slack channel useless, and the reason to route logs there is to
# notice failures without reading nine log files.
log_info() {
    local message
    message=$(redact "$1")
    log_to_file "INFO" "$message"
}

# Errors go to disk and to Slack, because under cron a failure is otherwise
# silent or lands in a mail nobody reads
log_error() {
    local message
    message=$(redact "$1")
    log_to_file "ERROR" "$message"
    log_to_slack "$message"
}

# Fail, loudly and consistently.
#
# This is the single failure path: it logs at error level -- and so reports to
# Slack -- before exiting, meaning no bot has to remember to log before it
# dies. Cleanup stays with the bot, in its own `trap cleanup EXIT`, which is
# where it can know what needs removing.
exit_error() {
    local message="$1"
    local code="${2-1}"

    log_error "$message"
    printf '%s\n' "$(redact "$message")" >&2
    exit "$code"
}

# Check that every named command is present before doing any work, so a missing
# dependency fails immediately with a clear message rather than partway through
# with a cryptic one
require_commands() {
    # Deliberately not named `command`: that would shadow the builtin used to
    # test for it, and every check would fail
    local needed
    for needed in "$@"; do
        if ! command -v "$needed" > /dev/null 2>&1; then
            exit_error "$needed is required but not installed"
        fi
    done
}
