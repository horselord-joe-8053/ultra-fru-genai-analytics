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
_log_ts() {
  date +"%Y-%m-%d %H:%M:%S.%3N %Z"
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

