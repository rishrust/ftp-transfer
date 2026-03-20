# PS4 PKG Installer Scripts

Download large  files to Android/Termux and upload to PS4 a device with poor browser compatibility  via FTP with automatic chunking, resume capability, and corruption recovery.

## Scripts

### 🐢 `ps_install_fixed.sh` - Single-threaded (Recommended for large files)
- **Best for:** Files >5GB, unstable networks, maximum safety
- **Speed:** Slower but reliable
- **Resume:** Resumes from exact byte position
- **Storage:** Uses minimal space (single chunk)

```bash
./ps_install_fixed.sh <download_url> [filename] [ps4_ip] [port] [path]
```

### ⚡ `ps_install_parallel.sh` - Multi-threaded (Fast)
- **Best for:** Files <5GB, stable networks, speed priority
- **Speed:** 3x faster (parallel downloads)
- **Resume:** Smart checkpoint system with 250MB rolling cache
- **Storage:** Requires ~250MB free space (5 chunks)
- **Features:**
  - Stable checkpoint tracking (minimal data loss on corruption)
  - URL expiration handling (prompts for new link)
  - Automatic cache management

```bash
./ps_install_parallel.sh <download_url> [filename] [ps4_ip] [port] [path]
```

## Quick Start

```bash
# Default PS4 settings (192.168.0.110:2121, /data/pkg/)
./ps_install_parallel.sh "https://example.com/game.pkg"

# Custom settings
./ps_install_fixed.sh "https://example.com/game.pkg" game.pkg 192.168.1.100 2121 /data/pkg/
```

## Key Features

✅ **Automatic Resume** - Stop/restart anytime, no progress lost  
✅ **Corruption Detection** - Verifies every chunk upload  
✅ **Stable Checkpoints** - Roll back to last known good state (parallel only)  
✅ **URL Expiration Handling** - Prompts for new link when download expires (parallel only)  
✅ **Network Error Recovery** - Auto-retry with exponential backoff  
✅ **Cross-Platform** - Works on Android/Termux, macOS, Linux  

## Requirements

- `curl` (usually pre-installed)
- FTP server running on PS4 (e.g., [PS4 FTP Payload](https://github.com/xvortex/ps4-ftp))
- Network connectivity between device and PS4

## Configuration

Edit script constants for your needs:

```bash
# Chunk size (bigger = fewer chunks, more RAM)
CHUNK_SIZE=$((50 * 1024 * 1024))  # 50MB default

# Parallel settings (ps_install_parallel.sh only)
MAX_PARALLEL_DOWNLOADS=3          # Concurrent downloads
MAX_CACHED_CHUNKS=5               # Storage limit (5 = 250MB)
MAX_RETRIES=5                     # Retry attempts per chunk
```

## Resume After Interruption

Both scripts automatically detect and resume interrupted transfers:

```bash
# Just run the same command again
./ps_install_parallel.sh "https://example.com/game.pkg"

# Progress is saved in: .ps4_chunks_<filename>/
```

## Troubleshooting

**"Cannot recover - insufficient cache"**  
- Increase `MAX_CACHED_CHUNKS` in parallel script, or use fixed script

**"URL expired"**  
- Parallel script will prompt for new URL automatically
- Or manually delete state: `rm -rf .ps4_chunks_*/`

**Corruption detected**  
- Parallel: Restores to last checkpoint (loses only recent chunks)
- Fixed: Restarts from exact byte position

**Downloads too slow**  
- Use parallel script with `MAX_PARALLEL_DOWNLOADS=5` (if bandwidth allows)

**PS4 connection failed**  
- Verify FTP server is running on PS4
- Check IP address: `ping 192.168.0.110`
- Test FTP: `curl ftp://192.168.0.110:2121/`

## Examples

```bash
# Large file (20GB), safety priority
./ps_install_fixed.sh "https://cdn.example.com/huge-game.pkg"

# Medium file (2GB), speed priority  
./ps_install_parallel.sh "https://tempfile.link/expire-24h.pkg"

# Resume interrupted transfer
./ps_install_parallel.sh "https://example.com/game.pkg"  # Same URL

# New URL after expiration (parallel detects automatically)
# Script will prompt: "Enter new download URL:"
```

## State Files

```
.ps4_chunks_<filename>/
├── chunk_state.dat         # Download/upload tracking
├── stable_checkpoint.txt   # Last verified state (parallel only)
├── download_url.txt        # Saved URL (parallel only)
├── chunk_*.tmp            # Cached chunks (deleted after upload)
└── *.dat                  # Internal state files
```

## Performance Tips

- **Android/Termux:** Use parallel script with default settings
- **Slow SD card:** Decrease `MAX_CACHED_CHUNKS` to 3
- **Fast network:** Increase `MAX_PARALLEL_DOWNLOADS` to 5
- **Unstable connection:** Use fixed script or decrease `MAX_PARALLEL_DOWNLOADS` to 1

## License

MIT - Use freely, no warranty provided
