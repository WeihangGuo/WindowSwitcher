import Foundation

/// Single source of truth for the switcher's metrics: the controller's
/// sizing math and the SwiftUI render must never disagree.
///
/// Layout model: a masonry grid. Each app group is an atomic vertical block
/// (header + its windows stacked beneath it); blocks are distributed
/// greedily into the currently shortest column, in MRU order.
enum SwitcherLayout {
    static let panelPadding: CGFloat = 20
    static let cardHeight: CGFloat = 44
    static let columnWidth: CGFloat = 260
    static let columnSpacing: CGFloat = 16
    /// Vertical gap inside a group (header→card and card→card).
    static let rowSpacing: CGFloat = 8
    static let groupSpacing: CGFloat = 14
    /// Header gets a pinned frame so its height isn't font-derived.
    static let headerHeight: CGFloat = 18
    static let cornerRadius: CGFloat = 22

    static func groupHeight(windowCount: Int) -> CGFloat {
        headerHeight + rowSpacing
            + CGFloat(windowCount) * cardHeight
            + CGFloat(max(0, windowCount - 1)) * rowSpacing
    }

    /// Height of the tallest column after greedy shortest-column-first
    /// distribution — the SAME rule SwitcherViewModel uses, so the
    /// column-count planning done before load matches what gets rendered.
    static func masonryHeight(groupSizes: [Int], columns: Int) -> CGFloat {
        guard columns > 0 else { return 0 }
        var heights = [CGFloat](repeating: 0, count: columns)
        for size in groupSizes {
            let target = heights.enumerated().min { $0.element < $1.element }!.offset
            if heights[target] > 0 { heights[target] += groupSpacing }
            heights[target] += groupHeight(windowCount: size)
        }
        return heights.max() ?? 0
    }
}
