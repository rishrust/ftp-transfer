#!/usr/bin/env bash

# ========= USAGE =========
# ps_install_parallel.sh <link> [filename] [ip] [port] [path]
# Parallel download + sequential upload for PS4 PKG files
# ========================

# ========= CONFIGURATION =========
# Chunk size for download/upload (in bytes)
readonly CHUNK_SIZE=$((50 * 1024 * 1024))  # 50MB

# Parallel settings
readonly MAX_PARALLEL_DOWNLOADS=3  # Number of concurrent downloads
readonly MAX_CACHED_CHUNKS=5       # Max chunks to keep in cache (storage limit)
readonly UPLOAD_CHECK_INTERVAL=1   # Seconds between upload queue checks
readonly DOWNLOAD_TIMEOUT=300      # Max seconds to wait for a chunk (5 min)

# Retry settings
readonly MAX_RETRIES=5          # Max retries per chunk before aborting
readonly CURL_RETRIES=3         # Curl internal retries
readonly CURL_RETRY_DELAY=3     # Delay between curl retries (seconds)
readonly RETRY_SLEEP=2          # Sleep between script retries (seconds)

# Timeout settings
readonly CURL_TIMEOUT=10        # Timeout for header/validation requests (seconds)

# Default FTP settings
readonly DEFAULT_IP="192.168.0.110"
readonly DEFAULT_PORT="2121"
readonly DEFAULT_REMOTE_PATH="/data/pkg/"
readonly DEFAULT_FILENAME="download.pkg"

# ========= ARGUMENTS =========
if [ "$#" -lt 1 ]; then
    echo "Usage: ps_install_parallel.sh <link> [filename] [ip] [port] [path]"
    exit 1
fi

LINK="$1"
IP="${3:-$DEFAULT_IP}"
PORT="${4:-$DEFAULT_PORT}"
REMOTE_PATH="${5:-$DEFAULT_REMOTE_PATH}"

# Note: DOWNLOAD_DIR will be set after FILENAME is determined

# ========= UTILITY FUNCTIONS =========

# Portable file locking (works on macOS and Linux)
with_lock() {
    local lockfile="$1"
    local lockdir="${lockfile}.lock"
    shift
    
    local retry=0
    while ! mkdir "$lockdir" 2>/dev/null && [ $retry -lt 50 ]; do
        sleep 0.1
        retry=$((retry + 1))
    done
    
    if [ $retry -ge 50 ]; then
        echo "Warning: Lock timeout on $lockfile" >&2
        return 1
    fi
    
    # Execute the command
    eval "$@"
    local result=$?
    
    # Release lock
    rmdir "$lockdir" 2>/dev/null
    
    return $result
}

# Get remote file size via FTP
get_remote_size() {
    local url="$1"
    curl -sI --max-time "$CURL_TIMEOUT" "$url" 2>/dev/null | \
        grep -i "Content-Length" | awk '{print $2}' | tr -d '\r'
}

# Validate and get info from download URL
get_url_info() {
    local url="$1"
    curl -sI -L --max-time "$CURL_TIMEOUT" "$url" 2>&1
}

# Download a chunk with range (with retries)
download_chunk() {
    local chunk_id=$1
    local start=$2
    local end=$3
    local file="$DOWNLOAD_DIR/chunk_${chunk_id}.tmp"
    local retry=0
    
    while [ $retry -lt $MAX_RETRIES ]; do
        echo "[DL-$chunk_id] Downloading bytes $start-$end... (attempt $((retry+1))/$MAX_RETRIES)"
        
        if curl -L --fail --retry "$CURL_RETRIES" --retry-delay "$CURL_RETRY_DELAY" \
                --range "$start-$end" -o "$file" "$LINK" 2>/dev/null; then
            
            local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
            
            # Validate download (not 0 bytes, not HTML error)
            if [ "$size" -eq 0 ]; then
                echo "[DL-$chunk_id] ⚠️ Downloaded 0 bytes, retrying..."
                retry=$((retry+1))
                sleep $RETRY_SLEEP
                continue
            fi
            
            echo "[DL-$chunk_id] ✅ Downloaded $size bytes"
            
            # Mark as downloaded atomically
            with_lock "$CHUNK_STATE_FILE" "echo 'downloaded:$chunk_id:$size' >> '$CHUNK_STATE_FILE'"
            
            # Reset failure counter on successful download
            reset_download_failures
            return 0
        else
            echo "[DL-$chunk_id] ❌ Download failed"
            retry=$((retry+1))
            [ $retry -lt $MAX_RETRIES ] && sleep $RETRY_SLEEP
        fi
    done
    
    # Mark as failed after all retries
    echo "[DL-$chunk_id] ❌ FAILED after $MAX_RETRIES attempts"
    with_lock "$FAILED_CHUNKS_FILE" "echo '$chunk_id' >> '$FAILED_CHUNKS_FILE'"
    return 1
}

