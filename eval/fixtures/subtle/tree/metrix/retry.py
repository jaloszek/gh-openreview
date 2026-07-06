"""Generic retry decorator with exponential backoff, used by the billing
API client and the notification sender.
"""

import functools
import time

DEFAULT_MAX_ATTEMPTS = 3
DEFAULT_BASE_DELAY = 0.5


def retry(max_attempts=DEFAULT_MAX_ATTEMPTS, base_delay=DEFAULT_BASE_DELAY, exceptions=(Exception,)):
    """Retry a function up to max_attempts times with exponential backoff."""

    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            attempt = 1
            while True:
                try:
                    return func(*args, **kwargs)
                except exceptions as exc:
                    if attempt >= max_attempts:
                        raise
                    delay = base_delay * (2 ** (attempt - 1))
                    time.sleep(delay)
                    attempt += 1

        return wrapper

    return decorator


def call_with_retry(func, *args, max_attempts=DEFAULT_MAX_ATTEMPTS, **kwargs):
    """Functional form of retry() for callers that don't want a decorator."""
    return retry(max_attempts=max_attempts)(func)(*args, **kwargs)
