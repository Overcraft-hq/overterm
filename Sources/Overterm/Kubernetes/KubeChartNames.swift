// The time charts' names as Kubernetes knew them before they moved to
// `Charts/` for Activity's detail and meters too (docs/design/activity/
// analysis.md, D-21): Kubernetes' code keeps calling them so.

/// A series' point: `Charts/`' own, so a chart's data needs nothing of
/// Kubernetes' files; Kubernetes' answers keep the name.
package typealias KubeSeriesPoint = TimeChartPoint
package typealias KubeChartRole = TimeChartRole
package typealias KubeChartUnit = TimeChartUnit
package typealias KubeChartBand = TimeChartBand
package typealias KubeChartSeries = TimeChartSeries
package typealias KubeChartData = TimeChartData
package typealias KubePlotPath = TimePlotPath
package typealias KubePlot = TimePlot
package typealias KubeChartTooltip = TimeChartTooltip
package typealias KubeChartTime = TimeChartTime
package typealias KubeChartSummary = TimeChartSummary
package typealias KubeChartPalette = TimeChartPalette
package typealias KubeChartCursor = TimeChartCursor
package typealias KubeChartDraws = TimeChartDraws
package typealias KubeChartState = TimeChartState
package typealias KubeChartRegistry = TimeChartRegistry
package typealias KubeChartView = TimeChartView
package typealias KubeChartHoverMemo = TimeChartHoverMemo
package typealias KubeChartChip = TimeChartChip
package typealias KubeChartOverlay = TimeChartOverlay
package typealias KubeChartDescriptor = TimeChartDescriptor
package typealias KubeFlowLayout = ChartFlowLayout
