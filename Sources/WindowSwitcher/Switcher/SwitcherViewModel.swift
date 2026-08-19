import AppKit
import Combine

/// Selection and layout state for the switcher.
///
/// Two orders coexist:
/// - `flat` (MRU): what the shortcut cycles through — most recent first,
///   exactly the order `groups` arrives in.
/// - masonry geometry: what the arrow keys navigate — ↑/↓ walk a column,
///   ←/→ jump to the vertically nearest card in the adjacent column.
/// Geometry is computed here, from the same SwitcherLayout constants the
/// view renders with, so keys and pixels can never disagree.
final class SwitcherViewModel: ObservableObject {
    /// Canonical MRU-ordered groups (cycling order).
    private(set) var groups: [AppWindowGroup] = []
    /// Masonry columns derived from `groups`.
    @Published private(set) var columns: [[AppWindowGroup]] = []
    @Published private(set) var selectedID: WindowID?
    @Published var hoveredID: WindowID?

    /// The currently frontmost window (moves as the user activates cards
    /// while the palette stays open). Published: it drives the current-dot.
    @Published private(set) var currentWindowID: WindowID?

    /// Live RAM footprint per app pid; sampled only while visible.
    @Published var memoryByApp: [pid_t: UInt64] = [:]

    /// Called when the user clicks a card.
    var onActivate: ((WindowInfo) -> Void)?
    /// Called when the user asks to close a window (hover ✕ or ⌘W).
    var onClose: ((WindowInfo) -> Void)?

    private(set) var flat: [WindowInfo] = []
    /// Content size of the laid-out masonry (no panel padding).
    private(set) var contentSize: CGSize = .zero

    private var columnCount = 1
    /// Sticky group→column assignment so mid-session merges never reshuffle
    /// blocks between columns under the user's selection.
    private var columnAssignment: [pid_t: Int] = [:]

    private struct Position {
        let column: Int
        let indexInColumn: Int
        let top: CGFloat
    }

    private var positions: [WindowID: Position] = [:]
    private var columnSequences: [[WindowID]] = []

    var selectedWindow: WindowInfo? {
        guard let selectedID else { return nil }
        return flat.first { $0.id == selectedID }
    }

    var isEmpty: Bool { flat.isEmpty }

    // MARK: - Loading

    func load(groups: [AppWindowGroup], columnCount: Int, currentWindowID: WindowID?) {
        self.groups = groups
        self.columnCount = max(1, min(columnCount, max(1, groups.count)))
        self.currentWindowID = currentWindowID
        self.flat = groups.flatMap(\.windows)
        self.hoveredID = nil
        self.selectedID = nil
        self.columnAssignment = [:]
        rebuildColumns()
    }

    func selectFirst() {
        selectedID = flat.first?.id
    }

    /// A card was activated while the palette stays open.
    func markCurrent(_ id: WindowID) {
        currentWindowID = id
    }

    /// Preselect the quick-toggle target: the most recently used window
    /// other than the current one, wherever it sits in the alphabetical
    /// grid. Falls back to the first card that isn't the current window.
    func selectInitial(preferring preferred: WindowID?) {
        guard !flat.isEmpty else { return }
        if let preferred, flat.contains(where: { $0.id == preferred }) {
            selectedID = preferred
        } else if flat.count > 1, flat[0].id == currentWindowID {
            selectedID = flat[1].id
        } else {
            selectedID = flat[0].id
        }
    }

    /// Merge a reconcile result while the panel is visible. The visible sort
    /// order and column assignment are frozen (reshuffling under the user's
    /// cycling selection is a classic switcher bug): update in place, append
    /// new windows at the end of their group, drop vanished ones.
    func merge(fresh: [AppWindowGroup]) {
        let freshByID: [WindowID: WindowInfo] = fresh
            .flatMap(\.windows)
            .reduce(into: [:]) { $0[$1.id] = $1 }
        let existingIDs = Set(flat.map(\.id))

        var merged: [AppWindowGroup] = []
        for group in groups {
            var windows: [WindowInfo] = []
            for var info in group.windows {
                guard let updated = freshByID[info.id] else { continue } // vanished
                info.title = updated.title
                info.isMinimized = updated.isMinimized
                info.isFullscreen = updated.isFullscreen
                windows.append(info)
            }
            // Append this app's newly discovered windows.
            if let freshGroup = fresh.first(where: { $0.id == group.id }) {
                for info in freshGroup.windows where !existingIDs.contains(info.id) {
                    windows.append(info)
                }
            }
            if !windows.isEmpty {
                merged.append(AppWindowGroup(id: group.id, appName: group.appName, bundleID: group.bundleID, windows: windows))
            }
        }
        // Entirely new apps go at the end (shortest column).
        let knownGroupIDs = Set(groups.map(\.id))
        for group in fresh where !knownGroupIDs.contains(group.id) {
            merged.append(group)
        }

        groups = merged
        flat = merged.flatMap(\.windows)
        rebuildColumns()
        if let selectedID, !flat.contains(where: { $0.id == selectedID }) {
            self.selectedID = flat.first?.id
        }
    }

