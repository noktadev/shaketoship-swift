import Foundation

/// Keeps the selected file stable when a caller updates the attachment list.
struct FeedbackAttachmentViewerState {
  private(set) var items: [FeedbackMediaItem]
  private(set) var selection: URL?
  let canRemove: Bool

  init(items: [FeedbackMediaItem], initialSelection: URL, canRemove: Bool) {
    self.items = items
    selection = items.first(where: { $0.id == initialSelection })?.id ?? items.first?.id
    self.canRemove = canRemove
  }

  var selectedItem: FeedbackMediaItem? {
    items.first(where: { $0.id == selection })
  }

  var indexText: String? {
    guard let selection, let index = items.firstIndex(where: { $0.id == selection }) else {
      return nil
    }
    return "\(index + 1) of \(items.count)"
  }

  mutating func select(_ url: URL) {
    guard items.contains(where: { $0.id == url }) else { return }
    selection = url
  }

  mutating func reconcile(_ newItems: [FeedbackMediaItem]) {
    let oldIndex = items.firstIndex(where: { $0.id == selection }) ?? 0
    items = newItems
    if let selection, newItems.contains(where: { $0.id == selection }) { return }
    self.selection = newItems.isEmpty ? nil : newItems[min(oldIndex, newItems.count - 1)].id
  }

  /// Removes the selected item locally so paging updates before the caller's next render.
  mutating func removeSelected() -> FeedbackMediaItem? {
    guard canRemove, let selection,
      let index = items.firstIndex(where: { $0.id == selection })
    else { return nil }
    let removed = items.remove(at: index)
    self.selection = items.isEmpty ? nil : items[min(index, items.count - 1)].id
    return removed
  }
}

#if canImport(UIKit)
import AVKit
import SwiftUI
import UIKit

/// Present this view in a fullScreenCover. The caller owns the attachment list.
struct FeedbackAttachmentViewer: View {
  let items: [FeedbackMediaItem]
  let initialSelection: URL
  let onRemove: ((FeedbackMediaItem) -> Bool)?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.shakeToShipTheme) private var theme
  @State private var state: FeedbackAttachmentViewerState
  @State private var isClosing = false

  init(
    items: [FeedbackMediaItem],
    initialSelection: URL,
    onRemove: ((FeedbackMediaItem) -> Bool)? = nil
  ) {
    self.items = items
    self.initialSelection = initialSelection
    self.onRemove = onRemove
    _state = State(initialValue: FeedbackAttachmentViewerState(
      items: items, initialSelection: initialSelection, canRemove: onRemove != nil))
  }

  var body: some View {
    ZStack {
      theme.background ?? .black
      if let selection = state.selection {
        TabView(selection: Binding(
          get: { state.selection ?? selection },
          set: { state.select($0) }
        )) {
          ForEach(state.items) { item in
            Group {
              switch item.kind {
              case .image:
                FeedbackViewerImage(url: item.url)
                  .accessibilityIdentifier("ShakeToShip.attachment.image")
              case .video:
                FeedbackViewerVideo(
                  url: item.url, isSelected: state.selection == item.id && !isClosing)
                  .accessibilityIdentifier("ShakeToShip.attachment.video")
              }
            }
            .tag(item.id)
          }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
      }
    }
    .safeAreaInset(edge: .top, spacing: 0) { topBar }
    .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    .ignoresSafeArea(.container, edges: [.leading, .trailing])
    .simultaneousGesture(
      DragGesture(minimumDistance: 30).onEnded { value in
        if value.translation.height > 120,
          abs(value.translation.height) > abs(value.translation.width) * 1.2
        {
          close()
        }
      })
    .onChange(of: items) { _, newItems in
      state.reconcile(newItems)
      if state.selection == nil { close() }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("ShakeToShip.attachment.viewer")
  }

  private var topBar: some View {
    HStack {
      Button(action: close) {
        Image(systemName: "xmark")
          .font(.headline)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Close attachment")
      .accessibilityIdentifier("ShakeToShip.attachment.close")
      Spacer()
      Text(state.indexText ?? "")
        .font(.subheadline.weight(.semibold))
        .accessibilityLabel(state.indexText ?? "")
      Spacer()
      Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
    }
    .padding(.horizontal, 12)
    .foregroundStyle(theme.primaryText ?? .white)
    .background(theme.surface ?? Color.black.opacity(0.82))
  }

  private var bottomBar: some View {
    HStack {
      Capsule()
        .fill((theme.secondaryText ?? .white).opacity(0.7))
        .frame(width: 36, height: 5)
        .accessibilityHidden(true)
      Spacer()
      if state.canRemove, state.selectedItem != nil {
        Button(role: .destructive, action: removeSelected) {
          Label("Remove", systemImage: "trash")
        }
        .tint(theme.accent ?? .red)
        .accessibilityIdentifier("ShakeToShip.attachment.remove")
      }
    }
    .padding(.horizontal, 24)
    .padding(.vertical, 14)
    .foregroundStyle(theme.primaryText ?? .white)
    .background(theme.surface ?? Color.black.opacity(0.82))
  }

  private func removeSelected() {
    guard let item = state.selectedItem, onRemove?(item) == true else { return }
    _ = state.removeSelected()
    if state.selection == nil { close() }
  }

  private func close() {
    isClosing = true
    dismiss()
  }
}

private struct FeedbackViewerImage: View {
  let url: URL

  var body: some View {
    Group {
      if let image = UIImage(contentsOfFile: url.path) {
        FeedbackZoomableImage(image: image)
      } else {
        ContentUnavailableView("Image unavailable", systemImage: "photo")
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

private struct FeedbackZoomableImage: UIViewRepresentable {
  let image: UIImage

  func makeUIView(context: Context) -> UIScrollView {
    let scrollView = UIScrollView()
    scrollView.minimumZoomScale = 1
    scrollView.maximumZoomScale = 5
    scrollView.delegate = context.coordinator
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.backgroundColor = .clear

    let imageView = UIImageView(image: image)
    imageView.contentMode = .scaleAspectFit
    imageView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])
    context.coordinator.imageView = imageView
    return scrollView
  }

  func updateUIView(_ scrollView: UIScrollView, context: Context) {
    if context.coordinator.imageView?.image !== image {
      context.coordinator.imageView?.image = image
      scrollView.setZoomScale(1, animated: false)
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator: NSObject, UIScrollViewDelegate {
    weak var imageView: UIImageView?

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
  }
}

private struct FeedbackViewerVideo: View {
  let url: URL
  let isSelected: Bool
  @State private var player: AVPlayer
  /// Full-screen review playback must be audible with the Ring/Silent switch on too.
  @State private var audio = FeedbackPreviewAudio()

  init(url: URL, isSelected: Bool) {
    self.url = url
    self.isSelected = isSelected
    _player = State(initialValue: AVPlayer(url: url))
  }

  var body: some View {
    VideoPlayer(player: player)
      .onAppear { if isSelected { audio.begin(); player.play() } }
      .onChange(of: isSelected) { _, selected in
        if selected { audio.begin(); player.play() } else { player.pause(); audio.end() }
      }
      .onDisappear { player.pause(); audio.end() }
  }
}
#endif