# Upload chunk to FTP with verification
upload_chunk() {
    local chunk_id=$1
    local file="$DOWNLOAD_DIR/chunk_${chunk_id}.tmp"
    local is_first=$2
    local expected_remote_size=$3
    
    if [ ! -f "$file" ]; then
        echo "[UP-$chunk_id] ⚠️ File not in cache, re-downloading..."
        # Re-download the missing chunk
        local start_byte=$((chunk_id * CHUNK_SIZE))
        local end_byte=$((start_byte + CHUNK_SIZE - 1))
        
        if ! download_chunk $chunk_id $start_byte $end_byte; then
            echo "[UP-$chunk_id] ❌ Failed to re-download chunk"
            return 1
        fi
    fi
    
    local file_size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
    
    if [ "$is_first" = true ]; then
        echo "[UP-$chunk_id] ⬆️ Creating file on PS4..."
        curl --globoff --ftp-method nocwd -T "$file" "$FTP_URL" 2>/dev/null
    else
        echo "[UP-$chunk_id] ⬆️ Appending to PS4..."
        curl --globoff --ftp-method nocwd --append -T "$file" "$FTP_URL" 2>/dev/null
    fi
    
    local result=$?
    if [ $result -ne 0 ]; then
        echo "[UP-$chunk_id] ❌ Upload failed (curl error)"
        return 1
    fi
    
    # CRITICAL: Verify upload succeeded
    local actual_size=$(get_remote_size "$FTP_URL")
    local expected_after=$((expected_remote_size + file_size))
    
    if [ -n "$actual_size" ] && [ "$actual_size" != "$expected_after" ]; then
        echo "[UP-$chunk_id] ❌ Size verification FAILED! Expected $expected_after, got $actual_size"
        return 1
    fi
    
    echo "[UP-$chunk_id] ✅ Upload verified ($actual_size bytes total)"
    
    # Mark as uploaded and delete chunk file to free storage
    mark_chunk_uploaded $chunk_id
    
    # Update stable checkpoint - this is now a verified stable state
    update_stable_checkpoint $chunk_id $actual_size
    
    rm -f "$file"
    echo "[UP-$chunk_id] 🗑️ Deleted from cache (freed $(( file_size / 1024 / 1024 ))MB)"
    
    return 0
}

# Check how many downloads are active
count_active_downloads() {
    if [ ! -f "$ACTIVE_DOWNLOADS_FILE" ]; then
        echo "0"
        return
    fi
    local count=$(wc -l < "$ACTIVE_DOWNLOADS_FILE" 2>/dev/null | tr -d ' ')
    echo "${count:-0}"
}

# Register active download
register_download() {
    local chunk_id=$1
    with_lock "$ACTIVE_DOWNLOADS_FILE" "echo '$chunk_id' >> '$ACTIVE_DOWNLOADS_FILE'"
}

# Unregister download
unregister_download() {
    local chunk_id=$1
    with_lock "$ACTIVE_DOWNLOADS_FILE" "grep -v '^${chunk_id}\$' '$ACTIVE_DOWNLOADS_FILE' > '${ACTIVE_DOWNLOADS_FILE}.tmp' 2>/dev/null && mv '${ACTIVE_DOWNLOADS_FILE}.tmp' '$ACTIVE_DOWNLOADS_FILE' 2>/dev/null || true"
}

# Check if chunk is downloaded
is_chunk_downloaded() {
    local chunk_id=$1
    grep -q "^downloaded:${chunk_id}:" "$CHUNK_STATE_FILE" 2>/dev/null
}

# Check if chunk has failed
is_chunk_failed() {
    local chunk_id=$1
    grep -q "^${chunk_id}$" "$FAILED_CHUNKS_FILE" 2>/dev/null
}

# Get chunk size from state
get_chunk_size() {
    local chunk_id=$1
    grep "^downloaded:${chunk_id}:" "$CHUNK_STATE_FILE" 2>/dev/null | cut -d: -f3 | tr -d '\n\r '
}

# Count actual cached chunk files (for storage management)
count_cached_chunks() {
    ls -1 "$DOWNLOAD_DIR"/chunk_*.tmp 2>/dev/null | wc -l | tr -d ' '
}

# Mark chunk as uploaded (to avoid re-upload on resume)
mark_chunk_uploaded() {
    local chunk_id=$1
    with_lock "$CHUNK_STATE_FILE" "echo 'uploaded:$chunk_id' >> '$CHUNK_STATE_FILE'"
}

# Check if chunk was already uploaded
is_chunk_uploaded() {
    local chunk_id=$1
    grep -q "^uploaded:${chunk_id}$" "$CHUNK_STATE_FILE" 2>/dev/null
}