    /// Optimistic removal after a successful close: the card vanishes now;
    /// the store catches up via the destroyed-notification. Selection moves
    /// to the next window in cycling order.
    func removeWindow(id: WindowID) {
        guard let flatIndex = flat.firstIndex(where: { $0.id == id }) else { return }
        var newGroups: [AppWindowGroup] = []
        for var group in groups {
            group.windows.removeAll { $0.id == id }
            if !group.windows.isEmpty {
                newGroups.append(group)
            }
        }
        groups = newGroups
        flat = newGroups.flatMap(\.windows)
        rebuildColumns()
        if selectedID == id {
            selectedID = flat.isEmpty ? nil : flat[min(flatIndex, flat.count - 1)].id
        }
        if hoveredID == id {
            hoveredID = nil
        }
    }

    // MARK: - Masonry

    private func rebuildColumns() {
        var cols: [[AppWindowGroup]] = Array(repeating: [], count: columnCount)
        var heights = [CGFloat](repeating: 0, count: columnCount)
        for group in groups {
            var target = columnAssignment[group.id] ?? -1
            if target < 0 || target >= columnCount {
                // Same greedy rule as SwitcherLayout.masonryHeight.
                target = heights.enumerated().min { $0.element < $1.element }!.offset
            }
            columnAssignment[group.id] = target
            if heights[target] > 0 { heights[target] += SwitcherLayout.groupSpacing }
            cols[target].append(group)
            heights[target] += SwitcherLayout.groupHeight(windowCount: group.windows.count)
        }
        columns = cols

        // Geometry for arrow-key navigation.
        positions = [:]
        columnSequences = Array(repeating: [], count: columnCount)
        for (columnIndex, columnGroups) in columns.enumerated() {
            var y: CGFloat = 0
            var index = 0
            for group in columnGroups {
                y += SwitcherLayout.headerHeight + SwitcherLayout.rowSpacing
                for info in group.windows {
                    positions[info.id] = Position(column: columnIndex, indexInColumn: index, top: y)
                    columnSequences[columnIndex].append(info.id)
                    index += 1
                    y += SwitcherLayout.cardHeight + SwitcherLayout.rowSpacing
                }
                y += SwitcherLayout.groupSpacing - SwitcherLayout.rowSpacing
            }
        }

        contentSize = CGSize(
            width: CGFloat(columnCount) * SwitcherLayout.columnWidth
                + CGFloat(max(0, columnCount - 1)) * SwitcherLayout.columnSpacing,
            height: heights.max() ?? 0
        )
    }

    // MARK: - Keyboard navigation

    func selectNext() { step(by: 1) }
    func selectPrevious() { step(by: -1) }

    private func step(by delta: Int) {
        guard !flat.isEmpty else { return }
        guard let selectedID, let index = flat.firstIndex(where: { $0.id == selectedID }) else {
            self.selectedID = flat.first?.id
            return
        }
        let next = (index + delta + flat.count) % flat.count
        self.selectedID = flat[next].id
    }

    func moveUp() { moveVertically(by: -1) }
    func moveDown() { moveVertically(by: 1) }

    private func moveVertically(by delta: Int) {
        guard let selectedID, let position = positions[selectedID] else {
            selectFirst()
            return
        }
        let sequence = columnSequences[position.column]
        let target = position.indexInColumn + delta
        guard target >= 0, target < sequence.count else { return }
        self.selectedID = sequence[target]
    }

    func moveLeft() { moveHorizontally(by: -1) }
    func moveRight() { moveHorizontally(by: 1) }

    private func moveHorizontally(by delta: Int) {
        guard let selectedID, let position = positions[selectedID] else {
            selectFirst()
            return
        }
        guard columnCount > 1 else { return }
        // Wrap across columns, skipping any empty ones.
        var target = position.column
        for _ in 0..<columnCount {
            target = (target + delta + columnCount) % columnCount
            if !columnSequences[target].isEmpty { break }
        }
        guard target != position.column, !columnSequences[target].isEmpty else { return }
        // Land on the vertically nearest card.
        let best = columnSequences[target].min {
            abs((positions[$0]?.top ?? 0) - position.top) < abs((positions[$1]?.top ?? 0) - position.top)
        }
        self.selectedID = best
    }
}
