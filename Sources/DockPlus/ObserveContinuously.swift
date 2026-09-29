import Observation

/// Calls `read` under observation tracking and, after each change to anything it read, `onChange`
/// and then `read` again. `withObservationTracking` reports only the first change after it is set
/// up, so staying subscribed means setting it up again every time.
///
/// Held weakly by `owner`: once it is gone the chain stops re-arming. Without that, every replaced
/// DockController left a subscription behind that re-armed itself forever.
@MainActor
func observeContinuously(
    ownedBy owner: AnyObject & Sendable,
    _ read: @escaping @MainActor () -> Void,
    onChange: @escaping @MainActor () -> Void
) {
    withObservationTracking {
        read()
    } onChange: { [weak owner] in
        Task { @MainActor in
            guard let owner else { return }
            onChange()
            observeContinuously(ownedBy: owner, read, onChange: onChange)
        }
    }
}
