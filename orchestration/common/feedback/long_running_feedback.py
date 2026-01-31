"""
Shared feedback helpers for long-running AWS operations: progress, status, and wait-with-heartbeat.
Used by remove-all-aws-resources.py and any script that needs continuous feedback and heartbeat while waiting.
"""
import sys
import time
from typing import Callable, Optional


def _color(s: str, code: str) -> str:
    if hasattr(sys.stderr, "isatty") and sys.stderr.isatty():
        return f"\033[{code}m{s}\033[0m"
    return s


def _green(s: str) -> str:
    return _color(s, "32")


def _red(s: str) -> str:
    return _color(s, "31")


def _yellow(s: str) -> str:
    return _color(s, "33")


def progress(msg: str) -> None:
    """Print a progress line to stderr (visible to user)."""
    print(f"  {msg}", file=sys.stderr, flush=True)


def print_status(resource_id: str, status: str, detail: Optional[str] = None) -> None:
    """Print per-resource outcome: success (green), failed (red), skipped (yellow)."""
    if status == "success":
        print(f"  {resource_id}: {_green('success')}", file=sys.stderr, flush=True)
    elif status == "failed":
        line = f"  {resource_id}: {_red('failed')}"
        if detail:
            line += f" — {detail}"
        print(line, file=sys.stderr, flush=True)
    else:
        line = f"  {resource_id}: {_yellow('skipped')}"
        if detail:
            line += f" ({detail})"
        print(line, file=sys.stderr, flush=True)


def log_timeout(component: str, resource_id: str, timeout_min: int) -> None:
    """Print timeout at start of deletion for a component (DRY)."""
    print(f"  {component} {resource_id}: timeout {timeout_min} min", file=sys.stderr, flush=True)


def wait_with_heartbeat(
    description: str,
    check_fn: Callable[[], bool],
    timeout_sec: int,
    interval_sec: int = 60,
) -> bool:
    """
    Wait until check_fn() returns True or timeout. Print heartbeat every interval_sec to stderr.
    Returns True if check_fn() returned True before timeout, False on timeout.
    """
    timeout_min = timeout_sec // 60
    print(f"  Waiting for {description} (timeout: {timeout_min} min)...", file=sys.stderr, flush=True)
    start = time.monotonic()
    last_heartbeat = 0
    while True:
        try:
            if check_fn():
                return True
        except Exception:
            pass
        elapsed = int(time.monotonic() - start)
        if elapsed >= timeout_sec:
            print(f"  Timeout after {timeout_min} min.", file=sys.stderr, flush=True)
            return False
        if elapsed - last_heartbeat >= interval_sec:
            mins = elapsed // 60
            print(f"  ... have waited for {description} - {mins} min", file=sys.stderr, flush=True)
            last_heartbeat = elapsed
        time.sleep(min(interval_sec, timeout_sec - elapsed))
