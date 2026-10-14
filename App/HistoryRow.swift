import SwiftUI
import UIKit

/// Native iOS 26+ swipe actions use a 50-point capsule regardless of row height.
/// These explicit full-height actions share geometry with the content instead.
struct HistoryRow: View {
    let record: ListeningRecord
    let height: CGFloat
    let textHeight: CGFloat
    @Binding var activeSwipeID: String?
    let onPlay: () -> Void
    let onDelete: () -> Void
    let onToggleFavorite: () -> Void
    @State private var offset: CGFloat = 0
    @State private var initialOffset: CGFloat?
    private let actionWidth: CGFloat = 96

    private var visibleOffset: CGFloat { activeSwipeID == record.id ? offset : 0 }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if visibleOffset > 0 {
                    actionButton(title: record.isFavorite ? "取消收藏" : "收藏",
                                 icon: record.isFavorite ? "star.slash" : "star.fill", color: .orange) {
                        closeSwipe(); onToggleFavorite()
                    }
                    .accessibilityIdentifier("favorite-\(record.id)")
                    Spacer(minLength: 0)
                } else if visibleOffset < 0 {
                    Spacer(minLength: 0)
                    actionButton(title: "删除", icon: "trash", color: .red) {
                        closeSwipe(); onDelete()
                    }
                    .accessibilityIdentifier("delete-\(record.id)")
                }
            }
            Button {
                if activeSwipeID != nil { closeSwipe() }
                else { onPlay() }
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(record.text).font(.body).lineLimit(2).truncationMode(.tail)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: textHeight, maxHeight: textHeight, alignment: .topLeading)
                    HStack {
                        if record.isFavorite {
                            Image(systemName: "star.fill").foregroundStyle(.orange).accessibilityLabel("已收藏")
                        }
                        Text(record.lastPlayedAt, format: .dateTime.month().day().hour().minute())
                        Spacer()
                        Text(String(format: "%.1f 秒", record.duration))
                        Image(systemName: "play.circle.fill").foregroundStyle(.teal)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("history-\(record.id)")
            .accessibilityValue(record.isFavorite ? "已收藏" : "未收藏")
            .accessibilityAction(named: record.isFavorite ? "取消收藏" : "收藏") { closeSwipe(); onToggleFavorite() }
            .accessibilityAction(named: "删除") { closeSwipe(); onDelete() }
            .offset(x: visibleOffset)
            .gesture(HorizontalHistoryPan(
                changed: { dx in
                    if initialOffset == nil { initialOffset = visibleOffset }
                    activeSwipeID = record.id
                    offset = min(actionWidth, max(-actionWidth, (initialOffset ?? 0) + dx))
                },
                ended: { dx in
                    defer { initialOffset = nil }
                    let total = (initialOffset ?? 0) + dx
                    if total > actionWidth * 2.3 {
                        closeSwipe(); onToggleFavorite()
                    } else if total < -actionWidth * 2.3 {
                        closeSwipe(); onDelete()
                    } else {
                        withAnimation(.easeOut(duration: 0.16)) {
                            offset = abs(total) > actionWidth * 0.45 ? (total > 0 ? actionWidth : -actionWidth) : 0
                            activeSwipeID = offset == 0 ? nil : record.id
                        }
                    }
                },
                cancelled: { closeSwipe() }
            ))
        }
        .frame(height: height)
        .clipped()
        .onChange(of: record.isFavorite) { _, _ in closeSwipe() }
    }

    private func actionButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
            }
            .foregroundStyle(.white)
            .frame(width: actionWidth, height: height)
            .background(color)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func closeSwipe() {
        activeSwipeID = nil
        offset = 0
        initialOffset = nil
    }
}


/// Reject vertical pans before recognition so the List keeps normal vertical scrolling.
private struct HorizontalHistoryPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void
    let cancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed: changed(dx)
        case .ended: ended(dx)
        case .cancelled, .failed: cancelled()
        default: break
        }
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.2
        }
    }
}
