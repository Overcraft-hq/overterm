// The time charts' names as Kubernetes knew them before they moved to
// `Charts/` for Activity's detail and meters too (docs/design/activity/
// analysis.md, D-21): Kubernetes' code keeps calling them so.

/// A series' point: `Charts/`' own, so a chart's data needs nothing of
/// Kubernetes' files; Kubernetes' answers keep the name.
typealias KubeSeriesPoint = TimeChartPoint
typealias KubeChartRole = TimeChartRole
typealias KubeChartUnit = TimeChartUnit
typealias KubeChartBand = TimeChartBand
typealias KubeChartSeries = TimeChartSeries
typealias KubeChartData = TimeChartData
typealias KubePlotPath = TimePlotPath
typealias KubePlot = TimePlot
typealias KubeChartTooltip = TimeChartTooltip
typealias KubeChartTime = TimeChartTime
typealias KubeChartSummary = TimeChartSummary
typealias KubeChartPalette = TimeChartPalette
typealias KubeChartCursor = TimeChartCursor
typealias KubeChartDraws = TimeChartDraws
typealias KubeChartState = TimeChartState
typealias KubeChartRegistry = TimeChartRegistry
typealias KubeChartView = TimeChartView
typealias KubeChartHoverMemo = TimeChartHoverMemo
typealias KubeChartChip = TimeChartChip
typealias KubeChartOverlay = TimeChartOverlay
typealias KubeChartDescriptor = TimeChartDescriptor
typealias KubeFlowLayout = ChartFlowLayout