# Prompt user for new download URL
prompt_for_new_url() {
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "⚠️  DOWNLOAD URL EXPIRED OR UNREACHABLE"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "The download link is no longer working. This commonly happens with:"
    echo "  - Temporary file sharing links that have expired"
    echo "  - Network/DNS issues"
    echo "  - Server maintenance"
    echo ""
    echo "Current progress:"
    echo "  ✅ Uploaded to PS4: $(grep -c '^uploaded:' "$CHUNK_STATE_FILE" 2>/dev/null || echo 0) chunks"
    echo "  📦 Cached locally: $(ls -1 "$DOWNLOAD_DIR"/chunk_*.tmp 2>/dev/null | wc -l | tr -d ' ') chunks"
    echo "  ⏸️  All cached chunks will be uploaded before pausing"
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo ""
    read -p "Enter new download URL (or press Ctrl+C to abort): " NEW_URL
    echo ""  
    
    if [ -z "$NEW_URL" ]; then
        echo "❌ No URL provided. Exiting..."
        exit 1
    fi
    
    # Validate new URL
    echo "🔍 Validating new URL..."
    if curl -sI -L --max-time "$CURL_TIMEOUT" "$NEW_URL" >/dev/null 2>&1; then
        echo "✅ New URL is reachable"
        LINK="$NEW_URL"
        echo "$NEW_URL" > "$URL_FILE"
        echo "0" > "$URL_FAILED_FILE"
        return 0
    else
        echo "⚠️ Cannot validate new URL (network error). Will try anyway..."
        LINK="$NEW_URL"
        echo "$NEW_URL" > "$URL_FILE"
        echo "0" > "$URL_FAILED_FILE"
        return 0
    fi
}

# Track consecutive download failures to detect URL expiration
track_download_failure() {
    local current=$(cat "$URL_FAILED_FILE" 2>/dev/null || echo "0")
    local new_count=$((current + 1))
    echo "$new_count" > "$URL_FAILED_FILE"
    echo "$new_count"
}

# Reset download failure counter on success
reset_download_failures() {
    echo "0" > "$URL_FAILED_FILE"
}

# Update stable checkpoint after successful verified upload
update_stable_checkpoint() {
    local chunk_id=$1
    local byte_position=$2
    echo "${chunk_id}:${byte_position}" > "$DOWNLOAD_DIR/stable_checkpoint.txt"
}

# Get last stable checkpoint (returns chunk_id:byte_position)
get_stable_checkpoint() {
    if [ -f "$DOWNLOAD_DIR/stable_checkpoint.txt" ]; then
        cat "$DOWNLOAD_DIR/stable_checkpoint.txt"
    else
        echo "0:0"  # No checkpoint yet
    fi
}

# Handle fatal error
fatal_error() {
    echo "❌ $1"
    [ -n "$2" ] && echo "   $2"
    cleanup_error
    exit 1
}

# Cleanup only on success
cleanup_success() {
    echo "🧹 Cleaning up..."
    rm -rf "$DOWNLOAD_DIR"
}

# Cleanup on error (preserve chunks for resume)
cleanup_error() {
    echo "⚠️ Interrupted - preserving chunks for resume"
    # Kill any background downloads
    jobs -p | xargs -r kill 2>/dev/null
    wait 2>/dev/null
    echo "📂 Chunks saved in: $DOWNLOAD_DIR"
    echo "   Run script again to resume"
}

trap cleanup_error INT TERM

# ========= FILENAME DETECTION =========
if [ -n "$2" ]; then
    FILENAME="$2"
    echo "📦 Using provided filename: $FILENAME"
else
    echo "🔍 Detecting filename..."
    FILENAME=$(get_url_info "$LINK" | grep -i "Content-Disposition" | \
               sed -n 's/.*filename="\([^"]*\)".*/\1/p')

    if [ -z "$FILENAME" ]; then
        FINAL_URL=$(curl -Ls --max-time "$CURL_TIMEOUT" -o /dev/null -w %{url_effective} "$LINK")
        FILENAME=$(basename "$FINAL_URL")
    fi

    if [ -z "$FILENAME" ]; then
        echo "⚠️ Could not detect filename. Using default..."
        FILENAME="$DEFAULT_FILENAME"
    fi
fi

[[ "$FILENAME" != *.* ]] && FILENAME="$FILENAME.pkg"

# ========= INITIALIZE CHUNK STORAGE =========
# Create consistent directory based on filename (for resume capability)
# Use MD5 or simple sanitization to create safe directory name
SAFE_NAME=$(echo "$FILENAME" | tr -cd '[:alnum:]._-' | cut -c1-50)
DOWNLOAD_DIR=".ps4_chunks_${SAFE_NAME}"

