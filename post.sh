#!/usr/bin/env bash

set -x

# URL of your Mastodon server, without a trailing slash
MASTODON_SERVER="https://mastodon.social"

# Your Mastodon account's access token
MASTODON_TOKEN="TOKEN_HERE"

# Define a failure function
function exit_error {
    printf '%s\n' "$1" >&2
    exit "${2-1}"
}

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
    if tail -n 50 post_history.txt | grep -q "$entry_hash"; then
        return 0  # 0 = true, recent
    else
        return 1  # 1 = false, not recent
    fi
}

# Move into the directory where this script is found
cd "$(dirname "$0")" || exit

# Loop until a non-recent entry is found
while true; do
    ENTRY=$(select_entry)
    if is_recent "$ENTRY"; then
        echo "Entry is recent, selecting another..."
        continue
    else
        break
    fi
done

POST="I hope this email ${ENTRY}"

# Send the message to Mastodon
curl "$MASTODON_SERVER"/api/v1/statuses -H "Authorization: Bearer ${MASTODON_TOKEN}" -F "status=${POST}"
RESULT=$?
if [ "$RESULT" -ne 0 ]; then
    exit_error "Posting message to Mastodon failed"
fi

# Log this to the post history
echo -n "$ENTRY" | md5sum | cut -d ' ' -f 1 >> post_history.txt
