import SwiftUI
import SwiftData
import Charts
import MapKit

/// Per-drive deep dive: speed-vs-time chart with traffic shading, a
/// speed-colored route thumbnail, and stat cards.
///
/// The GPS blob is decoded once, lazily, in `.task` — never on list render —
/// and the decoded payload dies with this view's @State on dismissal.
struct DriveDetailView: View {
    let record: DriveRecord

    @State private var detail: DriveDetail?
    @AppStorage("steddi.units") private var unitsRaw: String = MeasurementUnit.miles.rawValue

    private var units: MeasurementUnit {
        MeasurementUnit(rawValue: unitsRaw) ?? .miles
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if let detail {
                    header(detail)
                    statsGrid(detail)
                    speedChartSection(detail)
                    mapSection(detail)
                } else {
                    loadingState
                }
            }
            .padding()
        }
        .background(SteddiTheme.surfacePrimary)
        .navigationTitle("Drive")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard detail == nil else { return }
            detail = AnalyticsService.buildDriveDetail(for: record)
        }
    }

    // MARK: - Header

    private func header(_ detail: DriveDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(detail.title)
                .font(SteddiTheme.heading(24))
                .foregroundStyle(SteddiTheme.textPrimary)
            Text(detail.startedAt.formatted(date: .complete, time: .shortened))
                .font(SteddiTheme.body(14))
                .foregroundStyle(SteddiTheme.textSecondary)
            SteadyLine()
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Stats

    private func statsGrid(_ detail: DriveDetail) -> some View {
        let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: columns, spacing: 12) {
            StatCard(
                value: AnalyticsFormat.minutesValue(seconds: detail.durationSeconds),
                label: "Duration", unit: "min", icon: "clock"
            )
            StatCard(
                value: AnalyticsFormat.minutesValue(seconds: detail.trafficSeconds),
                label: "In traffic", unit: "min", icon: "car.rear.waves.up",
                // Value is drawn AS TEXT on a surface, so use the surface-adaptive
                // legible variants (not the raw fill hues, which fail AA in
                // light/grey) — matches AggregateStatsCards and StatCard's preview.
                tint: detail.trafficSeconds > 0 ? SteddiTheme.warmRedText : SteddiTheme.sageText
            )
            StatCard(
                value: detail.averageSpeedMps.map { AnalyticsFormat.speedValue(mps: $0, unit: units) } ?? "—",
                label: "Avg speed", unit: AnalyticsFormat.speedUnit(units), icon: "gauge.with.needle"
            )
            StatCard(
                value: detail.maxSpeedMps.map { AnalyticsFormat.speedValue(mps: $0, unit: units) } ?? "—",
                label: "Top speed", unit: AnalyticsFormat.speedUnit(units), icon: "speedometer"
            )
        }
    }

    // MARK: - Speed Chart

    private func speedChartSection(_ detail: DriveDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speed")
                .font(SteddiTheme.heading(18))
                .foregroundStyle(SteddiTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if detail.speedPoints.count >= 2 {
                    speedChart(detail)
                } else {
                    chartPlaceholder
                }
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: SteddiTheme.radiusCard)
                    .fill(SteddiTheme.surfaceSecondary)
            }
        }
    }

    private func speedChart(_ detail: DriveDetail) -> some View {
        Chart {
            // Traffic shading: full-height bands where the drive crawled.
            ForEach(Array(detail.trafficRanges.enumerated()), id: \.offset) { _, range in
                RectangleMark(
                    xStart: .value("From", range.lowerBound / 60),
                    xEnd: .value("To", max(range.upperBound, range.lowerBound + 10) / 60)
                )
                .foregroundStyle(SteddiTheme.warmRed.opacity(0.13))
            }

            ForEach(detail.speedPoints) { point in
                LineMark(
                    x: .value("Minutes", point.offsetSeconds / 60),
                    y: .value("Speed", displaySpeed(point.speedMps))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(SteddiTheme.accent)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))

                AreaMark(
                    x: .value("Minutes", point.offsetSeconds / 60),
                    y: .value("Speed", displaySpeed(point.speedMps))
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(
                    LinearGradient(
                        colors: [SteddiTheme.accent.opacity(0.25), SteddiTheme.accent.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }

            if let avg = detail.averageSpeedMps {
                RuleMark(y: .value("Average", displaySpeed(avg)))
                    .foregroundStyle(SteddiTheme.textMuted.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .topTrailing, alignment: .trailing) {
                        Text("avg")
                            .font(SteddiTheme.mono(10))
                            .foregroundStyle(SteddiTheme.textMuted)
                    }
            }
        }
        .chartXAxisLabel("min", alignment: .trailing)
        .chartYAxisLabel(AnalyticsFormat.speedUnit(units))
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(SteddiTheme.textMuted.opacity(0.15))
                AxisValueLabel().foregroundStyle(SteddiTheme.textSecondary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(SteddiTheme.textMuted.opacity(0.15))
                AxisValueLabel().foregroundStyle(SteddiTheme.textSecondary)
            }
        }
        .frame(height: 220)
    }

    private var chartPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 28))
                .foregroundStyle(SteddiTheme.textMuted)
            Text("No GPS trace for this drive")
                .font(SteddiTheme.body(14))
                .foregroundStyle(SteddiTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 160)
    }

    private func displaySpeed(_ mps: Double) -> Double {
        switch units {
        case .miles: return mps * 2.23694
        case .kilometers: return mps * 3.6
        }
    }

    // MARK: - Route Map

    @ViewBuilder
    private func mapSection(_ detail: DriveDetail) -> some View {
        if detail.routeSamples.count >= 2 {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Route")
                        .font(SteddiTheme.heading(18))
                        .foregroundStyle(SteddiTheme.textPrimary)
                    Spacer()
                    speedLegend
                }
                SpeedColoredRouteMap(samples: detail.routeSamples)
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: SteddiTheme.radiusCard))
                    .allowsHitTesting(false)
            }
        }
    }

    private var speedLegend: some View {
        HStack(spacing: 10) {
            legendDot(color: SteddiTheme.warmRed, label: "Slow")
            legendDot(color: SteddiTheme.accent, label: "Moving")
            legendDot(color: SteddiTheme.sage, label: "Fast")
        }
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(SteddiTheme.textSecondary)
        }
    }

    // MARK: - Loading

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(SteddiTheme.accent)
            Text("Reading drive trace…")
                .font(SteddiTheme.body(14))
                .foregroundStyle(SteddiTheme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

// MARK: - Speed-Colored Route Map

/// Read-only map thumbnail whose polyline is colored by speed band:
/// warm red (stopped/slow), accent (moving), sage (free flow).
private struct SpeedColoredRouteMap: UIViewRepresentable {
    let samples: [DriveDetail.RouteSample]

    /// Below this is slow/stopped (~10 mph).
    static let slowThresholdMps = 4.5
    /// Above this is free flow (~35 mph).
    static let fastThresholdMps = 15.6

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.overrideUserInterfaceStyle = SteddiTheme.currentThemeMode.mapInterfaceStyle
        mapView.delegate = context.coordinator
        mapView.preferredConfiguration = SteddiTheme.mapConfiguration(
            traffic: false,
            poiFilter: .excludingAll
        )
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false

        addSegments(to: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {}

    private func addSegments(to mapView: MKMapView) {
        // Group consecutive samples into same-band segments. Each segment
        // shares one coordinate with its neighbor so the line is continuous.
        var segmentCoords: [CLLocationCoordinate2D] = []
        var segmentBand: Int?
        var boundingRect = MKMapRect.null

        func flush() {
            guard segmentCoords.count >= 2, let band = segmentBand else { return }
            let polyline = MKPolyline(coordinates: segmentCoords, count: segmentCoords.count)
            polyline.title = "\(band)"
            mapView.addOverlay(polyline)
            boundingRect = boundingRect.union(polyline.boundingMapRect)
        }

        for sample in samples {
            let band = Self.band(for: sample.speedMps)
            if band != segmentBand {
                if let last = segmentCoords.last {
                    flush()
                    segmentCoords = [last]
                } else {
                    segmentCoords = []
                }
                segmentBand = band
            }
            segmentCoords.append(sample.coordinate)
        }
        flush()

        if !boundingRect.isNull {
            mapView.setVisibleMapRect(
                boundingRect,
                edgePadding: UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24),
                animated: false
            )
        }
    }

    static func band(for speedMps: Double) -> Int {
        if speedMps < slowThresholdMps { return 0 }
        if speedMps < fastThresholdMps { return 1 }
        return 2
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            switch polyline.title {
            case "0": renderer.strokeColor = UIColor(SteddiTheme.warmRed)
            case "2": renderer.strokeColor = UIColor(SteddiTheme.sage)
            default: renderer.strokeColor = SteddiTheme.accentUIColor
            }
            renderer.lineWidth = 4
            renderer.lineCap = .round
            return renderer
        }
    }
}
