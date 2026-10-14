import CoreGraphics

/// The week is a single canvas. Rows and columns share the available space so
/// adding a teaching period never pushes the last row below the window.
struct ScheduleWeekMetrics {
    let horizontalInset: CGFloat
    let verticalInset: CGFloat
    let headerHeight: CGFloat
    let allDayHeight: CGFloat
    let labelWidth: CGFloat
    let timeColumnWidth: CGFloat
    let sectionColumnWidth: CGFloat
    let columnWidth: CGFloat
    let rowHeight: CGFloat

    init(viewport: CGSize, sectionCount: Int) {
        let width = viewport.width.isFinite ? max(0, viewport.width) : 0
        let height = viewport.height.isFinite ? max(0, viewport.height) : 0
        horizontalInset = min(10, width / 2)
        verticalInset = min(8, height / 2)
        let contentWidth = max(0, width - 2 * horizontalInset)
        let contentHeight = max(0, height - 2 * verticalInset)
        labelWidth = min(width < 620 ? 100 : 112, contentWidth)
        timeColumnWidth = min(width < 620 ? 48 : 54, labelWidth)
        sectionColumnWidth = max(0, labelWidth - timeColumnWidth)
        columnWidth = max(0, contentWidth - labelWidth) / 7
        headerHeight = min(44, contentHeight)
        allDayHeight = min(42, max(0, contentHeight - headerHeight))
        rowHeight = max(0, contentHeight - headerHeight - allDayHeight) / CGFloat(max(1, sectionCount))
    }

    func eventRect(dayIndex: Int, lane: Int = 0, laneCount: Int = 1,
                   top: CGFloat, height: CGFloat) -> CGRect {
        let laneWidth = columnWidth / CGFloat(max(1, laneCount))
        return CGRect(x: labelWidth + CGFloat(dayIndex) * columnWidth + CGFloat(lane) * laneWidth,
                      y: top, width: laneWidth, height: height)
    }
}
