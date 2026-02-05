#!/bin/bash
#
# Project-wide logging utilities.
# Provides colored, timestamped output and consistent logging format.
#
# Format: [YYYY-MM-DD HH:MM:SS.mmm TZ] [LEVEL] message
#

# Guard against double-loading
if [ -n "${FRU_LOGGER_SH_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
FRU_LOGGER_SH_LOADED=1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Timestamp helper: [YYYY-MM-DD HH:MM:SS.mmm TZ]
# Note: BSD `date` (macOS) does NOT support `%N`, so we:
# - Prefer GNU date (if available) for true milliseconds
# - Otherwise fall back to python3 for portable milliseconds
_log_ts() {
  # Prefer GNU date if available (supports %3N)
  if command -v gdate >/dev/null 2>&1; then
    gdate +"%Y-%m-%d %H:%M:%S.%3N %Z"
  elif date +"%N" >/dev/null 2>&1  | grep -qE '^[0-9]{9}$'; then
    # Some environments have GNU-ish `date` as default
    date +"%Y-%m-%d %H:%M:%S.%3N %Z"
  elif command -v python3 >/dev/null 2>&1; then
    # Portable fallback using python3
    python3 - << 'EOF'
import datetime, time
now = datetime.datetime.now()
ms = int(now.microsecond / 1000)
ts = now.strftime("%Y-%m-%d %H:%M:%S.") + f"{ms:03d}"
tz = time.tzname[0]
print(f"{ts} {tz}")
EOF
  else
    # Last resort: no milliseconds, but valid timestamp
    date +"%Y-%m-%d %H:%M:%S %Z"
  fi
}

_log_prefix() {
  printf '[%s] ' "$(_log_ts)"
}

log_info() {
  echo -e "$(_log_prefix)${BLUE}[INFO]${NC} $*"
}

log_success() {
  echo -e "$(_log_prefix)${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
  echo -e "$(_log_prefix)${YELLOW}[WARNING]${NC} $*"
}

log_error() {
  echo -e "$(_log_prefix)${RED}[ERROR]${NC} $*" >&2
}

log_step() {
  echo -e "\n$(_log_prefix)${GREEN}==>${NC} ${BLUE}$*${NC}"
}

# Check if command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Exit with error message
exit_with_error() {
  log_error "$*"
  exit 1
}

