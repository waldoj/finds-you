#!/usr/bin/env bash
#
# Bluesky (AT Protocol) transport.
#
# Requires core.sh and secrets.sh.
#
# Record *construction* is deliberately not here. The embed differs enough
# between image, video, and video-with-captions that a shared builder would
# take more parameters than it saves, and the `jq -n` calls are the
# most-reviewed lines in each bot. This library handles transport; the bot
# decides what to say.

if [ -n "${BOTLIB_BLUESKY_LOADED:-}" ]; then
    return 0
fi
BOTLIB_BLUESKY_LOADED=1

BLUESKY_SERVER="${BLUESKY_SERVER:-https://bsky.social}"
BLUESKY_VIDEO_SERVER="${BLUESKY_VIDEO_SERVER:-https://video.bsky.app}"

BSKY_POLL_ATTEMPTS="${BSKY_POLL_ATTEMPTS:-60}"
BSKY_POLL_DELAY="${BSKY_POLL_DELAY:-5}"

# Authenticate, returning the full session JSON.
#
# The whole response is returned rather than just the token because callers
# need three things from it -- accessJwt, did, and didDoc -- and re-requesting
# a session for each would be three logins.
bsky_create_session() {
    local handle="$1"
    local password="$2"

    local response
    response=$(curl -s -f -X POST \
        "${BLUESKY_SERVER}/xrpc/com.atproto.server.createSession" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg identifier "$handle" \
            --arg password "$password" \
            '{identifier: $identifier, password: $password}')") || return 1

    # A session with no token is a failed login that returned 200
    if [ -z "$(printf '%s' "$response" | jq -r '.accessJwt // empty')" ]; then
        return 1
    fi

    # The tokens are credentials in their own right, and a later error message
    # may quote a response body wholesale
    add_redaction "$(printf '%s' "$response" | jq -r '.accessJwt // empty')"
    add_redaction "$(printf '%s' "$response" | jq -r '.refreshJwt // empty')"

    printf '%s' "$response"
    return 0
}

bsky_access_jwt() {
    printf '%s' "$1" | jq -r '.accessJwt // empty'
}

# The repo is the account's DID, which is not the same as the handle. Posting
# with the handle happens to work today, but the DID is what the record is
# actually keyed on and survives a handle change.
bsky_did() {
    printf '%s' "$1" | jq -r '.did // empty'
}

# Extract the PDS hostname from a session response.
#
# No network request: createSession already returns a didDoc carrying the
# #atproto_pds serviceEndpoint. Bots previously re-fetched this from either
# plc.directory or getSession, which was a redundant round-trip in both cases.
#
# Deliberately no fallback to plc.directory. A conditional fetch would make the
# captured request sequence depend on the response, which golden tests pin down
# poorly. If a PDS ever omits didDoc this fails loudly and gets revisited.
bsky_pds_host_from_session() {
    local session_json="$1"

    local endpoint
    endpoint=$(printf '%s' "$session_json" \
        | jq -r '.didDoc.service[]? | select(.id == "#atproto_pds") | .serviceEndpoint' \
        | head -1)

    if [ -z "$endpoint" ]; then
        return 1
    fi

    # Strip scheme and any trailing slash, leaving a bare host
    printf '%s' "$endpoint" | sed -e 's#^https\{0,1\}://##' -e 's#/$##'
    return 0
}

# Mint a service-scoped token.
#
# Video uploads need this rather than the ordinary session token, and the
# audience has to be the account's own PDS rather than the video host. The
# lexicon method is uploadBlob even though the call goes to uploadVideo.
bsky_service_auth() {
    local access_jwt="$1"
    local aud="$2"
    local lxm="$3"

    local response
    response=$(curl -s -f -G \
        -H "Authorization: Bearer ${access_jwt}" \
        --data-urlencode "aud=${aud}" \
        --data-urlencode "lxm=${lxm}" \
        "${BLUESKY_SERVER}/xrpc/com.atproto.server.getServiceAuth") || return 1

    local token
    token=$(printf '%s' "$response" | jq -r '.token // empty')

    if [ -z "$token" ]; then
        return 1
    fi

    add_redaction "$token"

    printf '%s' "$token"
    return 0
}

