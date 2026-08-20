//! Pure policy for synchronous-only Linux AIO support.

/// io_submit completes requests before returning, so there is no cancellable
/// request state. io_cancel must not inspect or mutate any supplied object.
pub fn cancelUnsupported() bool {
    return true;
}
