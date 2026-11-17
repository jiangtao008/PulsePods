import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PulsePodsLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PulsePodsActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "heart.fill")
                    .font(.title2)
                    .foregroundStyle(.pink)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PulsePods")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(context.state.isConnected ? "实时心率" : "耳机未连接")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                heartRateValue(context.state.heartRateBPM, font: .system(size: 30, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .activityBackgroundTint(Color.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "heart.fill")
                        .font(.title2)
                        .foregroundStyle(.pink)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.isConnected ? "实时心率" : "耳机未连接")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        heartRateValue(context.state.heartRateBPM, font: .system(size: 32, weight: .semibold, design: .rounded))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Pods脉搏舱 · Your Heart. Your Rhythm.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
            } compactTrailing: {
                heartRateValue(
                    context.state.heartRateBPM,
                    font: .system(size: 15, weight: .semibold, design: .rounded),
                    showsUnit: false
                )
            } minimal: {
                ZStack {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 23, weight: .regular))
                        .foregroundStyle(Color.pink.opacity(0.58))
                    Text(context.state.heartRateBPM.map(String.init) ?? "--")
                        .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .contentTransition(.numericText())
                }
                .accessibilityLabel(context.state.heartRateBPM.map { "\($0) beats per minute" } ?? "Heart rate unavailable")
            }
            .keylineTint(.pink)
        }
    }

    @ViewBuilder
    private func heartRateValue(_ bpm: Int?, font: Font, showsUnit: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(bpm.map(String.init) ?? "--")
                .font(font.monospacedDigit())
                .contentTransition(.numericText())
            if showsUnit {
                Text("BPM")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
        .accessibilityLabel(bpm.map { "\($0) beats per minute" } ?? "Heart rate unavailable")
    }
}
