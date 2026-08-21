//! Pure policy for the currently unsupported user memory-lock ABI.

/// The kernel has no complete user-page pinning implementation. User-facing
/// mlock operations therefore fail without inspecting or mutating mapping or
/// lock state. The generic syscall entry still publishes the current task for
/// every syscall before reaching this ABI-specific policy.
pub fn userMlockUnsupported() bool {
    return true;
}