# Upload a blob to the account's own PDS, returning the blob JSON.
#
# Used for images and for WebVTT captions. Video does not come through here:
# it goes to the video host and is transcoded asynchronously.
bsky_upload_blob() {
    local pds_host="$1"
    local jwt="$2"
    local mime="$3"
    local file="$4"

    local response
    response=$(curl -s -f -X POST \
        "https://${pds_host}/xrpc/com.atproto.repo.uploadBlob" \
        -H "Authorization: Bearer ${jwt}" \
        -H "Content-Type: ${mime}" \
        --data-binary "@${file}") || return 1

    local blob
    blob=$(printf '%s' "$response" | jq -c '.blob // empty')

    if [ -z "$blob" ]; then
        return 1
    fi

    printf '%s' "$blob"
    return 0
}

# Queue a video for transcoding, returning the job id.
#
# The response body is kept on failure rather than discarded with -f: this
# endpoint explains auth problems in the body, and the caller needs to see it.
# A successful upload reports the job at the top level, an already-running one
# under jobStatus, so both shapes are accepted.
bsky_upload_video() {
    local did="$1"
    local jwt="$2"
    local name="$3"
    local file="$4"

    local response
    response=$(curl -s -X POST \
        "${BLUESKY_VIDEO_SERVER}/xrpc/app.bsky.video.uploadVideo?did=${did}&name=$(jq -rn --arg n "$name" '$n|@uri')" \
        -H "Authorization: Bearer ${jwt}" \
        -H "Content-Type: video/mp4" \
        --data-binary "@${file}") || return 1

    local job_id
    job_id=$(printf '%s' "$response" | jq -r '.jobId // .jobStatus.jobId // empty')

    if [ -z "$job_id" ]; then
        return 1
    fi

    printf '%s' "$job_id"
    return 0
}

# Wait for transcoding, echoing the blob JSON once the job reports success
bsky_await_video() {
    local job_id="$1"
    local jwt="${2-}"
    local attempt=0
    local job_json state

    local auth=()
    if [ -n "$jwt" ]; then
        auth=(-H "Authorization: Bearer ${jwt}")
    fi

    while [ "$attempt" -lt "$BSKY_POLL_ATTEMPTS" ]; do
        attempt=$(( attempt + 1 ))

        job_json=$(curl -s -f "${auth[@]}" \
            "${BLUESKY_VIDEO_SERVER}/xrpc/app.bsky.video.getJobStatus?jobId=${job_id}") || return 1

        state=$(printf '%s' "$job_json" | jq -r '.jobStatus.state // empty')

        if [ "$state" = "JOB_STATE_COMPLETED" ]; then
            printf '%s' "$job_json" | jq -c '.jobStatus.blob'
            return 0
        fi

        if [ "$state" = "JOB_STATE_FAILED" ]; then
            return 1
        fi

        sleep "$BSKY_POLL_DELAY"
    done

    return 1
}

# Create a record, returning the response JSON.
#
# `repo` is a parameter rather than resolved internally because the bots
# disagree about it: most send the DID, but at least one sends the handle. Both
# work against the live API, and forcing the DID here would change what those
# bots send -- which is a deliberate fix for a later commit, not a side effect
# of moving to this library.
bsky_create_record() {
    local repo="$1"
    local jwt="$2"
    local record="$3"

    local body
    body=$(jq -n \
        --arg repo "$repo" \
        --argjson record "$record" \
        '{repo: $repo, collection: "app.bsky.feed.post", record: $record}') || return 1

    local response
    response=$(curl -s -f -X POST \
        "${BLUESKY_SERVER}/xrpc/com.atproto.repo.createRecord" \
        -H "Authorization: Bearer ${jwt}" \
        -H "Content-Type: application/json" \
        -d "$body") || return 1

    # A record that posted has a uri; anything else is a failure that returned
    # 200, which does happen
    if ! printf '%s' "$response" | jq -e '.uri' > /dev/null 2>&1; then
        return 1
    fi

    printf '%s' "$response"
    return 0
}