# Create directory if it doesn't exist
if [ ! -d "$DOWNLOAD_DIR" ]; then
    mkdir -p "$DOWNLOAD_DIR"
    echo "📁 Created new chunk directory: $DOWNLOAD_DIR"
else
    echo "📁 Using existing chunk directory: $DOWNLOAD_DIR"
fi

# Chunk tracking files
CHUNK_STATE_FILE="$DOWNLOAD_DIR/chunk_state.dat"
ACTIVE_DOWNLOADS_FILE="$DOWNLOAD_DIR/active_downloads.dat"
NEXT_UPLOAD_FILE="$DOWNLOAD_DIR/next_upload.dat"
FAILED_CHUNKS_FILE="$DOWNLOAD_DIR/failed_chunks.dat"
CHUNK_WAIT_START="$DOWNLOAD_DIR/wait_start.dat"
URL_FILE="$DOWNLOAD_DIR/download_url.txt"
URL_FAILED_FILE="$DOWNLOAD_DIR/url_failed.dat"

# Initialize state files only if they don't exist (preserve on resume)
[ ! -f "$CHUNK_STATE_FILE" ] && > "$CHUNK_STATE_FILE"
[ ! -f "$ACTIVE_DOWNLOADS_FILE" ] && > "$ACTIVE_DOWNLOADS_FILE"
[ ! -f "$FAILED_CHUNKS_FILE" ] && > "$FAILED_CHUNKS_FILE"
[ ! -f "$NEXT_UPLOAD_FILE" ] && echo "0" > "$NEXT_UPLOAD_FILE"
[ ! -f "$URL_FAILED_FILE" ] && echo "0" > "$URL_FAILED_FILE"

# Save/restore URL
if [ -f "$URL_FILE" ]; then
    SAVED_URL=$(cat "$URL_FILE")
    if [ -n "$SAVED_URL" ] && [ "$SAVED_URL" != "$LINK" ]; then
        echo "ℹ️  Found saved URL in state (using new URL from command line)"
    fi
fi
echo "$LINK" > "$URL_FILE"

FTP_URL="ftp://$IP:$PORT$REMOTE_PATH$FILENAME"

echo "📡 Target: $IP:$PORT$REMOTE_PATH"
echo "📦 File: $FILENAME"
echo "⚡ Parallel downloads: $MAX_PARALLEL_DOWNLOADS"

# ========= URL VALIDATION =========
echo "🔍 Validating download URL..."
URL_INFO=$(get_url_info "$LINK")
HTTP_CODE=$(echo "$URL_INFO" | tail -1 | awk '{print $2}')

if [ -z "$HTTP_CODE" ]; then
    echo "⚠️ Could not validate URL (network error). Proceeding anyway..."
    TOTAL_SIZE=0
elif [ "$HTTP_CODE" -ge 400 ]; then
    fatal_error "Download URL validation failed (HTTP $HTTP_CODE)" \
                "URL may be invalid, expired, or server unavailable"
else
    echo "✅ URL valid (HTTP $HTTP_CODE)"
    TOTAL_SIZE=$(echo "$URL_INFO" | grep -i "Content-Length" | awk '{print $2}' | tr -d '\r')
    
    if [ -z "$TOTAL_SIZE" ]; then
        echo "⚠️ Could not determine total file size. Proceeding anyway..."
        TOTAL_SIZE=0
    else
        echo "📊 Total file size: $TOTAL_SIZE bytes"
        TOTAL_CHUNKS=$(( (TOTAL_SIZE + CHUNK_SIZE - 1) / CHUNK_SIZE ))
        echo "📦 Total chunks: $TOTAL_CHUNKS"
    fi
fi

# ========= RESUME LOGIC =========
echo "🔍 Checking existing file on PS4..."
REMOTE_SIZE=$(get_remote_size "$FTP_URL")

# Count how many chunks were already uploaded (from state file)
UPLOADED_COUNT=$(grep -c "^uploaded:" "$CHUNK_STATE_FILE" 2>/dev/null | tr -d '\n\r ' || echo "0")
UPLOADED_COUNT=${UPLOADED_COUNT:-0}

if [ -z "$REMOTE_SIZE" ] || [ "$REMOTE_SIZE" = "0" ]; then
    echo "No existing file. Starting fresh."
    REMOTE_SIZE=0
    START_CHUNK=0
    FIRST_UPLOAD=true
