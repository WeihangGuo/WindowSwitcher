import SwiftUI
import AppKit

/// Explicit drag zone: native window dragging via performDrag, immune to
/// SwiftUI hit-testing quirks.
private struct DragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ nsView: HandleView, context: Context) {}
}

/// Frosted-glass background that adapts to Light/Dark Mode and stays active
/// even though the app itself never activates.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherViewModel

    private let cornerRadius = SwitcherLayout.cornerRadius

    var body: some View {
        Group {
            if model.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VisualEffectBackground())
        // The top padding strip doubles as the drag grip (marked by the pill).
        .overlay(alignment: .top) {
            ZStack {
                DragHandle()
                Capsule()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 36, height: 5)
                    .allowsHitTesting(false)
            }
            .frame(height: SwitcherLayout.panelPadding)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow")
                .font(.system(size: 36, weight: .light))
            Text("No windows open")
                .font(.system(size: 15, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }

    /// Masonry: columns side by side, each a stack of app groups; a group is
    /// its header with its windows stacked vertically beneath it.
    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: SwitcherLayout.columnSpacing) {
                    ForEach(Array(model.columns.enumerated()), id: \.offset) { _, columnGroups in
                        VStack(alignment: .leading, spacing: SwitcherLayout.groupSpacing) {
                            ForEach(columnGroups) { group in
                                groupSection(group)
                            }
                        }
                        .frame(width: SwitcherLayout.columnWidth)
                    }
                }
                .padding(SwitcherLayout.panelPadding)
            }
            .onChange(of: model.selectedID) {
                if let id = model.selectedID {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private func groupSection(_ group: AppWindowGroup) -> some View {
        VStack(alignment: .leading, spacing: SwitcherLayout.rowSpacing) {
            HStack(spacing: 6) {
                Text(group.appName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(group.windows.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer(minLength: 0)
            }
            // Pinned so the model's geometry math stays exact.
            .frame(height: SwitcherLayout.headerHeight)
            ForEach(group.windows) { info in
                WindowCard(
                    info: info,
                    isSelected: model.selectedID == info.id,
                    isHovered: model.hoveredID == info.id,
                    isCurrent: model.currentWindowID == info.id,
                    onClose: { model.onClose?(info) }
                )
                .id(info.id)
                .onHover { hovering in
                    if hovering {
                        model.hoveredID = info.id
                    } else if model.hoveredID == info.id {
                        model.hoveredID = nil
                    }
                }
                .onTapGesture {
                    model.onActivate?(info)
                }
            }
        }
    }
}

private struct WindowCard: View {
    let info: WindowInfo
    let isSelected: Bool
    let isHovered: Bool
    let isCurrent: Bool
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.shared.icon(for: info.pid))
                .resizable()
                .frame(width: 26, height: 26)
            Text(info.displayTitle)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
            Spacer(minLength: 4)
            if info.isMinimized {
                statusGlyph("arrow.down.right.and.arrow.up.left")
            } else if info.isFullscreen {
                statusGlyph("arrow.up.left.and.arrow.down.right")
            }
            if isCurrent {
                Circle()
                    .fill(isSelected ? Color.white : Color.secondary)
                    .frame(width: 4, height: 4)
            }
            if isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Window (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: SwitcherLayout.cardHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(fillColor)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
    }

    private var fillColor: Color {
        if isSelected { return Color.accentColor }
        if isHovered { return Color.primary.opacity(0.10) }
        return Color.primary.opacity(0.045)
    }
}
