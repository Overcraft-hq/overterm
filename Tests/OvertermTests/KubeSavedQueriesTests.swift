import Foundation
import XCTest

@testable import Overterm

/// A context's saved queries (docs/design/kubernetes/metrics.md, decision
/// 11; stage M8d): read from `kubernetes.contexts`' `charts`, checked
/// against the schema; filled in for a workload — `$ns` and `$name`
/// escaped as a literal or a regex by their matcher, `$pod` its pods'
/// names as a regex, `$w` the charts' rate window — or refused before
/// anything is sent: a selector without the scope's matchers, a subquery,
/// a range past an hour; planned on a workload's tab, drawn a chart each.
final class KubeSavedQueriesTests: XCTestCase {
    private let alphabet = KubeTabQueries.alphabet

    private func fill(_ query: String, namespace: String = "shop", kind: String = "Deployment", name: String = "web", window: TimeInterval = 240) -> Result<
        String, KubeCommands.Refused
    > {
        KubeSavedQueries.fill(query, namespace: namespace, kind: kind, name: name, window: window)
    }

    private func filled(_ query: String, namespace: String = "shop", kind: String = "Deployment", name: String = "web") throws -> String {
        try fill(query, namespace: namespace, kind: kind, name: name).get()
    }

    private func refusal(_ query: String) -> String? {
        if case .failure(let refused) = fill(query) { return refused.reason }
        return nil
    }

    // MARK: Filled in

