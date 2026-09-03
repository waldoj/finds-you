#!/usr/bin/env bash

set -x

# Shared library: credentials, logging, the failure path, and both platforms'
# transport. See lib/botlib/ and the bot-harness docs.
. "$(dirname "$0")/lib/botlib/core.sh"
. "$(dirname "$0")/lib/botlib/secrets.sh"
. "$(dirname "$0")/lib/botlib/mastodon.sh"
. "$(dirname "$0")/lib/botlib/bluesky.sh"

load_secrets finds-you
require_secrets MASTODON_SERVER MASTODON_TOKEN \
                BLUESKY_SERVER BLUESKY_HANDLE BLUESKY_APP_PASSWORD

# Select an entry from the list
function select_entry {
    # Select a random entry from the list
    local entry=$(sort -R finds_you.txt | head -1)
    # Remove any trailing carriage return from the entry
    echo "$entry" | tr -d '\r'
}

# See if an entry has been used in the past 500 posts
function is_recent {
    local entry_hash=$(echo -n "$1" | md5sum | cut -d ' ' -f 1)
    if tail -n 500 post_history.txt | grep -q "$entry_hash"; then
        return 0  # 0 = true, recent
    else
        return 1  # 1 = false, not recent
    fi
}

# Move into the directory where this script is found
cd "$(dirname "$0")" || exit

# The entry list is the whole of this bot's content. Without it `sort -R`
# yields nothing, ENTRY comes out empty, and the bot posts the bare prefix
# "I hope this email finds you" -- which is what happened on the first
# deployment to a new server, where the file had not been copied across.
if [ ! -s finds_you.txt ]; then
    exit_error "finds_you.txt is missing or empty"
fi

# Loop until a non-recent entry is found.
#
# Bounded, unlike the original: is_recent looks at the last 500 posts, and if
# those ever cover every available entry the unbounded loop spins forever. The
# list holds a few hundred entries, so that is reachable rather than
# theoretical. Giving up is better than hanging a cron job.
MAX_SELECTION_ATTEMPTS=100
attempts=0

while [ "$attempts" -lt "$MAX_SELECTION_ATTEMPTS" ]; do
    attempts=$(( attempts + 1 ))
    ENTRY=$(select_entry)
    if ! is_recent "$ENTRY"; then
        break
    fi
    echo "Entry is recent, selecting another..."
done

if [ -z "$ENTRY" ]; then
    exit_error "Could not select an entry"
fi

if [ "$attempts" -ge "$MAX_SELECTION_ATTEMPTS" ]; then
    exit_error "Could not find an unused entry in $MAX_SELECTION_ATTEMPTS attempts"
fi

POST="I hope this email ${ENTRY}"

# Send the message to Mastodon
masto_post_status "$POST" > /dev/null \
    || exit_error "Posting message to Mastodon failed"

log_info "posted to mastodon"

# Log this to the post history
echo -n "$ENTRY" | md5sum | cut -d ' ' -f 1 >> post_history.txt

# Create an authentication session on Bluesky
SESSION_JSON=$(bsky_create_session "$BLUESKY_HANDLE" "$BLUESKY_APP_PASSWORD") \
    || exit_error "Could not authenticate to Bluesky"

ACCESS_JWT=$(bsky_access_jwt "$SESSION_JSON")

# The repo is the account's DID, not its handle. This bot used to send the
# handle, which works against the live API but is not what a record is keyed
# on -- a handle change would orphan every post made under the old one.
BLUESKY_DID=$(bsky_did "$SESSION_JSON")
if [ -z "$BLUESKY_DID" ]; then
    exit_error "Bluesky login didn’t return a DID."
fi

# Build the record with jq rather than string interpolation. Seven of the 726
# entries in finds_you.txt contain a double quote, which produced malformed
# JSON and a silently failed post roughly once in every hundred runs.
RECORD=$(jq -n \
    --arg text "$POST" \
    --arg created_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '{
        "$type": "app.bsky.feed.post",
        text: $text,
        createdAt: $created_at
    }')

bsky_create_record "$BLUESKY_DID" "$ACCESS_JWT" "$RECORD" > /dev/null \
    || exit_error "Posting message to Bluesky failed"

log_info "posted to bluesky"
