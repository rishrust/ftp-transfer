#!/usr/bin/env bash

# ========= USAGE =========
# ps_install_fixed.sh <link> [filename] [ip] [port] [path]
# ========================

# ========= CONFIGURATION =========
# Chunk size for download/upload (in bytes)
readonly CHUNK_SIZE=$((50 * 1024 * 1024))  # 50MB

# Retry settings
readonly MAX_RETRIES=5          # Max retries per chunk before aborting
readonly CURL_RETRIES=3         # Curl internal retries
readonly CURL_RETRY_DELAY=3     # Delay between curl retries (seconds)
readonly RETRY_SLEEP=2          # Sleep between script retries (seconds)
readonly DOWNLOAD_RETRY_SLEEP=3 # Sleep between download retries (seconds)

# Timeout settings
readonly CURL_TIMEOUT=10        # Timeout for header/validation requests (seconds)

# Default FTP settings
readonly DEFAULT_IP="192.168.0.110"
readonly DEFAULT_PORT="2121"
readonly DEFAULT_REMOTE_PATH="/data/pkg/"
readonly DEFAULT_FILENAME="download.pkg"

# ========= ARGUMENTS =========
if [ "$#" -lt 1 ]; then
    echo "Usage: ps_install_fixed.sh <link> [filename] [ip] [port] [path]"
    exit 1
fi

LINK="$1"
IP="${3:-$DEFAULT_IP}"
PORT="${4:-$DEFAULT_PORT}"
REMOTE_PATH="${5:-$DEFAULT_REMOTE_PATH}"

# ========= UTILITY FUNCTIONS =========

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

# Download a chunk with range
download_chunk() {
    local start=$1
    local end=$2
    local file=$3
    curl -L --fail --retry "$CURL_RETRIES" --retry-delay "$CURL_RETRY_DELAY" \
         --range "$start-$end" -o "$file" "$LINK"
}

# Upload chunk to FTP
upload_chunk() {
    local file=$1
    local is_first=$2
    
    if [ "$is_first" = true ]; then
        echo "⬆️ Uploading chunk $INDEX (creating file)..."
        curl --globoff --ftp-method nocwd -T "$file" "$FTP_URL"
    else
        echo "⬆️ Uploading chunk $INDEX (appending)..."
        curl --globoff --ftp-method nocwd --append -T "$file" "$FTP_URL"
    fi
}

# Handle fatal error with message
fatal_error() {
    echo "❌ $1"
    [ -n "$2" ] && echo "   $2"
    exit 1
}

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

# Ensure extension
[[ "$FILENAME" != *.* ]] && FILENAME="$FILENAME.pkg"

FTP_URL="ftp://$IP:$PORT$REMOTE_PATH$FILENAME"

echo "📡 Target: $IP:$PORT$REMOTE_PATH"
echo "📦 File: $FILENAME"

# Cleanup temp files
rm -f chunk_*.tmp

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
    fi
fi

# ========= RESUME LOGIC =========
echo "🔍 Checking existing file on PS4..."
REMOTE_SIZE=$(get_remote_size "$FTP_URL")

if [ -z "$REMOTE_SIZE" ] || [ "$REMOTE_SIZE" = "0" ]; then
    echo "No existing file. Starting fresh."
    REMOTE_SIZE=0
    INDEX=0
    FIRST_UPLOAD=true
    SKIP_TO=0
else
    echo "Found existing file: $REMOTE_SIZE bytes"
    REMAINDER=$((REMOTE_SIZE % CHUNK_SIZE))
    
    if [ $REMAINDER -ne 0 ]; then
        COMPLETE_SIZE=$((REMOTE_SIZE - REMAINDER))
        echo "⚠️ Partial chunk detected! File has $REMAINDER bytes into an incomplete chunk."
        echo "⚠️ This could cause corruption (likely from interrupted upload)."
        echo "🔄 Deleting remote file and restarting from byte $COMPLETE_SIZE to ensure integrity..."
        
        curl -s -Q "DELE $REMOTE_PATH$FILENAME" "ftp://$IP:$PORT/" 2>/dev/null
        
        REMOTE_SIZE=0
        INDEX=0
        FIRST_UPLOAD=true
        SKIP_TO=$COMPLETE_SIZE
    else
        INDEX=$((REMOTE_SIZE / CHUNK_SIZE))
        FIRST_UPLOAD=false
        SKIP_TO=0
        echo "✅ File aligned to chunk boundary. Safe to resume."
        echo "🚀 Resuming from byte: $REMOTE_SIZE (chunk $INDEX)"
    fi
fi

# ========= MAIN TRANSFER LOOP =========
RETRY_COUNT=0