    func testARequestRateIsFilledInForTheWorkload() throws {
        let query = #"sum(rate(http_requests_total{namespace="$ns",pod=~"$pod"}[$w]))"#
        XCTAssertEqual(
            try filled(query),
            #"sum(rate(http_requests_total{namespace="shop",pod=~"web-\#(alphabet){1,10}-\#(alphabet){5}"}[4m]))"#)
        // A StatefulSet's pods are its ordinals.
        XCTAssertEqual(
            try filled(query, kind: "StatefulSet", name: "db"), #"sum(rate(http_requests_total{namespace="shop",pod=~"db-[0-9]+"}[4m]))"#)
    }

    func testANameIsALiteralInEqualsAndARegexInMatches() throws {
        // `.` in a name: as is in `=`, escaped in `=~` (regexLiteral first, then literal: `\\.`).
        XCTAssertEqual(
            try filled(#"queue_depth{namespace="$ns",deployment="$name"}"#, namespace: "a.b", name: "api.v2"),
            #"queue_depth{namespace="a.b",deployment="api.v2"}"#)
        XCTAssertEqual(
            try filled(#"queue_depth{namespace="$ns",app="$name",service=~"$name-(grpc|http)"}"#, name: "api.v2"),
            #"queue_depth{namespace="shop",app="api.v2",service=~"api\\.v2-(grpc|http)"}"#)
        // The user's own escapes kept: a backquoted regex, a doubled backslash.
        XCTAssertEqual(
            try filled(#"x{namespace=`$ns`,app=`$name`,host=~`$name\.internal`}"#), #"x{namespace="shop",app="web",host=~"web\\.internal"}"#)
        XCTAssertEqual(try filled(#"x{namespace="$ns",app=~"$name",host=~"$name\\.internal"}"#), #"x{namespace="shop",app=~"web",host=~"web\\.internal"}"#)
        // A regex's own `$` anchor isn't a placeholder.
        XCTAssertEqual(try filled(#"x{namespace="$ns",app="$name",host=~"$name$"}"#), #"x{namespace="shop",app="web",host=~"web$"}"#)
    }

    func testLatencyAQuantileOverTheWorkloadsHistogram() throws {
        let query = """
            histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket{namespace="$ns", pod=~"$pod"}[$w])))
              / on() group_left() 1 # p99, seconds
            """
        let out = try filled(query)
        XCTAssertTrue(out.contains(#"{namespace="shop", pod=~"web-"#), out)
        XCTAssertTrue(out.contains("[4m]"), out)
        XCTAssertTrue(out.contains("# p99, seconds"), "a comment is the user's: kept as typed")
    }

    func testEverySelectorOfAnExpressionIsChecked() throws {
        let ok = #"sum(rate(errors_total{namespace="$ns",app="$name"}[5m])) / sum(rate(requests_total{namespace="$ns",app="$name"}[5m]))"#
        XCTAssertNoThrow(try filled(ok))
        let one = #"sum(rate(errors_total{namespace="$ns",app="$name"}[5m])) / sum(rate(requests_total{namespace="$ns"}[5m]))"#
        XCTAssertEqual(
            refusal(one),
            #"requests_total{…} needs namespace="$ns" and pod=~"$pod" or a label ="$name", each the placeholder alone, so it reads this workload's series alone."#)
        // PromQL 3's quoted name, and a selector of `__name__` alone.
        XCTAssertNoThrow(try filled(#"{"http.server.requests", namespace="$ns", pod=~"$pod"}"#))
        XCTAssertNoThrow(try filled(#"{__name__=~"queue_.*",namespace="$ns",app="$name"}"#))
        // Keywords are metrics' names where the grammar puts a selector.
        XCTAssertNoThrow(try filled(#"count by (code) (x{namespace="$ns",app="$name"}) or vector(0)"#))
        XCTAssertNoThrow(try filled(#"rate(x{namespace="$ns",app="$name"}[5m] offset 1h) > bool 0"#))
        XCTAssertNoThrow(try filled(#"x{namespace="$ns",app="$name"} offset -5m and on (pod) group_left y{namespace="$ns",app="$name"}"#))
        XCTAssertNotNil(refusal("rate(count[5m])"), "count, not followed by ( or by: a metric")
        XCTAssertNotNil(refusal("max"), "max alone: a metric")
        XCTAssertNotNil(refusal(#"x{namespace="$ns",app="$name"} + sum"#), "sum, not an aggregation here")
        XCTAssertNotNil(refusal(#"x{namespace="$ns",app="$name"} offset by"#), "offset without a duration")
        XCTAssertNotNil(refusal("rate(and[5m])"), "and in an operand's place: a metric")
        XCTAssertNotNil(refusal(#"x{namespace="$ns",app="$name"} + group_left"#), "group_left without on (…)")
    }

    // MARK: Refused

    func testWithoutTheScopesMatchersItIsRefused() {
        XCTAssertEqual(
            refusal("sum(rate(http_requests_total[5m]))"),
            #"http_requests_total has no label matchers: every selector needs namespace="$ns" and a matcher on $pod or $name."#)
        XCTAssertNotNil(refusal(#"http_requests_total{pod=~"$pod"}"#), "no namespace")
        XCTAssertNotNil(refusal(#"http_requests_total{namespace=~"$ns",pod=~"$pod"}"#), "the namespace as a regex isn't the scope")
        XCTAssertNotNil(refusal(#"http_requests_total{namespace="$ns"}"#), "the namespace alone: every workload's")
        XCTAssertNotNil(refusal(#"http_requests_total{namespace="$ns",pod!~"$pod"}"#), "a negative matcher isn't the scope")
        XCTAssertNotNil(refusal(#"http_requests_total{namespace="other",pod=~"$pod"}"#), "another namespace")
        // The placeholder mentioned isn't enough: it must be the whole value.
        XCTAssertNotNil(refusal(#"rate(http_requests_total{namespace="$ns",pod=~"$pod|.*"}[$w])"#), "every pod of the namespace")
        XCTAssertNotNil(refusal(#"rate(http_requests_total{namespace="$ns",pod=~"$pod|.+"}[$w])"#), "every pod of the namespace")
        XCTAssertNotNil(refusal(#"x{namespace="$ns",app=~"$name.*"}"#), "every workload whose name starts with it")
        XCTAssertNotNil(refusal(#"x{namespace="$ns",app=~".*$name.*"}"#), "every workload whose name holds it")
        XCTAssertNotNil(refusal(#"x{namespace="$ns",job=~"$name|.*"}"#), "matches the empty string: series without the label too")
        XCTAssertNotNil(refusal(#"x{namespace="$ns",__name__="$name"}"#), "a metric's name isn't a workload")
        // `namespace` itself: an exported one leaves the real label open.
        XCTAssertNotNil(refusal(#"x{exported_namespace="$ns",pod=~"$pod"}"#))
        XCTAssertNotNil(refusal(#"x{foo_namespace="$ns",app="$name"}"#))
        XCTAssertNotNil(refusal(#"DCGM_FI_DEV_GPU_UTIL{exported_namespace="$ns",exported_pod=~"$pod"}"#))
    }

    func testThePlaceholdersGoWhereTheyMean() {
        XCTAssertEqual(
            refusal(#"x{namespace="$ns",pod="$pod"}"#), #"$pod is a pattern of the workload's pods' names: use it in a regex matcher, pod=~"$pod"."#)
        XCTAssertEqual(refusal(#"rate(x{namespace="$ns",app="$name"}[5m]) * $w"#), "$w is filled in only inside a range's brackets: rate(…[$w]).")
        XCTAssertEqual(
            refusal(#"label_replace(x{namespace="$ns",app="$name"}, "who", "$name", "", "")"#),
            "$ns, $pod and $name are filled in only in a label matcher's value, not in other strings.")
        XCTAssertEqual(refusal(#"rate(x{namespace="$ns",app="$name"}[$ns])"#), "$ns isn't filled in inside a range: only $w is.")
    }

    func testTheCostCaps() {
        XCTAssertEqual(
            refusal(#"max_over_time(rate(x{namespace="$ns",pod=~"$pod"}[5m])[1h:1m])"#),
            "it has a subquery ([…:…]): Prometheus would evaluate it at every step.")
        XCTAssertEqual(
            refusal(#"rate(x{namespace="$ns",pod=~"$pod"}[2h])"#), "it reads a range longer than 1h at every step: use $w, or a recording rule.")
        XCTAssertNil(refusal(#"rate(x{namespace="$ns",pod=~"$pod"}[1h])"#), "an hour is allowed")
        XCTAssertNotNil(refusal(#"rate(x{namespace="$ns",pod=~"$pod"}[30m30m1s])"#))
        XCTAssertEqual(refusal("   "), "it is empty.")
        let long = #"x{namespace="$ns",pod=~"$pod"}"# + String(repeating: " ", count: 1) + "+ " + String(repeating: "1 + ", count: 600) + "1"
        XCTAssertEqual(refusal(long), "it is longer than \(KubeSavedQueries.lengthAtMost) characters.")
        XCTAssertEqual(refusal(#"x{namespace="$ns",pod=~"$pod}"#), "a string isn't closed.")
        XCTAssertEqual(refusal(#"x{namespace="$ns",pod=~"\q"}"#), #""\q" isn't a string Prometheus reads."#)
    }

    func testDurations() {
        XCTAssertEqual(KubeSavedQueries.seconds("5m"), 300)
        XCTAssertEqual(KubeSavedQueries.seconds("1h30m"), 5400)
        XCTAssertEqual(KubeSavedQueries.seconds("90"), 90)
        XCTAssertEqual(KubeSavedQueries.seconds("250ms"), 0.25)
        XCTAssertNil(KubeSavedQueries.seconds("5x"))
    }

    // MARK: The setting

    func testChartsAreReadFromTheContextsEntry() throws {
        let json = """
            {"fake-dev": {"metrics": "prometheus", "charts": [
              {"title": "Requests", "query": "sum(rate(a{namespace=\\"$ns\\",pod=~\\"$pod\\"}[$w]))", "unit": "perSecond"},
              {"title": "Queue", "query": "b{namespace=\\"$ns\\",app=\\"$name\\"}"},
              {"title": "", "query": "c"}
            ]}}
            """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let value = try XCTUnwrap(SettingValue(json: object))
        let spec = try XCTUnwrap(SettingsSchema.byKey["kubernetes.contexts"])
        XCTAssertNil(spec.problem(with: value))
        let (fitted, problems) = spec.fitted(value)
        XCTAssertEqual(problems, [#""kubernetes.contexts" › "fake-dev": "charts" item 3's "title" is empty; it is left out."#])
        XCTAssertNil(fitted.entries?["fake-dev"]?["charts"], "a bad item leaves the field out, the rest of the entry kept")
        XCTAssertEqual(fitted.entries?["fake-dev"]?["metrics"], .string("prometheus"))
        // Read as the file has it: the two good ones, a unit by default a number.
        let settings = KubeContextSettings(fields: try XCTUnwrap(value.entries?["fake-dev"]))
        XCTAssertEqual(settings.charts.map(\.title), ["Requests", "Queue"])
        XCTAssertEqual(settings.charts.map(\.unit), [.perSecond, .count])
        // Written back as it was read.
        let charts = try XCTUnwrap(value.entries?["fake-dev"]?["charts"])
        let again = try JSONSerialization.jsonObject(with: Data(charts.json.utf8))
        XCTAssertEqual(SettingValue(json: again), charts)
    }

    func testTheSchemaSaysWhatIsWrongWithAChart() throws {
        let spec = try XCTUnwrap(SettingsSchema.byKey["kubernetes.contexts"])
        func problem(_ records: [[String: String]]) -> [String] { spec.fitted(.entries(["fake-dev": ["charts": .records(records)]])).problems }
        XCTAssertEqual(problem([["title": "Requests", "query": "q", "unit": "perSecond"]]), [])
        XCTAssertEqual(problem([["title": "Requests"]]), [#""kubernetes.contexts" › "fake-dev": "charts" item 1 has no "query"; it is left out."#])
        XCTAssertEqual(
            problem([["title": "R", "query": "q", "colour": "red"]]),
            [#""kubernetes.contexts" › "fake-dev": "charts" item 1 has "colour", which isn't a field Overterm knows (title, query, unit); it is left out."#])
        XCTAssertTrue(problem([["title": "R", "query": "q", "unit": "furlongs"]]).first?.contains(#"item 1's "unit" must be one of "count""#) == true)
        XCTAssertEqual(
            spec.fitted(.entries(["fake-dev": ["charts": .string("q")]])).problems.first,
            #""kubernetes.contexts" › "fake-dev": "charts" must be a list of objects, like [{ "title": …, "query": …, "unit": … }]; it is left out."#)
        // `[]` is none; a number in a field is said as text, never dropped silently.
        XCTAssertEqual(problem([]), [])
        let numbered = SettingValue(json: [["title": "R", "query": 1] as [String: Any]] as [Any])
        XCTAssertEqual(numbered, .records([["title": "R", "query": "1"]]))
        XCTAssertNil(SettingValue(json: [["title": ["nested": true]] as [String: Any]] as [Any]))
    }

    // MARK: Planned

    private func request(_ saved: [KubeSavedChart], families: Set<KubeTabFamily> = [.saved]) -> KubeTabRequest {
        KubeTabRequest(subject: .workload(namespace: "shop", kind: "Deployment", name: "web", hpa: nil), span: .range(.hour), families: families, saved: saved)
    }

    private var span: KubePromSpan { KubeMetricsSpan.of(.hour, scrape: KubePromProfile.unknown.scrapeInterval, now: Date(timeIntervalSince1970: 1_800_000_000)) }

    func testAWorkloadsTabAsksEachSavedQueryOverItsRange() {
        let saved = [
            KubeSavedChart(title: "Requests", query: #"sum(rate(a{namespace="$ns",pod=~"$pod"}[$w]))"#, unit: .perSecond),
            KubeSavedChart(title: "Everything", query: "sum(rate(a[5m]))"),
        ]
        let plan = KubeTabQueries.plan(request(saved), span: span, profile: .unknown)
        XCTAssertEqual(plan.queries.map(\.id), ["saved.0"])
        XCTAssertEqual(plan.queries.first?.family, .saved)
        XCTAssertEqual(plan.queries.first?.instant, false, "over the range: query_range")
        XCTAssertEqual(
            plan.queries.first?.promql,
            #"sum(rate(a{namespace="shop",pod=~"web-\#(alphabet){1,10}-\#(alphabet){5}"}[\#(KubePromQL.duration(KubeRateWindow.of(step: span.step, scrape: KubePromProfile.unknown.scrapeInterval)))]))"#
        )
        XCTAssertEqual(plan.savedRefused, ["saved.1": #"a has no label matchers: every selector needs namespace="$ns" and a matcher on $pod or $name."#])
        // Not wanted (scrolled off): nothing asked.
        XCTAssertTrue(KubeTabQueries.plan(request(saved, families: [.cpu]), span: span, profile: .unknown).queries.allSatisfy { $0.family != .saved })
        // Past six, the rest aren't asked.
        let many = (0..<9).map { KubeSavedChart(title: "q\($0)", query: #"a{namespace="$ns",app="$name"}"#) }
        XCTAssertEqual(KubeTabQueries.plan(request(many), span: span, profile: .unknown).queries.count, KubeSavedQueries.atMost)
    }

    func testOnlyAWorkloadsTabHasThem() {
        XCTAssertTrue(KubePromTabCharts.families(.workload("Deployment"), source: .prometheus).contains(.saved))
        XCTAssertTrue(KubePromTabCharts.families(.workload("Deployment"), source: .mixed).contains(.saved), "in Live too: Prometheus' only")
        XCTAssertFalse(KubePromTabCharts.families(.pod, source: .prometheus).contains(.saved))
        XCTAssertFalse(KubePromTabCharts.families(.namespace, source: .prometheus).contains(.saved))
        XCTAssertEqual(KubePromTabCharts.readWhenShown[KubeSavedCharts.groupTitle], [.saved], "read only while on screen")
    }

    // MARK: Drawn

    private func reading(_ results: [String: [KubeSeries]], saved: [String: String] = [:]) -> KubeTabReading {
        var reading = KubeTabReading(request: request([]))
        reading.span = span
        reading.results = results
        reading.saved = saved
        return reading
    }

    private func line(_ labels: [String: String], _ value: Double) -> KubeSeries {
        KubeSeries(labels: labels, points: [KubeSeriesPoint(time: span.end.addingTimeInterval(-60), value: value), KubeSeriesPoint(time: span.end, value: value)])
    }

    func testEachSavedQueryIsAChartInItsUnit() throws {
        let saved = [
            KubeSavedChart(title: "Requests", query: "q", unit: .perSecond), KubeSavedChart(title: "p99", query: "q", unit: .seconds),
            KubeSavedChart(title: "Errors", query: "q"), KubeSavedChart(title: "Bad", query: "q"),
        ]
        let made = KubeSavedCharts.group(
            subject: "workload.shop.deployment.web", saved: saved,
            reading: reading(
                [
                    "saved.0": [line(["route": "/a", "__name__": "x"], 12), line(["route": "/b", "__name__": "x"], 3)],
                    "saved.1": [line([:], 0.25)],
                    "saved.2": [],
                ], saved: ["saved.3": KubeSavedCharts.rejected("Prometheus refused the query: 1:5: parse error: unexpected }")]))
        let group = try XCTUnwrap(made.group)
        XCTAssertEqual(group.title, KubeSavedCharts.groupTitle)
        XCTAssertTrue(group.readsWhenShown)
        XCTAssertFalse(group.pending)
        XCTAssertEqual(group.charts.map(\.data.id), ["workload.shop.deployment.web.saved.0", "workload.shop.deployment.web.saved.1"])
        XCTAssertEqual(group.charts.map(\.data.title), ["Requests", "p99"])
        XCTAssertEqual(group.charts[0].data.unit, .perSecond)
        XCTAssertEqual(group.charts[0].data.usage.map(\.name), ["/a", "/b"], "named by the label that tells them apart, largest first")
        XCTAssertEqual(group.charts[0].headline, "2 series")
        XCTAssertEqual(group.charts[1].headline, "250 ms now")
        XCTAssertEqual(
            made.notes,
            [
                "Saved query \u{201C}Errors\u{201D}: Prometheus answered no series for this workload over the range.",
                "Saved query \u{201C}Bad\u{201D}: Prometheus refused the query: 1:5: parse error: unexpected }. Not asked again until it is edited.",
            ])
        // Nothing read yet: pending, there to be scrolled to.
        let pending = KubeSavedCharts.group(subject: "w", saved: saved, reading: nil)
        XCTAssertEqual(pending.group?.pending, true)
        XCTAssertNil(KubeSavedCharts.group(subject: "w", saved: [], reading: nil).group, "none written: no group")
        XCTAssertEqual(
            KubeSavedCharts.group(subject: "w", saved: Array(repeating: saved[0], count: 8), reading: nil).notes,
            ["2 saved queries more aren't asked: at most 6 a context."])
    }

    func testPastTwelveSeriesTheRestAreOtherOrSaid() throws {
        let answer = (0..<15).map { line(["route": "/r\($0)"], Double($0 + 1)) }
        let rate = try XCTUnwrap(
            KubeSavedCharts.chart(KubeSavedChart(title: "R", query: "q", unit: .perSecond), index: 0, subject: "w", answer: answer, span: span))
        XCTAssertEqual(rate.chart.data.usage.count, 13)
        XCTAssertEqual(rate.chart.data.usage.first?.name, "/r14", "largest first")
        XCTAssertEqual(rate.chart.data.usage.last?.name, "other")
        XCTAssertEqual(rate.chart.data.usage.last?.points.last?.value, 6, "the three smallest summed")
        let latency = try XCTUnwrap(
            KubeSavedCharts.chart(KubeSavedChart(title: "L", query: "q", unit: .seconds), index: 0, subject: "w", answer: answer, span: span))
        XCTAssertEqual(latency.chart.data.usage.count, 12, "latencies don't add up")
        XCTAssertEqual(latency.notes, [#"3 series more aren't drawn: the 12 largest are (seconds don't add up into "other")."#])
    }

    func testSeriesNames() {
        XCTAssertEqual(KubeSavedCharts.names([["a": "1"]]), ["value"])
        XCTAssertEqual(KubeSavedCharts.names([["a": "1", "b": "x"], ["a": "2", "b": "x"]]), ["1", "2"])
        XCTAssertEqual(KubeSavedCharts.names([["a": "1", "b": "x"], ["a": "2", "b": "y"]]), ["a=1 · b=x", "a=2 · b=y"])
        XCTAssertEqual(KubeSavedCharts.names([["a": "1"], ["a": "1"]]), ["series 1", "series 2"])
    }

    func testAQueryPrometheusRefusedIsSaidInItsWords() {
        XCTAssertEqual(KubeSavedCharts.rejected(""), "Prometheus refused it. Not asked again until it is edited.")
        XCTAssertEqual(KubeSavedCharts.rejected("Prometheus refused the query: x."), "Prometheus refused the query: x. Not asked again until it is edited.")
    }

    func testRatesAndDurationsAreSaidInTheirUnits() {
        XCTAssertEqual(KubeChartUnit.perSecond.format(12.4), "12/s")
        XCTAssertEqual(KubeChartUnit.perSecond.format(0.25), "0.25/s")
        XCTAssertEqual(KubeChartUnit.perSecond.format(1500), "1.5k/s")
        XCTAssertEqual(KubeChartUnit.seconds.format(0.012), "12 ms")
        XCTAssertEqual(KubeChartUnit.seconds.format(1.5), "1.50 s")
        XCTAssertEqual(KubeChartUnit.seconds.format(0.0002), "200 µs")
        XCTAssertEqual(KubeSavedChart.Unit.percent.chartUnit, .ratio)
        // Anyone's numbers: past Int's range they are said, never trap.
        for unit in KubeSavedChart.Unit.allCases {
            let chart = unit.chartUnit
            XCTAssertFalse(chart.format(1.8e19).isEmpty, "\(unit)")
            XCTAssertFalse(chart.format(-1e19).isEmpty, "\(unit)")
            XCTAssertFalse(chart.format(.infinity).isEmpty, "\(unit)")
            XCTAssertFalse(chart.format(.nan).isEmpty, "\(unit)")
        }
        XCTAssertEqual(KubeChartUnit.count.format(1.8446744073709552e19), "1.84e+19")
        XCTAssertEqual(KubeChartUnit.ratio.format(-1e19), "-1e+21%")
        XCTAssertEqual(KubeChartUnit.bytes.format(-1e19), "-1e+19 B")
        XCTAssertEqual(KubeChartUnit.count.format(42), "42", "an ordinary count, as before")
    }
}
