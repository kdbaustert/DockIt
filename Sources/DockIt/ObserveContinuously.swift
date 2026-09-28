import Observation

/// Calls `read` under observation tracking and, after each change to anything it read, `onChange`
/// and then `read` again. `withObservationTracking` reports only the first change after it is set
/// up, so staying subscribed means setting it up again every time.
@MainActor
func observeContinuously(_ read: @escaping @MainActor () -> Void, onChange: @escaping @MainActor () -> Void) {
    withObservationTracking {
        read()
    } onChange: {
        Task { @MainActor in
            onChange()
            observeContinuously(read, onChange: onChange)
        }
    }
}
