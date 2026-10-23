import AppKit
import SwiftUI
import Testing
@testable import Teachshelf

@MainActor @Suite(.serialized) struct ToolbarUpdateFeedbackTests {
    @Test func mountedFeedbackDrawsIntermediateFramesBeforeSlowPresentationAndCoalescesRepeatedClicks() throws {
        let feedback = ToolbarUpdateFeedback(), frames = RotationFrames()
        let (window, host) = makeHost(feedback: feedback, frames: frames)
        defer { feedback.cancel(); window.close() }
        try waitUntil { frames.values.contains(0) }
        var presentations = 0, framesWhenPresented: [Double] = []
        feedback.start(reduceMotion: false) {
            presentations += 1
            framesWhenPresented = frames.values
            // Model constructing a slow WebKit sheet. Its work must start only
            // after the feedback has already produced visible intermediate frames.
            Thread.sleep(forTimeInterval: 0.1)
        }
        feedback.start(reduceMotion: false) { presentations += 100 }
        #expect(presentations == 0)
        try waitUntil { presentations > 0 }
        #expect(presentations == 1)
        #expect(feedback.rotation == 360)
        #expect(framesWhenPresented.contains { $0 > 0 && $0 < 360 })
        #expect(host.bounds.size == NSSize(width: 120, height: 80))
    }

    @Test func cancelingAndRequestingAgainCannotPresentTheOldRequestFromItsAnimationCompletion() throws {
        let feedback = ToolbarUpdateFeedback(), frames = RotationFrames()
        let (window, _) = makeHost(feedback: feedback, frames: frames)
        defer { feedback.cancel(); window.close() }
        try waitUntil { frames.values.contains(0) }
        var oldPresentations = 0, newPresentations = 0
        feedback.start(reduceMotion: false) { oldPresentations += 1 }
        try waitUntil { frames.values.contains { $0 > 0 && $0 < 360 } }
        feedback.cancel()
        feedback.start(reduceMotion: false) { newPresentations += 1 }
        feedback.start(reduceMotion: false) { newPresentations += 100 }
        try waitUntil { newPresentations > 0 }
        #expect(oldPresentations == 0)
        #expect(newPresentations == 1)
        #expect(feedback.rotation == 720)
        #expect(frames.values.contains { $0 > 360 && $0 < 720 })
    }

    @Test func reducedMotionPresentsSynchronouslyWithoutWaitingForAHostOrChangingRotation() {
        let feedback = ToolbarUpdateFeedback()
        var presentations = 0
        feedback.start(reduceMotion: true) { presentations += 1 }
        #expect(presentations == 1)
        #expect(feedback.rotation == 0)
        feedback.cancel()
        #expect(presentations == 1)
    }

    private func makeHost(feedback: ToolbarUpdateFeedback, frames: RotationFrames) -> (NSWindow, NSHostingView<FeedbackArtwork>) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: FeedbackArtwork(feedback: feedback, frames: frames))
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 120, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Toolbar feedback regression"
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return (window, host)
    }

    private func waitUntil(_ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try #require(predicate(), "The mounted SwiftUI host did not deliver the expected animation event.")
    }

    private struct FeedbackArtwork: View {
        @ObservedObject var feedback: ToolbarUpdateFeedback
        let frames: RotationFrames

        var body: some View {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 28))
                .modifier(RotationProbe(angle: feedback.rotation, frames: frames))
                .frame(width: 120, height: 80)
        }
    }

    private struct RotationProbe: GeometryEffect {
        var angle: Double
        let frames: RotationFrames
        var animatableData: Double {
            get { angle }
            set { angle = newValue }
        }

        func effectValue(size: CGSize) -> ProjectionTransform {
            frames.record(angle)
            return ProjectionTransform(CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
                .rotated(by: angle * .pi / 180)
                .translatedBy(x: -size.width / 2, y: -size.height / 2))
        }
    }

    private final class RotationFrames: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Double] = []
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
        func record(_ angle: Double) { lock.lock(); recorded.append(angle); lock.unlock() }
    }
}