else
    echo "Found existing file: $REMOTE_SIZE bytes"
    REMAINDER=$((REMOTE_SIZE % CHUNK_SIZE))
    COMPLETE_CHUNKS=$((REMOTE_SIZE / CHUNK_SIZE))
    EXPECTED_SIZE=$((UPLOADED_COUNT * CHUNK_SIZE))
    
    if [ $REMAINDER -ne 0 ]; then
        # Partial chunk detected - could be last chunk or corruption
        echo "⚠️ Partial chunk detected! File has $REMAINDER bytes into incomplete chunk $COMPLETE_CHUNKS"
        
        # Get last stable checkpoint
        STABLE_CHECKPOINT=$(get_stable_checkpoint)
        STABLE_CHUNK=$(echo "$STABLE_CHECKPOINT" | cut -d: -f1)
        STABLE_BYTES=$(echo "$STABLE_CHECKPOINT" | cut -d: -f2)
        
        echo "📍 Last stable checkpoint: chunk $STABLE_CHUNK at $STABLE_BYTES bytes"
        
        # Check if remote size matches stable checkpoint - if so, file is COMPLETE (not corrupted)
        if [ "$REMOTE_SIZE" = "$STABLE_BYTES" ]; then
            echo "✅ File is COMPLETE! Last chunk is $REMAINDER bytes (smaller than standard chunk size)"
            echo "🎉 All $((COMPLETE_CHUNKS + 1)) chunks verified on PS4"
            
            # Set total size if not known and exit successfully
            TOTAL_SIZE=${TOTAL_SIZE:-0}
            [ "$TOTAL_SIZE" -eq 0 ] && TOTAL_SIZE=$REMOTE_SIZE
            cleanup_success
            exit 0
        fi
        
        # If we get here, it's actual corruption (remote != stable checkpoint)
        echo "⚠️ Remote size ($REMOTE_SIZE) differs from stable checkpoint ($STABLE_BYTES) - corruption detected"
        
        # Check if we can restore to stable checkpoint
        CHUNKS_NEEDED=$((STABLE_CHUNK + 1))  # Need chunks 0 to STABLE_CHUNK
        CHUNKS_IN_CACHE=$(ls -1 "$DOWNLOAD_DIR"/chunk_*.tmp 2>/dev/null | wc -l | tr -d ' ')
        CHUNKS_IN_CACHE=${CHUNKS_IN_CACHE:-0}
        
        if [ $CHUNKS_NEEDED -gt 0 ] && [ $CHUNKS_IN_CACHE -lt $CHUNKS_NEEDED ]; then
            echo "❌ CANNOT RECOVER: Need $CHUNKS_NEEDED chunks to restore to stable checkpoint, but only have $CHUNKS_IN_CACHE in cache"
            echo "   Remote: $REMOTE_SIZE bytes (corrupted)"
            echo "   Stable: $STABLE_BYTES bytes (last verified good state)"
            echo "   Loss if we proceed: $((REMOTE_SIZE - STABLE_BYTES)) bytes"
            echo ""
            echo "   OPTIONS:"
            echo "   1. Keep corrupted file (${REMOTE_SIZE} bytes) - manual fix needed"
            echo "   2. Delete and restart completely"
            echo ""
            fatal_error "Cannot recover - insufficient cache to restore to stable checkpoint"
        fi
        
        # We can restore to stable checkpoint
        echo "✅ Cache check: Have $CHUNKS_IN_CACHE chunks, need $CHUNKS_NEEDED - can restore to stable checkpoint"
        echo "🔄 Deleting corrupted remote file and restoring to last stable state ($STABLE_BYTES bytes)..."
        
        curl -s -Q "DELE $REMOTE_PATH$FILENAME" "ftp://$IP:$PORT/" 2>/dev/null
        
        # Remote file deleted - restore to stable checkpoint
        REMOTE_SIZE=0
        START_CHUNK=0
        FIRST_UPLOAD=true
        
        echo "♻️ Will restore to stable checkpoint:"
        echo "   - Re-upload chunks 0-$STABLE_CHUNK from cache"
        echo "   - Continue downloads from last point"
        echo "   - Lost data: $((REMOTE_SIZE - STABLE_BYTES)) bytes (only corrupted portion)"
        
    elif [ "$REMOTE_SIZE" = "$EXPECTED_SIZE" ]; then
        # Perfect match - continue from next chunk
        START_CHUNK=$UPLOADED_COUNT
        FIRST_UPLOAD=false
        echo "✅ File matches uploaded chunks. Safe to resume."
        echo "🚀 Resuming from chunk $START_CHUNK (byte $REMOTE_SIZE)"
    else
        # Mismatch - something wrong
        echo "⚠️ Remote size ($REMOTE_SIZE) doesn't match expected ($EXPECTED_SIZE based on $UPLOADED_COUNT uploaded chunks)"
        
        # Get last stable checkpoint
        STABLE_CHECKPOINT=$(get_stable_checkpoint)
        STABLE_CHUNK=$(echo "$STABLE_CHECKPOINT" | cut -d: -f1)
        STABLE_BYTES=$(echo "$STABLE_CHECKPOINT" | cut -d: -f2)
        
        echo "📍 Last stable checkpoint: chunk $STABLE_CHUNK at $STABLE_BYTES bytes"
        
        # Check if remote matches stable checkpoint - file might be complete despite state file mismatch
        if [ "$REMOTE_SIZE" = "$STABLE_BYTES" ]; then
            echo "✅ File matches stable checkpoint! Transfer is COMPLETE."
            echo "🎉 All chunks verified on PS4 ($(( (REMOTE_SIZE + CHUNK_SIZE - 1) / CHUNK_SIZE )) chunks, $REMOTE_SIZE bytes)"
            
            # Set total size if not known and exit successfully
            TOTAL_SIZE=${TOTAL_SIZE:-0}
            [ "$TOTAL_SIZE" -eq 0 ] && TOTAL_SIZE=$REMOTE_SIZE
            cleanup_success
            exit 0
        fi
        
        # If we get here, it's actual corruption
        echo "⚠️ Remote size differs from both expected and stable checkpoint - corruption detected"
        
        # Check if we can restore to stable checkpoint instead of losing everything
        CHUNKS_NEEDED=$((STABLE_CHUNK + 1))
        CHUNKS_IN_CACHE=$(ls -1 "$DOWNLOAD_DIR"/chunk_*.tmp 2>/dev/null | wc -l | tr -d ' ')
        CHUNKS_IN_CACHE=${CHUNKS_IN_CACHE:-0}
        
        if [ $CHUNKS_NEEDED -gt 0 ] && [ $CHUNKS_IN_CACHE -lt $CHUNKS_NEEDED ]; then
            echo "❌ CANNOT RECOVER: Need $CHUNKS_NEEDED chunks to restore to stable checkpoint, but only have $CHUNKS_IN_CACHE in cache"
            echo ""
            echo "   Current situation:"
            echo "   - Remote file: ${REMOTE_SIZE} bytes (corrupted)"
            echo "   - Expected: ${EXPECTED_SIZE} bytes"
            echo "   - Last stable: ${STABLE_BYTES} bytes"
            echo "   - Cached chunks: ${CHUNKS_IN_CACHE}"
            echo ""
            echo "   To fix manually:"
            echo "   1. Delete remote file on PS4 via FTP client"
            echo "   2. Run script again to start fresh"
            echo ""
            fatal_error "Cannot recover - insufficient cache to restore to stable checkpoint"
        fi
        
        echo "✅ Cache check: Have $CHUNKS_IN_CACHE chunks, need $CHUNKS_NEEDED - can restore to stable checkpoint"
        echo "🔄 Deleting corrupted file and restoring to last stable state ($STABLE_BYTES bytes)..."
        
        curl -s -Q "DELE $REMOTE_PATH$FILENAME" "ftp://$IP:$PORT/" 2>/dev/null
        
        # Restore to stable checkpoint
        REMOTE_SIZE=0
        START_CHUNK=0
        FIRST_UPLOAD=true
        
        echo "♻️ Restoring to stable checkpoint (chunk $STABLE_CHUNK, $STABLE_BYTES bytes)"
        echo "   Lost: $((REMOTE_SIZE - STABLE_BYTES)) bytes of unstable data"
        echo "   Will re-upload chunks 0-$STABLE_CHUNK from cache"
    fi
