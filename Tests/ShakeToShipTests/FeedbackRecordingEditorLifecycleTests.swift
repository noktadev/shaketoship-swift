#if canImport(UIKit)
  import Foundation
  import Testing
  @testable import ShakeToShip

  private actor EditorLoadSignal {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
      if open { return }
      await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
      open = true
      let pending = waiters
      waiters.removeAll()
      pending.forEach { $0.resume() }
    }
  }

  @Suite @MainActor struct FeedbackRecordingEditorLifecycleTests {
    @Test func closeDuringSuspendedLoadRejectsLateCompletionAndRetryTasks() async {
      let started = EditorLoadSignal()
      let finish = EditorLoadSignal()
      let editor = FeedbackRecordingEditor()
      let data = FeedbackComposerData(
        id: "test", dir: URL(fileURLWithPath: "/capture"), events: [],
        recorded: URL(fileURLWithPath: "/capture/recording.mov"))
      let loading = Task {
        await editor.load(data) { _ in
          await started.release()
          await finish.wait()
          return URL(fileURLWithPath: "/capture/recording.mov")
        }
      }
      await started.wait()
      editor.stop()
      await finish.release()
      await loading.value
      #expect(editor.source == nil)
      #expect(editor.player == nil)
      #expect(editor.poster == nil)
      #expect(editor.thumbnails.isEmpty)
      #expect(editor.hasAudio == nil)
      #expect(editor.error == nil)
      #expect(!editor.transcribing)
      #expect(!editor.loading)
      // A queued unstructured Try again action cannot reopen a stopped editor.
      var retryStarted = false
      await editor.load(data) { _ in
        retryStarted = true
        return URL(fileURLWithPath: "/capture/recording.mov")
      }
      #expect(!retryStarted)
    }

    @Test func canceledLoadDoesNotInstallLateMediaOrSurfaceAnError() async {
      let started = EditorLoadSignal()
      let finish = EditorLoadSignal()
      let editor = FeedbackRecordingEditor()
      let data = FeedbackComposerData(
        id: "test", dir: URL(fileURLWithPath: "/capture"), events: [],
        recorded: URL(fileURLWithPath: "/capture/recording.mov"))
      let loading = Task {
        await editor.load(data) { _ in
          await started.release()
          await finish.wait()
          return URL(fileURLWithPath: "/capture/recording.mov")
        }
      }
      await started.wait()
      loading.cancel()
      await finish.release()
      await loading.value
      #expect(editor.source == nil)
      #expect(editor.player == nil)
      #expect(editor.error == nil)
      #expect(!editor.transcribing)
      editor.stop()
    }
  }
#endif
