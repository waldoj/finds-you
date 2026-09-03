#!/usr/bin/env bash
#
# Credential loading.
#
# Requires core.sh.
#
# All nine bots' credentials live in one file outside the repos, so there is a
# single place to provision and rotate. The tradeoff, accepted deliberately:
# compromise of that file exposes every account. It must be mode 0600.
#
# Format is shell, sourced rather than parsed, with variables prefixed by the
# bot's name in upper snake case:
#
#     BOUS_MASTODON_SERVER="https://mastodon.social"
#     BOUS_MASTODON_TOKEN="..."
#     BOUS_BLUESKY_HANDLE="botofunusualsize.bsky.social"
#     BOUS_BLUESKY_APP_PASSWORD="..."
#     BOUS_S3_BUCKET="s3://bous.jaquith.org/"
#
#     REJECTED_PLATES_MASTODON_SERVER="https://mastodon.social"
#     ...
#
#     SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
#
# Shell format because these values already are shell strings, and a bot that
# needs to add a variable should not need a parser change. The cost is that the
# file is executable code; it is owned by the user running the bots and is
# never written by anything but a human.

if [ -n "${BOTLIB_SECRETS_LOADED:-}" ]; then
    return 0
fi
BOTLIB_SECRETS_LOADED=1

# Where the shared secrets file lives. Overridable so the harness can point at
# a fixture instead of the real credentials.
BOT_SECRETS_FILE="${BOT_SECRETS_FILE:-${HOME}/.config/botlib/secrets.env}"

# Turn a bot's directory name into the prefix used in the secrets file:
# `rejected-plates` becomes `REJECTED_PLATES`.
secrets_prefix_for() {
    printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

# Load one bot's credentials into the conventional variable names.
#
# Populates whichever of these the secrets file defines for this bot:
#   MASTODON_SERVER MASTODON_TOKEN
#   BLUESKY_HANDLE BLUESKY_APP_PASSWORD BLUESKY_SERVER
#   S3_BUCKET
# plus SLACK_WEBHOOK_URL, which is shared rather than per-bot.
#
# Absent values are left unset rather than defaulted. A bot that needs one
# should say so with require_secrets, which fails with a clear message -- an
# empty token would otherwise produce a confusing 401 from the platform.
load_secrets() {
    local bot="${1:?load_secrets requires a bot name}"

    BOT_NAME="$bot"

    if [ ! -f "$BOT_SECRETS_FILE" ]; then
        exit_error "Secrets file not found: $BOT_SECRETS_FILE"
    fi

    # Refuse to read a world- or group-readable secrets file. This holds every
    # bot's credentials, so loose permissions are worth stopping for rather
    # than warning about. Both stat dialects, since these run on macOS and
    # Ubuntu both.
    #
    # Skipped under the harness: the fixture secrets file is committed, holds
    # nothing real, and git records only the executable bit -- so a checkout
    # cannot preserve 600 and every clone would otherwise fail here.
    if [ -z "${HARNESS_CAPTURE:-}" ]; then
        # GNU stat first, then BSD. Deliberately not the other way around: on
        # Linux `stat -f` is valid but means "filesystem info", so it succeeds
        # with output that is not a mode at all -- the `||` would never fire
        # and the arithmetic below would fail on a non-numeric value.
        local mode
        mode=$(stat -c '%a' "$BOT_SECRETS_FILE" 2>/dev/null) \
            || mode=$(stat -f '%Lp' "$BOT_SECRETS_FILE" 2>/dev/null) \
            || mode=""

        # Only act on something that actually looks like an octal mode. An
        # unrecognised stat is a reason to skip the check, not to fail: the
        # permissions may well be fine, and refusing to run would be worse
        # than not checking.
        case "$mode" in
            [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) : ;;
            *) mode="" ;;
        esac

        if [ -n "$mode" ] && [ "$(( 8#$mode & 8#077 ))" -ne 0 ]; then
            exit_error "Secrets file $BOT_SECRETS_FILE is mode $mode; must be 600"
        fi
    fi

    # shellcheck disable=SC1090
    . "$BOT_SECRETS_FILE" || exit_error "Could not read $BOT_SECRETS_FILE"

    local prefix
    prefix=$(secrets_prefix_for "$bot")

    local name
    for name in MASTODON_SERVER MASTODON_TOKEN \
                BLUESKY_HANDLE BLUESKY_APP_PASSWORD BLUESKY_SERVER \
                S3_BUCKET; do
        # Indirect expansion: read BOUS_MASTODON_TOKEN into MASTODON_TOKEN
        local source_var="${prefix}_${name}"
        local value="${!source_var-}"

        if [ -n "$value" ]; then
            printf -v "$name" '%s' "$value"
            export "${name?}"
        fi
    done

    # Every credential loaded is registered for redaction, so a token that ends
    # up inside an error message never reaches a log file or Slack
    add_redaction "${MASTODON_TOKEN:-}"
    add_redaction "${BLUESKY_APP_PASSWORD:-}"
    add_redaction "${SLACK_WEBHOOK_URL:-}"

    return 0
}

# Fail unless every named variable is set and non-empty.
#
# Called by a bot after load_secrets, naming what it actually needs:
#
#     require_secrets MASTODON_SERVER MASTODON_TOKEN
require_secrets() {
    local name
    for name in "$@"; do
        if [ -z "${!name-}" ]; then
            exit_error "$name is not set for $BOT_NAME in $BOT_SECRETS_FILE"
        fi
    done
}
