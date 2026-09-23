import AppKit
import Testing
@testable import ApolloRuntime

struct ScrollActivityDeadlineTests {
    @Test func inertiaKeepsHoverSuppressedAcrossSparseTailEvents() {
        var state = ScrollActivityDeadline()
        state.record(at: 0, phase: .began, momentumPhase: [])
        state.record(at: 0.1, phase: .ended, momentumPhase: [])
        state.record(at: 0.11, phase: [], momentumPhase: .began)
        state.record(at: 0.2, phase: [], momentumPhase: .changed)
        // The previous unconditional 180 ms debounce released at 0.38,
        // even though no momentum-ended event had arrived.
        #expect(state.remaining(at: 0.5) > 0)
        state.record(at: 0.6, phase: [], momentumPhase: .ended)
        #expect(state.remaining(at: 0.77) > 0)
        #expect(state.remaining(at: 0.79) == 0)
    }

    @Test func legacyWheelAndCancelledGestureReleasePromptly() {
        var state = ScrollActivityDeadline()
        state.record(at: 10, phase: [], momentumPhase: [])
        #expect(state.remaining(at: 10.19) == 0)
        state.record(at: 11, phase: .began, momentumPhase: [])
        state.record(at: 11.1, phase: .cancelled, momentumPhase: [])
        #expect(state.remaining(at: 11.29) == 0)
    }

    @Test func interruptedSequenceCannotLeaveHoverDisabledForever() {
        var state = ScrollActivityDeadline()
        for index in 0..<240 {
            state.record(at: Double(index) / 120, phase: [], momentumPhase: .changed)
        }
        #expect(state.remaining(at: 2.3) > 0)
        #expect(state.remaining(at: 4) == 0)
    }
}