while true; do
    CUR_FILE="chunk_$INDEX.tmp"
    START=$REMOTE_SIZE
    END=$((START + CHUNK_SIZE - 1))
    
    # Display download status
    if [ $SKIP_TO -gt 0 ]; then
        if [ $REMOTE_SIZE -ge $SKIP_TO ]; then
            echo "✅ Recovery complete. Continuing from byte $REMOTE_SIZE..."
            SKIP_TO=0
        else
            echo "⬇️ Re-downloading chunk $INDEX ($START - $END) [Recovery: $REMOTE_SIZE/$SKIP_TO bytes]"
        fi
    else
        echo "⬇️ Downloading chunk $INDEX ($START - $END)..."
    fi

    # Download chunk
    download_chunk $START $END "$CUR_FILE"
    DOWNLOAD_STATUS=$?

    # Handle download errors
    if [ $DOWNLOAD_STATUS -ne 0 ]; then
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            if [ $DOWNLOAD_STATUS -eq 22 ]; then
                fatal_error "Download failed after $MAX_RETRIES attempts." \
                           "ERROR: HTTP error (likely 403/404/410 - URL may have expired). Get a fresh download URL."
            else
                fatal_error "Download failed after $MAX_RETRIES attempts." \
                           "Curl exit code: $DOWNLOAD_STATUS. Possible: network error, timeout, or connection refused. Resume from byte $REMOTE_SIZE"
            fi
        fi
        if [ $DOWNLOAD_STATUS -eq 22 ]; then
            echo "❌ Download failed: HTTP error (URL may have expired). Retrying ($RETRY_COUNT/$MAX_RETRIES)..."
        else
            echo "❌ Download failed (curl exit code: $DOWNLOAD_STATUS). Retrying ($RETRY_COUNT/$MAX_RETRIES)..."
        fi
        sleep $DOWNLOAD_RETRY_SLEEP
        continue
    fi

    # Check for empty file
    if [ ! -s "$CUR_FILE" ]; then
        if [ "$TOTAL_SIZE" -gt 0 ] && [ "$REMOTE_SIZE" -ge "$TOTAL_SIZE" ] || [ "$REMOTE_SIZE" -gt 0 ]; then
            echo "✅ Download complete!"
            break
        else
            fatal_error "Download failed! Received 0 bytes from server." \
                       "Possible: Invalid/expired URL, 404, 5xx error, or disk full. Note: 0-byte PKG is invalid for PS4"
        fi
    fi

    FILE_SIZE=$(stat -f%z "$CUR_FILE" 2>/dev/null || stat -c%s "$CUR_FILE" 2>/dev/null)
    echo "   Downloaded: $FILE_SIZE bytes"

    # Upload chunk
    upload_chunk "$CUR_FILE" $FIRST_UPLOAD
    
    if [ $? -ne 0 ]; then
        RETRY_COUNT=$((RETRY_COUNT + 1))
        if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
            fatal_error "Upload failed after $MAX_RETRIES attempts." "Run script again to resume from byte $REMOTE_SIZE"
        fi
        echo "❌ Upload failed. Retrying ($RETRY_COUNT/$MAX_RETRIES)..."
        sleep $RETRY_SLEEP
        continue
    fi
    
    # Verify upload
    NEW_REMOTE_SIZE=$(get_remote_size "$FTP_URL")
    EXPECTED_SIZE=$((REMOTE_SIZE + FILE_SIZE))
    
    if [ -n "$NEW_REMOTE_SIZE" ]; then
        echo "   Remote size: $NEW_REMOTE_SIZE bytes (expected: $EXPECTED_SIZE)"
        if [ "$NEW_REMOTE_SIZE" != "$EXPECTED_SIZE" ]; then
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
                fatal_error "Size verification failed after $MAX_RETRIES attempts." \
                           "Remote has $NEW_REMOTE_SIZE bytes, expected $EXPECTED_SIZE. Run script again to resume."
            fi
            echo "⚠️ Size mismatch detected! Retrying ($RETRY_COUNT/$MAX_RETRIES)..."
            sleep $RETRY_SLEEP
            continue
        fi
        REMOTE_SIZE=$NEW_REMOTE_SIZE
        RETRY_COUNT=0
    else
        echo "⚠️ Warning: Cannot verify upload (FTP server not responding to SIZE query)"
        echo "   Assuming upload succeeded. Remote size should be: $EXPECTED_SIZE"
        REMOTE_SIZE=$EXPECTED_SIZE
    fi

    rm -f "$CUR_FILE"
    FIRST_UPLOAD=false

    # Check completion
    if [ "$FILE_SIZE" -lt "$CHUNK_SIZE" ]; then
        echo "🎉 Transfer complete!"
        break
    fi
    
    if [ "$TOTAL_SIZE" -gt 0 ] && [ "$REMOTE_SIZE" -ge "$TOTAL_SIZE" ]; then
        echo "🎉 Transfer complete! Reached total file size."
        break
    fi

    INDEX=$((INDEX + 1))
done

# ========= FINAL VERIFICATION =========
if [ "$TOTAL_SIZE" -gt 0 ]; then
    FINAL_REMOTE_SIZE=$(get_remote_size "$FTP_URL")
    if [ "$FINAL_REMOTE_SIZE" = "$TOTAL_SIZE" ]; then
        echo "✅ File size verified: $FINAL_REMOTE_SIZE bytes"
    else
        echo "⚠️ Warning: Remote size ($FINAL_REMOTE_SIZE) doesn't match expected ($TOTAL_SIZE)"
    fi
fi

echo "🏁 All done!"
