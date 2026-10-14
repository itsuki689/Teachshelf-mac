import CoreGraphics

/// The week is a single canvas. Rows and columns share the available space so
/// adding a teaching period never pushes the last row below the window.
struct ScheduleWeekMetrics {
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let headerHeight: CGFloat
    let labelWidth: CGFloat
    let columnWidth: CGFloat
    let rowHeight: CGFloat

    init(viewport: CGSize, sectionCount: Int) {
        let width = viewport.width.isFinite ? max(0, viewport.width) : 0
        let height = viewport.height.isFinite ? max(0, viewport.height) : 0
        horizontalInset = min(10, width / 2)
        verticalInset = min(8, height / 2)
        let contentWidth = max(0, width - 2 * horizontalInset)
        let contentHeight = max(0, height - 2 * verticalInset)
        labelWidth = min(width < 620 ? 58 : 64, contentWidth)
        columnWidth = max(0, contentWidth - labelWidth) / 7
        headerHeight = min(44, contentHeight)
        rowHeight = max(0, contentHeight - headerHeight) / CGFloat(max(1, sectionCount))
    }
}
