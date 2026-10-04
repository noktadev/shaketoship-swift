#if canImport(UIKit)
import SwiftUI

/// Add this section to FeedbackInboxView's List. It reads only persisted report receipts.
struct FeedbackOwnedReportSection: View {
  @Bindable var model: FeedbackHubModel
  var refreshToken = false

  @Environment(\.shakeToShipTheme) private var theme
  @State private var reports: [FeedbackOwnedSession] = []
  @State private var requestID = UUID()

  var body: some View {
    Group {
      if !reports.isEmpty {
        Section {
          ForEach(reports) { report in
            NavigationLink {
              FeedbackOwnedReportDetailView(model: model, report: report)
            } label: {
              HStack(spacing: 12) {
                Image(systemName: "doc.text.image")
                  .foregroundStyle(theme.secondaryText ?? .secondary)
                  .frame(width: 40, height: 40)
                  .background(
                    (theme.secondaryText ?? .secondary).opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 8))
                  .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                  Text("Bug report").feedbackFont(.headline)
                    .foregroundStyle(theme.primaryText ?? .primary)
                    .lineLimit(1)
                  Text(report.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .feedbackFont(.caption, inherit: false)
                    .foregroundStyle(theme.secondaryText ?? .secondary)
                    .lineLimit(1)
                }
              }
            }
            .accessibilityIdentifier("ShakeToShip.inbox.report")
            .feedbackRow()
          }
        } header: {
          Text("My reports").foregroundStyle(theme.secondaryText ?? .secondary)
        }
      }
    }
    .task(id: refreshToken) { await refresh() }
    .onChange(of: model.revision) { _, _ in
      requestID = UUID()
      reports = []
    }
  }

  private func refresh() async {
    guard model.active, model.config.hub.contains(.inbox) else { return }
    let expected = model.revision
    let currentRequest = UUID()
    requestID = currentRequest
    await model.perform {
      _ = try await model.client.identity()
      let receipts = try await model.client.ownedSessions()
      guard model.active, expected == model.revision,
        requestID == currentRequest, !Task.isCancelled
      else { return }
      reports = receipts.filter { $0.purpose == .report }
        .sorted { $0.createdAt > $1.createdAt }
    }
  }
}
#endif
