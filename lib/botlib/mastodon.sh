#!/usr/bin/env bash
#
# Mastodon transport.
#
# Requires core.sh and secrets.sh.
#
# Functions print their result to stdout and return 0, or return non-zero
# having printed nothing. Callers use $(...) and check the status. JSON goes in
# and out raw, so a caller needing an unusual field can jq it out without a
# library change.

if [ -n "${BOTLIB_MASTODON_LOADED:-}" ]; then
    return 0
fi
BOTLIB_MASTODON_LOADED=1

# How long to wait for the server to finish processing an upload
MASTO_POLL_ATTEMPTS="${MASTO_POLL_ATTEMPTS:-60}"
MASTO_POLL_DELAY="${MASTO_POLL_DELAY:-5}"

# Upload a media file, returning its media id.
#
# Uses the v2 endpoint throughout. v2 returns 202 for anything needing
# transcoding -- the media is accepted but not yet attachable -- so callers
# must masto_await_media before posting a status. v1 returned only when the
# media was ready, which was simpler but meant a long upload could time out.
#
# The description is sent as given, including empty: what empty alt text means
# is the bot's judgement, not the library's, and at least one bot posts an
# image whose caption legitimately comes out blank.
masto_upload_media() {
    local file="$1"
    local alt="$2"

    local response
    response=$(curl -s -f -X POST \
        -H "Authorization: Bearer ${MASTODON_TOKEN}" \
        -F "file=@${file}" \
        -F "description=${alt}" \
        "${MASTODON_SERVER}/api/v2/media") || return 1

    local media_id
    media_id=$(printf '%s' "$response" | jq -r '.id // empty')

    if [ -z "$media_id" ]; then
        return 1
    fi

    printf '%s' "$media_id"
    return 0
}

# Wait for the server to finish processing an upload.
#
# 206 means still working; 200 means ready to attach. Anything else is a real
# failure and stops the wait rather than burning the full poll budget.
masto_await_media() {
    local media_id="$1"
    local attempt=0
    local status

    while [ "$attempt" -lt "$MASTO_POLL_ATTEMPTS" ]; do
        attempt=$(( attempt + 1 ))

        status=$(curl -s -o /dev/null -w '%{http_code}' \
            -H "Authorization: Bearer ${MASTODON_TOKEN}" \
            "${MASTODON_SERVER}/api/v1/media/${media_id}") || return 1

        if [ "$status" = "200" ]; then
            return 0
        fi

        if [ "$status" != "206" ]; then
            return 1
        fi

        sleep "$MASTO_POLL_DELAY"
    done

    return 1
}

# Post a status, optionally attaching already-uploaded media.
#
# Text is passed with -F rather than --data-urlencode so that multipart
# encoding handles newlines and non-ASCII without the caller escaping
# anything. Media ids are repeated as media_ids[], which is how Mastodon
# expects an array in a form body.
masto_post_status() {
    local text="$1"
    shift

    # The status goes through a file rather than the command line.
    #
    # `-F "status=$text"` puts the whole post in an argv entry, and a long one
    # overflows the kernel's limit: botgov hit "Argument list too long" from a
    # 12KB post. Mastodon would have rejected that as over-length anyway, but
    # the library should fail with the server's error rather than an exec
    # failure -- and a post well under the character limit can still carry
    # enough multi-byte characters to be a large number of bytes.
    local body_file
    body_file=$(mktemp "${TMPDIR:-/tmp}/botlib.status.XXXXXX") || return 1
    printf '%s' "$text" > "$body_file"

    local args=(-s -f -X POST
        -H "Authorization: Bearer ${MASTODON_TOKEN}"
        -F "status=<${body_file}")

    local media_id
    for media_id in "$@"; do
        args+=(-F "media_ids[]=${media_id}")
    done

    local response status
    response=$(curl "${args[@]}" "${MASTODON_SERVER}/api/v1/statuses")
    status=$?

    rm -f "$body_file"

    [ "$status" -eq 0 ] || return 1

    printf '%s' "$response"
    return 0
}

# Boost an existing status. Used by dreambot, which reblogs rather than posts.
masto_reblog() {
    local status_id="$1"

    local response
    response=$(curl -s -f -X POST \
        -H "Authorization: Bearer ${MASTODON_TOKEN}" \
        "${MASTODON_SERVER}/api/v1/statuses/${status_id}/reblog") || return 1

    printf '%s' "$response"
    return 0
}
