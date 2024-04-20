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

# Move into the directory where this script is found
cd "$(dirname "$0")" || exit

# Select a random entry from the list
ENTRY=$(sort -R finds_you.txt |head -1)

# Remove any trailing carriage return from the entry
ENTRY=$(echo "$ENTRY" | tr -d '\r')

POST="I hope this email ${ENTRY}"

# Send the message to Mastodon
curl "$MASTODON_SERVER"/api/v1/statuses -H "Authorization: Bearer ${MASTODON_TOKEN}" -F "status=${POST}"

RESULT=$?
if [ "$RESULT" -ne 0 ]; then
    exit_error "Posting message to Mastodon failed"
fi