fi

echo "$START_CHUNK" > "$NEXT_UPLOAD_FILE"

# ========= PARALLEL DOWNLOAD & UPLOAD LOOP =========
echo ""
echo "🚀 Starting parallel download/upload..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

CURRENT_CHUNK=$START_CHUNK
DOWNLOADS_STARTED=0
UPLOAD_COUNT=0

# Background download worker
start_download() {
    local chunk_id=$1
    local start_byte=$(( chunk_id * CHUNK_SIZE ))
    local end_byte=$(( start_byte + CHUNK_SIZE - 1 ))
    
    # Skip if already downloaded
    if is_chunk_downloaded $chunk_id; then
        echo "[DL-$chunk_id] Already downloaded, skipping"
        return
    fi
    
    register_download $chunk_id
    
    (
        download_chunk $chunk_id $start_byte $end_byte
        unregister_download $chunk_id
    ) &
}

# Main parallel loop
while true; do
    # Check cache size limit  
    CACHED_COUNT=$(count_cached_chunks)
    CACHED_COUNT=${CACHED_COUNT:-0}
    
    # Start new downloads if slots available AND cache not full (unless URL expired)
    if [ "${URL_EXPIRED:-false}" = "false" ]; then
    ACTIVE_COUNT=$(count_active_downloads)
    ACTIVE_COUNT=${ACTIVE_COUNT:-0}
    while [ "$ACTIVE_COUNT" -lt "$MAX_PARALLEL_DOWNLOADS" ] && [ "$CACHED_COUNT" -lt "$MAX_CACHED_CHUNKS" ]; do
        # Check if we've started all chunks
        if [ $TOTAL_SIZE -gt 0 ] && [ $CURRENT_CHUNK -ge $TOTAL_CHUNKS ]; then
            break
        fi
        
        # Check if we should stop (estimated end based on size)
        START_BYTE=$(( CURRENT_CHUNK * CHUNK_SIZE ))
        if [ $TOTAL_SIZE -gt 0 ] && [ $START_BYTE -ge $TOTAL_SIZE ]; then
            break
        fi
        
        echo "[START] Initiating download of chunk $CURRENT_CHUNK"
        start_download $CURRENT_CHUNK
        DOWNLOADS_STARTED=$((DOWNLOADS_STARTED + 1))
        CURRENT_CHUNK=$((CURRENT_CHUNK + 1))
        
        sleep 0.2  # Brief delay to avoid overwhelming server
        
        # Refresh counts for next iteration
        ACTIVE_COUNT=$(count_active_downloads)
        ACTIVE_COUNT=${ACTIVE_COUNT:-0}
        CACHED_COUNT=$(count_cached_chunks)
        CACHED_COUNT=${CACHED_COUNT:-0}
    done
    fi  # End URL_EXPIRED check
    
    # Check for URL expiration before attempting downloads
    FAILURE_COUNT=$(cat "$URL_FAILED_FILE" 2>/dev/null || echo "0")
    if [ "$FAILURE_COUNT" -ge 3 ]; then
        echo ""
        echo "⏸️  URL appears to be expired. Finishing uploads from cache first..."
        
        # Wait for all active downloads to complete (they will fail)
        while [ $(count_active_downloads) -gt 0 ]; do
            echo "⏳ Waiting for active downloads to finish..."
            sleep 2
        done
        
        # Upload remaining cached chunks
        echo "⬆️  Uploading all cached chunks before requesting new URL..."
        
        # Continue upload loop but skip download attempts
        URL_EXPIRED=true
    fi
    
    # Process uploads sequentially
    NEXT_UPLOAD=$(cat "$NEXT_UPLOAD_FILE")
    
    # Check if chunk has failed permanently (non-URL failures)
    if is_chunk_failed $NEXT_UPLOAD; then
        FAILURE_COUNT=$(cat "$URL_FAILED_FILE" 2>/dev/null || echo "0")
        
        if [ "$FAILURE_COUNT" -ge 3 ]; then
            # URL expired - ask for new one
            echo ""
            echo "📤 All cached chunks uploaded. Downloads paused."
            prompt_for_new_url
            
            # Clear failed chunks and retry
            > "$FAILED_CHUNKS_FILE"
            URL_EXPIRED=false
            continue
        else
            fatal_error "Chunk $NEXT_UPLOAD failed permanently after all retries" \
                       "Cannot continue. Fix network issues and restart."
        fi
    fi
    
    # Check if chunk was already uploaded AND remote file still exists
    # (Skip optimization only works if remote file wasn't deleted)
    if is_chunk_uploaded $NEXT_UPLOAD && [ "$REMOTE_SIZE" -gt 0 ]; then
        # Get current remote size to verify
        ACTUAL_REMOTE=$(get_remote_size "$FTP_URL")
        ACTUAL_REMOTE=${ACTUAL_REMOTE:-0}
        
        # Only skip if remote file matches expected size
        if [ "$ACTUAL_REMOTE" = "$REMOTE_SIZE" ]; then
            CHUNK_SIZE_ACTUAL=$(get_chunk_size $NEXT_UPLOAD)
            CHUNK_SIZE_ACTUAL=${CHUNK_SIZE_ACTUAL:-0}
            
            if [ "$CHUNK_SIZE_ACTUAL" -gt 0 ]; then
                echo "[SKIP-$NEXT_UPLOAD] Already on PS4 ($ACTUAL_REMOTE bytes), skipping..."
                REMOTE_SIZE=$((REMOTE_SIZE + CHUNK_SIZE_ACTUAL))
                UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
                
                # Move to next chunk
                NEXT_UPLOAD=$((NEXT_UPLOAD + 1))
                echo "$NEXT_UPLOAD" > "$NEXT_UPLOAD_FILE"
                FIRST_UPLOAD=false
                continue  # Skip to next iteration
            fi
        else
            # Remote size doesn't match - file was deleted or corrupted
            # Fall through to re-upload from cache
            echo "[UP-$NEXT_UPLOAD] Remote file changed, re-uploading from cache..."
        fi
    fi
    
    # Upload chunk (either not uploaded yet, or re-uploading from cache)
    if is_chunk_downloaded $NEXT_UPLOAD; then
        CHUNK_SIZE_ACTUAL=$(get_chunk_size $NEXT_UPLOAD)
        CHUNK_SIZE_ACTUAL=${CHUNK_SIZE_ACTUAL:-0}
        
        if [ -n "$CHUNK_SIZE_ACTUAL" ] && [ "$CHUNK_SIZE_ACTUAL" -gt 0 ]; then
            # Upload with verification
            RETRY_COUNT=0
            while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
                if upload_chunk $NEXT_UPLOAD $FIRST_UPLOAD $REMOTE_SIZE; then
                    FIRST_UPLOAD=false
                    REMOTE_SIZE=$((REMOTE_SIZE + CHUNK_SIZE_ACTUAL))
                    UPLOAD_COUNT=$((UPLOAD_COUNT + 1))
                    
                    # Clear wait timer on successful upload
                    rm -f "$CHUNK_WAIT_START"
                    
                    echo "[PROGRESS] Uploaded $UPLOAD_COUNT chunks ($REMOTE_SIZE bytes)"
                    
                    # Move to next chunk
                    NEXT_UPLOAD=$((NEXT_UPLOAD + 1))
                    echo "$NEXT_UPLOAD" > "$NEXT_UPLOAD_FILE"
                    
                    # Check if this was the last chunk
                    if [ "$CHUNK_SIZE_ACTUAL" -lt "$CHUNK_SIZE" ]; then
                        echo "✅ Last chunk uploaded!"
                        break 2
                    fi
                    
                    if [ $TOTAL_SIZE -gt 0 ] && [ $REMOTE_SIZE -ge $TOTAL_SIZE ]; then
                        echo "✅ Reached total file size!"
                        break 2
                    fi
                    
                    break
                else
                    RETRY_COUNT=$((RETRY_COUNT + 1))
                    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
                        fatal_error "Upload of chunk $NEXT_UPLOAD failed after $MAX_RETRIES attempts"
                    fi
                    echo "[UP-$NEXT_UPLOAD] Retrying... ($RETRY_COUNT/$MAX_RETRIES)"
                    sleep $RETRY_SLEEP
                fi
            done
        fi
    else
        # Chunk not ready - check for timeout
        if [ ! -f "$CHUNK_WAIT_START" ]; then
            date +%s > "$CHUNK_WAIT_START"
        else
            WAIT_START=$(cat "$CHUNK_WAIT_START")
            WAIT_NOW=$(date +%s)
            WAIT_DURATION=$((WAIT_NOW - WAIT_START))
            
            if [ $WAIT_DURATION -gt $DOWNLOAD_TIMEOUT ]; then
                fatal_error "Timeout waiting for chunk $NEXT_UPLOAD (waited ${WAIT_DURATION}s)" \
                           "Download may have stalled. Check network and restart."
            fi
            
            if [ $((WAIT_DURATION % 30)) -eq 0 ] && [ $WAIT_DURATION -gt 0 ]; then
                echo "[WAIT] Waiting for chunk $NEXT_UPLOAD... (${WAIT_DURATION}s/${DOWNLOAD_TIMEOUT}s)"
            fi
        fi
    fi
    
    # Check if all work is done
    ACTIVE=$(count_active_downloads)
    ACTIVE=${ACTIVE:-0}
    if [ "$ACTIVE" -eq 0 ]; then
        # No active downloads - check if next upload is available or if we're done
        if ! is_chunk_downloaded $NEXT_UPLOAD; then
            # Next chunk not available and no downloads running
            if [ $TOTAL_SIZE -gt 0 ] && [ $REMOTE_SIZE -ge $TOTAL_SIZE ]; then
                break
            elif [ $DOWNLOADS_STARTED -eq $NEXT_UPLOAD ]; then
                # We've started all downloads and nothing is active
                break
            fi
        fi
    fi
    
    sleep $UPLOAD_CHECK_INTERVAL
done

# Wait for any remaining background processes
wait

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ========= FINAL VERIFICATION =========
if [ "$TOTAL_SIZE" -gt 0 ]; then
    FINAL_REMOTE_SIZE=$(get_remote_size "$FTP_URL")
    if [ "$FINAL_REMOTE_SIZE" = "$TOTAL_SIZE" ]; then
        echo "✅ File size verified: $FINAL_REMOTE_SIZE bytes"
    else
        echo "⚠️ Warning: Remote size ($FINAL_REMOTE_SIZE) doesn't match expected ($TOTAL_SIZE)"
    fi
fi

# Cleanup on success
cleanup_success

echo "🏁 All done!"
echo "📊 Statistics:"
echo "   - Total chunks: $UPLOAD_COUNT"
echo "   - Total size: $REMOTE_SIZE bytes"
echo "   - Parallel downloads: $MAX_PARALLEL_DOWNLOADS"
