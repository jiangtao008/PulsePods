//
//  ContentView.swift
//  PulsePods
//

import AVFAudio
import ActivityKit
import Charts
import Foundation
import HealthKit
import SwiftUI

private enum PulsePodsCopy {
    static var language: String {
        UserDefaults.standard.string(forKey: "appLanguage") ?? "zh-Hans"
    }

    static var locale: Locale { Locale(identifier: language) }

    static func text(_ simplifiedChinese: String, _ english: String) -> String {
        language == "en" ? english : simplifiedChinese
    }
}

@MainActor
final class AirPodsConnectionMonitor: ObservableObject {
    @Published private(set) var isAirPodsProConnected = false
    @Published private(set) var connectedDeviceName: String?

    private var routeChangeObserver: NSObjectProtocol?

    init() {
        configureAudioSession()
        refreshConnection()
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshConnection() }
        }
    }

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    func refreshConnection() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.filter {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
        }
        connectedDeviceName = outputs.first?.portName
        isAirPodsProConnected = outputs.contains {
            $0.portName.localizedCaseInsensitiveContains("AirPods Pro")
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // The HealthKit workout flow doesn't depend on audio playback.
        }
    }
}

@available(iOS 26.0, *)
@MainActor
final class HeartRateWorkoutManager: NSObject, ObservableObject {
    @Published private(set) var heartRateBPM: Int?
    @Published private(set) var heartRateHistory: [HeartRatePoint] = []
    @Published private(set) var measurementStartedAt: Date?
    @Published private(set) var isStarting = false
    @Published private(set) var isMeasuring = false
    @Published private(set) var message = PulsePodsCopy.text("准备开始", "Ready")

    private let healthStore = HKHealthStore()
    private let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)!
    private var workoutSession: HKWorkoutSession?
    private var workoutBuilder: HKLiveWorkoutBuilder?
    private var liveActivity: Activity<PulsePodsActivityAttributes>?
    private var isAirPodsConnected = false

    func refreshMessageLanguage() {
        if isMeasuring {
            message = PulsePodsCopy.text(
                "测量中。请佩戴 AirPods Pro 3，至少戴入一只耳机。",
                "Measuring. Wear AirPods Pro 3 with at least one earbud in."
            )
        } else if isStarting {
            message = PulsePodsCopy.text("正在准备运动会话…", "Preparing workout session…")
        } else {
            message = PulsePodsCopy.text("准备开始", "Ready")
        }
    }

    func startMeasurement() {
        guard !isStarting, !isMeasuring else { return }
        guard HKHealthStore.isHealthDataAvailable() else {
            message = PulsePodsCopy.text("这台设备无法使用 Apple 健康数据", "Apple Health is unavailable on this device")
            return
        }

        isStarting = true
        heartRateBPM = nil
        heartRateHistory = []
        message = PulsePodsCopy.text("请在弹窗中允许读取心率并记录运动", "Allow heart rate access and workout recording when prompted")
        let workoutType = HKObjectType.workoutType()
        let typesToShare: Set<HKSampleType> = [workoutType]
        let typesToRead: Set<HKObjectType> = [heartRateType, workoutType]

        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.isStarting = false
                    self.message = PulsePodsCopy.text("健康数据授权失败：", "Health authorization failed: ") + error.localizedDescription
                    return
                }
                self.prepareWorkoutSession()
            }
        }
    }

    func stopMeasurement() {
        guard let workoutSession else { return }
        message = PulsePodsCopy.text("正在结束并保存运动记录…", "Ending and saving the workout…")
        workoutSession.stopActivity(with: Date())
    }

    private func prepareWorkoutSession() {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = .other
        configuration.locationType = .unknown

        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(
                healthStore: healthStore,
                workoutConfiguration: configuration
            )
            session.delegate = self
            builder.delegate = self
            workoutSession = session
            workoutBuilder = builder
            message = PulsePodsCopy.text("正在准备运动会话…", "Preparing workout session…")
            session.prepare()
        } catch {
            isStarting = false
            message = PulsePodsCopy.text("无法启动运动会话：", "Could not start workout session: ") + error.localizedDescription
        }
    }

    private func beginPreparedWorkout() {
        guard let workoutSession, let workoutBuilder else { return }
        let startDate = Date()
        workoutSession.startActivity(with: startDate)
        workoutBuilder.beginCollection(withStart: startDate) { [weak self] success, error in
            Task { @MainActor in
                guard let self else { return }
                self.isStarting = false
                if success {
                    self.isMeasuring = true
                    self.measurementStartedAt = startDate
                    self.message = PulsePodsCopy.text("测量中。请佩戴 AirPods Pro 3，至少戴入一只耳机。", "Measuring. Wear AirPods Pro 3 with at least one earbud in.")
                    self.startLiveActivity()
                } else {
                    self.message = PulsePodsCopy.text("无法开始收集运动数据：", "Could not start collecting workout data: ")
                        + (error?.localizedDescription ?? PulsePodsCopy.text("未知错误", "Unknown error"))
                    self.workoutSession?.stopActivity(with: Date())
                }
            }
        }
    }

    private func finishWorkout(at endDate: Date) {
        guard let builder = workoutBuilder else {
            HeartRateHistoryStore.save(samples: heartRateHistory, endDate: endDate)
            workoutSession?.end()
            resetAfterWorkout(message: PulsePodsCopy.text("测量已结束", "Measurement ended"))
            return
        }

        builder.endCollection(withEnd: endDate) { [weak self] _, collectionError in
            builder.finishWorkout { _, finishError in
                let error = finishError ?? collectionError
                let resultMessage = error.map {
                    PulsePodsCopy.text("测量已结束，但保存运动记录时出错：", "Measurement ended, but saving the workout failed: ")
                        + $0.localizedDescription
                } ?? PulsePodsCopy.text("测量结束，运动记录已保存到健康 App。", "Measurement ended. Workout saved to Apple Health.")
                guard let manager = self else { return }
                Task { @MainActor in
                    HeartRateHistoryStore.save(samples: manager.heartRateHistory, endDate: endDate)
                    manager.workoutSession?.end()
                    manager.resetAfterWorkout(message: resultMessage)
                }
            }
        }
    }

    private func resetAfterWorkout(message: String) {
        endLiveActivity()
        isStarting = false
        isMeasuring = false
        measurementStartedAt = nil
        self.message = message
        workoutSession = nil
        workoutBuilder = nil
    }

    func updateAirPodsConnection(_ isConnected: Bool) {
        isAirPodsConnected = isConnected
        publishLiveActivityState(heartRateBPM)
    }

    private func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let existingActivity = Activity<PulsePodsActivityAttributes>.activities.first {
            liveActivity = existingActivity
            publishLiveActivityState(heartRateBPM)
            return
        }

        let attributes = PulsePodsActivityAttributes(startedAt: Date())
        let state = PulsePodsActivityAttributes.ContentState(
            heartRateBPM: heartRateBPM,
            isConnected: isAirPodsConnected
        )
        do {
            liveActivity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            liveActivity = nil
        }
    }

    private func publishLiveActivityState(_ bpm: Int?) {
        let state = PulsePodsActivityAttributes.ContentState(
            heartRateBPM: bpm,
            isConnected: isAirPodsConnected
        )
        let activities = Activity<PulsePodsActivityAttributes>.activities
        if liveActivity == nil {
            liveActivity = activities.first
        }
        guard !activities.isEmpty else { return }
        Task {
            for activity in activities {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }
    }

    private func endLiveActivity() {
        guard let liveActivity else { return }
        self.liveActivity = nil
        Task { await liveActivity.end(nil, dismissalPolicy: .immediate) }
    }

    private func updateHeartRate(from builder: HKLiveWorkoutBuilder) {
        guard let quantity = builder.statistics(for: heartRateType)?.mostRecentQuantity() else { return }
        let unit = HKUnit.count().unitDivided(by: HKUnit.minute())
        let bpm = Int(quantity.doubleValue(for: unit).rounded())
        let now = Date()
        heartRateBPM = bpm
        heartRateHistory.append(HeartRatePoint(timestamp: now, bpm: bpm))
        publishLiveActivityState(bpm)
    }
}

@available(iOS 26.0, *)
struct HeartRatePoint: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let bpm: Int

    init(id: UUID = UUID(), timestamp: Date, bpm: Int) {
        self.id = id
        self.timestamp = timestamp
        self.bpm = bpm
    }
}

@available(iOS 26.0, *)
private struct ConnectionRoutePoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let isConnected: Bool
}

@available(iOS 26.0, *)
private struct HeartRatePlotPoint: Identifiable {
    let id: String
    let timestamp: Date
    let bpm: Int
    let seriesID: String

    init(id: String = UUID().uuidString, timestamp: Date, bpm: Int, seriesID: String = "heart-rate") {
        self.id = id
        self.timestamp = timestamp
        self.bpm = bpm
        self.seriesID = seriesID
    }
}

@available(iOS 26.0, *)
private struct DisconnectedInterval: Identifiable {
    let id: String
    let start: Date
    let end: Date
}

@available(iOS 26.0, *)
private struct HeartRateHistoryRecord: Identifiable, Codable {
    let id: UUID
    let endDate: Date
    let samples: [HeartRatePoint]

    init(id: UUID = UUID(), endDate: Date, samples: [HeartRatePoint]) {
        self.id = id
        self.endDate = endDate
        self.samples = samples
    }

    var title: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd hh:mm:ss"
        return formatter.string(from: endDate)
    }
}

@available(iOS 26.0, *)
private enum HeartRateHistoryStore {
    private static var fileURL: URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        try? FileManager.default.createDirectory(
            at: supportDirectory,
            withIntermediateDirectories: true
        )
        return supportDirectory.appendingPathComponent("HeartRateHistory.json")
    }

    static func load() -> [HeartRateHistoryRecord] {
        guard let data = try? Data(contentsOf: fileURL),
              let records = try? JSONDecoder().decode([HeartRateHistoryRecord].self, from: data) else {
            return []
        }
        return records.sorted { $0.endDate > $1.endDate }
    }

    static func save(samples: [HeartRatePoint], endDate: Date) {
        guard !samples.isEmpty else { return }
        var records = load()
        records.insert(HeartRateHistoryRecord(endDate: endDate, samples: samples), at: 0)
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}

@available(iOS 26.0, *)
private enum HeartRateChartRange: String, CaseIterable, Identifiable {
    case all = "All"
    case minute = "1m"
    case fiveMinutes = "5m"
    case hour = "1h"
    case threeHours = "3h"
    case twelveHours = "12h"

    var id: String { rawValue }

    var duration: TimeInterval? {
        switch self {
        case .all: nil
        case .minute: 60
        case .fiveMinutes: 5 * 60
        case .hour: 60 * 60
        case .threeHours: 3 * 60 * 60
        case .twelveHours: 12 * 60 * 60
        }
    }
}

@available(iOS 26.0, *)
extension HeartRateWorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState,
        date: Date
    ) {
        guard toState == .prepared || toState == .stopped else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if toState == .prepared {
                self.beginPreparedWorkout()
            } else {
                self.finishWorkout(at: date)
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.workoutSession?.end()
            self.resetAfterWorkout(message: PulsePodsCopy.text("运动会话失败：", "Workout session failed: ") + error.localizedDescription)
        }
    }
}

@available(iOS 26.0, *)
extension HeartRateWorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        Task { @MainActor [weak self] in
            guard let self,
                  collectedTypes.contains(self.heartRateType),
                  let builder = self.workoutBuilder else { return }
            self.updateHeartRate(from: builder)
        }
    }
}

struct ContentView: View {
    @StateObject private var connectionMonitor = AirPodsConnectionMonitor()
    @State private var hasEnteredMainPage = false
    @State private var shouldStartMeasurement = false
    @AppStorage("appLanguage") private var appLanguage = "zh-Hans"
    @AppStorage("appTheme") private var appTheme = "dark"

    var body: some View {
        NavigationStack {
            Group {
                if hasEnteredMainPage {
                    if #available(iOS 26.0, *) {
                        HeartRateMeasurementView(
                            connectionMonitor: connectionMonitor,
                            shouldStartMeasurement: $shouldStartMeasurement
                        )
                    } else {
                        ContentUnavailableView(
                            "需要 iOS 26",
                            systemImage: "heart.text.square",
                            description: Text("AirPods Pro 3 的心率测量需要 iOS 26 或更高版本。")
                        )
                    }
                } else {
                    AirPodsConnectionIntroView(
                        connectionMonitor: connectionMonitor,
                        onContinue: { hasEnteredMainPage = true },
                        onStartMeasurement: {
                            shouldStartMeasurement = true
                            hasEnteredMainPage = true
                        }
                    )
                }
            }
        }
        .environment(\.locale, Locale(identifier: appLanguage))
        .preferredColorScheme(appTheme == "dark" ? .dark : .light)
    }
}

private struct AirPodsConnectionIntroView: View {
    @ObservedObject var connectionMonitor: AirPodsConnectionMonitor
    let onContinue: () -> Void
    let onStartMeasurement: () -> Void

    @State private var showConnectedState = false
    @State private var showSkipButton = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "airpodspro")
                .font(.system(size: 78, weight: .regular))
                .foregroundStyle(showConnectedState ? Color.green : Color.secondary)
                .scaleEffect(showConnectedState ? 1 : 0.88)
                .contentTransition(.symbolEffect(.replace))
                .animation(.spring(response: 0.55, dampingFraction: 0.62), value: showConnectedState)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Pods脉搏舱")
                    .font(.largeTitle.bold())
                Text("Your Heart. Your Rhythm.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("AirPods 心率监测工具")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                Text(showConnectedState
                     ? PulsePodsCopy.text("已连接", "Connected")
                     : PulsePodsCopy.text("正在检查连接状态…", "Checking connection…"))
                    .font(.headline)
                    .foregroundStyle(showConnectedState ? Color.green : Color.secondary)
                    .contentTransition(.opacity)
            }

            if showConnectedState {
                Text("正在进入心率页面")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else if showSkipButton {
                VStack(spacing: 12) {
                    Button("直接开始测量") {
                        onStartMeasurement()
                    }
                    .font(.headline)
                    .buttonStyle(.borderedProminent)

                    Button("跳过") {
                        onContinue()
                    }
                    .font(.subheadline)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            VStack(spacing: 6) {
                Text("连接检测说明")
                    .font(.subheadline.weight(.semibold))
                Text("本 App 根据系统当前音频输出判断连接状态。请先播放音乐，并确认声音输出到 AirPods Pro 3；仅完成蓝牙配对时，页面可能不会显示已连接。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .task(id: connectionMonitor.isAirPodsProConnected) {
            showSkipButton = false
            guard connectionMonitor.isAirPodsProConnected else {
                showConnectedState = false
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, !connectionMonitor.isAirPodsProConnected else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    showSkipButton = true
                }
                return
            }

            withAnimation(.spring(response: 0.55, dampingFraction: 0.62)) {
                showConnectedState = true
            }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, connectionMonitor.isAirPodsProConnected else { return }
            onContinue()
        }
    }
}

@available(iOS 26.0, *)
private struct AboutPulsePodsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.pink.gradient)
                    .accessibilityHidden(true)
                Text("PulsePods")
                    .font(.title.bold())
                Text("Your Heart. Your Rhythm.")
                    .font(.headline)
                Text("AirPods 心率监测工具")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("关于")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

@available(iOS 26.0, *)
private struct PulsePodsSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = "zh-Hans"
    @AppStorage("appTheme") private var appTheme = "dark"

    var body: some View {
        Form {
            Section("语言") {
                Picker("语言", selection: $appLanguage) {
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                .pickerStyle(.segmented)
            }

            Section("外观") {
                Picker("外观", selection: $appTheme) {
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                .pickerStyle(.segmented)
            }
        }
            .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AirPodsConnectionDetailView: View {
    @ObservedObject var connectionMonitor: AirPodsConnectionMonitor

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "airpodspro")
                .font(.system(size: 72, weight: .regular))
                .foregroundStyle(connectionMonitor.isAirPodsProConnected ? Color.green : Color.orange)
                .accessibilityHidden(true)

            Text("AirPods Pro 3")
                .font(.largeTitle.bold())

            Text(PulsePodsCopy.text(
                connectionMonitor.isAirPodsProConnected ? "音频已连接" : "尚未连接",
                connectionMonitor.isAirPodsProConnected ? "Audio connected" : "Not connected"
            ))
                .font(.title3.weight(.medium))
                .foregroundStyle(connectionMonitor.isAirPodsProConnected ? Color.green : Color.orange)

            if !connectionMonitor.isAirPodsProConnected {
                Text("请连接并佩戴 AirPods Pro 3。连接后此页面会自动更新状态。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            VStack(spacing: 6) {
                Text("连接检测说明")
                    .font(.subheadline.weight(.semibold))
                Text("本 App 根据系统当前音频输出判断连接状态。请先播放音乐，并确认声音输出到 AirPods Pro 3；仅完成蓝牙配对时，页面可能不会显示已连接。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 24)

            Spacer()
        }
        .padding(.top, 64)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("连接状态")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@available(iOS 26.0, *)
private struct HeartRateMeasurementView: View {
    @ObservedObject var connectionMonitor: AirPodsConnectionMonitor
    @Binding var shouldStartMeasurement: Bool
    @StateObject private var workoutManager = HeartRateWorkoutManager()
    @AppStorage("appLanguage") private var appLanguage = "zh-Hans"
    @State private var selectedChartRange: HeartRateChartRange = .all
    @State private var isAboutPresented = false
    @State private var isSettingsPresented = false
    @State private var connectionRouteHistory: [ConnectionRoutePoint] = []
    @State private var chartNow = Date()
    @State private var didHandleEntryMeasurementStart = false
    @Namespace private var chartRangeNamespace

    var body: some View {
        GeometryReader { geometry in
          let availableHeight = geometry.size.height
          let spacing: CGFloat = availableHeight < 640 ? 6 : 10
          let heartRateFontSize = min(88, max(48, availableHeight * 0.12))
          let showsFooter = availableHeight > 440
          let footerHeight: CGFloat = showsFooter ? 32 : 0
          let chartChromeHeight: CGFloat = 170
          let fixedHeight = heartRateFontSize * 1.4
              + 52 + 36 + 30 + footerHeight
              + spacing * (showsFooter ? 4 : 3)
              + 12 + chartChromeHeight
          let chartPlotHeight = max(50, min(170, availableHeight - fixedHeight))

          VStack(spacing: spacing) {
            ZStack(alignment: .bottomTrailing) {
                Text(displayedHeartRateBPM.map(String.init) ?? "--")
                    .font(.system(size: heartRateFontSize, weight: .light, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)

                HStack(alignment: .bottom, spacing: 8) {
                    HeartRatePulseIcon(
                        bpm: displayedHeartRateBPM,
                        isMeasuring: workoutManager.isMeasuring
                    )
                    Text("次/分钟")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)

            measurementStatusRow

            heartRateChartCard(plotHeight: chartPlotHeight)

            if workoutManager.isMeasuring {
                HoldToStopMeasurementButton {
                    workoutManager.stopMeasurement()
                }
            } else {
                Button {
                    workoutManager.startMeasurement()
                } label: {
                    Text(PulsePodsCopy.text(
                        workoutManager.isStarting ? "正在准备测量…" : "开始测量",
                        workoutManager.isStarting ? "Preparing measurement…" : "Start measurement"
                    ))
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(workoutManager.isStarting)
            }

            Text(workoutManager.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 32)

            if showsFooter {
                Text("心率只在测量期间读取。请在系统弹窗中授权健康数据访问。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
          }
          .padding(.horizontal, 24)
          .padding(.vertical, 6)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle("Pods脉搏舱")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    AirPodsConnectionDetailView(connectionMonitor: connectionMonitor)
                } label: {
                    Image(systemName: "airpodspro")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(connectionMonitor.isAirPodsProConnected ? Color.green : Color.orange)
                }
                .accessibilityLabel(PulsePodsCopy.text(
                    connectionMonitor.isAirPodsProConnected ? "AirPods Pro 已连接，查看状态" : "AirPods Pro 未连接，查看状态",
                    connectionMonitor.isAirPodsProConnected ? "AirPods Pro connected, view status" : "AirPods Pro not connected, view status"
                ))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    Button {
                        connectionMonitor.refreshConnection()
                    } label: {
                        Label("刷新连接状态", systemImage: "arrow.clockwise")
                    }
                    Button {
                        isAboutPresented = true
                    } label: {
                        Label("关于 PulsePods", systemImage: "info.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("菜单")
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .sheet(isPresented: $isAboutPresented) {
            AboutPulsePodsView()
        }
        .navigationDestination(isPresented: $isSettingsPresented) {
            PulsePodsSettingsView()
        }
        .onAppear {
            chartNow = Date()
            recordConnectionRoute(connectionMonitor.isAirPodsProConnected)
            workoutManager.updateAirPodsConnection(connectionMonitor.isAirPodsProConnected)
            startMeasurementIfRequested()
        }
        .task(id: !connectionMonitor.isAirPodsProConnected || workoutManager.isMeasuring) {
            guard !connectionMonitor.isAirPodsProConnected || workoutManager.isMeasuring else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                chartNow = Date()
            }
        }
        .onChange(of: shouldStartMeasurement) { _, requested in
            if requested { startMeasurementIfRequested() }
        }
        .onChange(of: appLanguage) { _, _ in
            workoutManager.refreshMessageLanguage()
        }
        .onChange(of: workoutManager.isMeasuring) { _, isMeasuring in
            if isMeasuring { connectionMonitor.refreshConnection() }
        }
        .onChange(of: connectionMonitor.isAirPodsProConnected) { _, isConnected in
            recordConnectionRoute(isConnected)
            workoutManager.updateAirPodsConnection(isConnected)
            if isConnected { startMeasurementIfRequested() }
        }
    }

    private var displayedHeartRateBPM: Int? {
        connectionMonitor.isAirPodsProConnected ? workoutManager.heartRateBPM : nil
    }

    private var measurementStatusRow: some View {
        HStack(spacing: 8) {
            if workoutManager.isMeasuring, let startedAt = workoutManager.measurementStartedAt {
                Label {
                    Text(elapsedTime(since: startedAt, now: chartNow))
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "timer")
                }
                .accessibilityLabel(PulsePodsCopy.text("测量时长", "Duration"))
            }

            Spacer(minLength: 4)

            Label {
                Text(connectionStatusText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } icon: {
                Image(systemName: "airpodspro")
                    .foregroundStyle(connectionMonitor.isAirPodsProConnected ? Color.green : Color.orange)
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())
    }

    private var connectionStatusText: String {
        if connectionMonitor.isAirPodsProConnected {
            return PulsePodsCopy.text("AirPods 音频路由已连接", "AirPods audio routed")
        }
        if workoutManager.isMeasuring {
            return PulsePodsCopy.text("音频路由断开，测量继续", "Audio route off · measuring")
        }
        return PulsePodsCopy.text("AirPods 音频路由未连接", "AirPods audio not routed")
    }

    private func elapsedTime(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remainingSeconds)
    }

    private func recordConnectionRoute(_ isConnected: Bool) {
        guard connectionRouteHistory.last?.isConnected != isConnected else { return }
        connectionRouteHistory.append(ConnectionRoutePoint(timestamp: Date(), isConnected: isConnected))
    }

    private func startMeasurementIfRequested() {
        if shouldStartMeasurement {
            shouldStartMeasurement = false
            didHandleEntryMeasurementStart = true
            workoutManager.startMeasurement()
            return
        }

        guard connectionMonitor.isAirPodsProConnected,
              !didHandleEntryMeasurementStart else { return }
        didHandleEntryMeasurementStart = true
        workoutManager.startMeasurement()
    }

    private func heartRateChartCard(plotHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("心率趋势")
                            .font(.headline)
                        Text(chartSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    NavigationLink {
                        HeartRateHistoryListView()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("历史")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(
                            Color(uiColor: .tertiarySystemGroupedBackground),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("历史记录")
                }

                HStack(alignment: .center, spacing: 14) {
                    HeartRateRangeStatView(title: PulsePodsCopy.text("最高", "Max"), value: maximumHeartRate, color: .red)
                    HeartRateRangeStatView(title: PulsePodsCopy.text("最低", "Min"), value: minimumHeartRate, color: .blue)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("平均心率")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(averageHeartRate.map(String.init) ?? "--")
                                .font(.title3.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.orange)
                                .contentTransition(.numericText())
                            Text("BPM")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack(spacing: 3) {
                ForEach(HeartRateChartRange.allCases) { range in
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            selectedChartRange = range
                        }
                    } label: {
                        Text(range.rawValue)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(selectedChartRange == range ? .white : .secondary)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 34)
                            .background {
                                if selectedChartRange == range {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(Color.pink.gradient)
                                        .matchedGeometryEffect(id: "chart-range-selection", in: chartRangeNamespace)
                                }
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedChartRange == range ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: Capsule())

            Chart {
                ForEach(disconnectedIntervals) { interval in
                    RectangleMark(
                        xStart: .value("未连接开始", interval.start),
                        xEnd: .value("未连接结束", interval.end),
                        yStart: .value("区间下界", chartHeartRateRange.lowerBound),
                        yEnd: .value("区间上界", chartHeartRateRange.upperBound)
                    )
                    .foregroundStyle(Color.gray.opacity(0.12))
                }

                if let averageHeartRate {
                    RuleMark(y: .value("平均心率", averageHeartRate))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(Color.orange.opacity(0.9))
                }

                ForEach(chartHeartRatePoints) { point in
                    LineMark(
                        x: .value("时间", point.timestamp),
                        y: .value("心率", point.bpm),
                        series: .value("连接时段", point.seriesID)
                    )
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(Color.pink.gradient)
                }
            }
            .chartXScale(domain: chartTimeRange)
            .chartYScale(domain: chartHeartRateRange)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
                        .foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: xAxisDateFormat)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
                        .foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let bpm = value.as(Int.self) {
                            Text("\(bpm)")
                                .font(.system(size: 10, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: plotHeight)
            .overlay {
                if chartHeartRatePoints.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text(PulsePodsCopy.text(
                            workoutManager.heartRateHistory.isEmpty ? "开始测量后显示心率曲线" : "所选时间范围内暂无数据",
                            workoutManager.heartRateHistory.isEmpty ? "The heart rate chart appears after measurement starts" : "No data in the selected time range"
                        ))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityLabel(PulsePodsCopy.text(
                "\(selectedChartRange.rawValue)心率曲线",
                "\(selectedChartRange.rawValue) heart rate chart"
            ))
        }
        .padding(16)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.045), radius: 16, x: 0, y: 7)
    }

    private var visibleHeartRateHistory: [HeartRatePoint] {
        let timeFilteredHistory: [HeartRatePoint]
        if let duration = selectedChartRange.duration {
            let cutoff = chartNow.addingTimeInterval(-duration)
            timeFilteredHistory = workoutManager.heartRateHistory.filter { $0.timestamp >= cutoff }
        } else {
            timeFilteredHistory = workoutManager.heartRateHistory
        }

        let routePoints = connectionRouteHistory.sorted { $0.timestamp < $1.timestamp }
        return timeFilteredHistory.filter { sample in
            let stateAtSample = routePoints.last(where: { $0.timestamp <= sample.timestamp })?.isConnected
                ?? routePoints.first?.isConnected
                ?? connectionMonitor.isAirPodsProConnected
            return stateAtSample
        }
    }

    private var chartTimeRange: ClosedRange<Date> {
        if let duration = selectedChartRange.duration {
            let end = max(chartNow, visibleHeartRateHistory.last?.timestamp ?? chartNow)
            return end.addingTimeInterval(-duration)...end
        }
        let firstHeartRateDate = visibleHeartRateHistory.first?.timestamp
        let firstRouteDate = connectionRouteHistory.first?.timestamp
        guard let first = [firstHeartRateDate, firstRouteDate].compactMap({ $0 }).min() else {
            let now = Date()
            return now.addingTimeInterval(-60)...now
        }
        let lastHeartRateDate = visibleHeartRateHistory.last?.timestamp ?? first
        let lastRouteDate = connectionRouteHistory.last?.timestamp ?? first
        let currentStatusDate = connectionMonitor.isAirPodsProConnected ? first : chartNow
        let last = max(max(lastHeartRateDate, lastRouteDate), currentStatusDate)
        guard first < last else {
            return first.addingTimeInterval(-30)...first.addingTimeInterval(30)
        }
        return first...last
    }

    private var chartHeartRatePoints: [HeartRatePlotPoint] {
        let routePoints = connectionRouteHistory.sorted { $0.timestamp < $1.timestamp }
        return visibleHeartRateHistory.map { sample in
            let segmentID = routePoints.last(where: { $0.timestamp <= sample.timestamp })?.id.uuidString ?? "initial"
            return HeartRatePlotPoint(
                id: sample.id.uuidString,
                timestamp: sample.timestamp,
                bpm: sample.bpm,
                seriesID: segmentID
            )
        }
    }

    private var disconnectedIntervals: [DisconnectedInterval] {
        let range = chartTimeRange
        let routePoints = connectionRouteHistory.sorted { $0.timestamp < $1.timestamp }
        let stateAtStart = routePoints.last(where: { $0.timestamp <= range.lowerBound })?.isConnected
            ?? routePoints.first?.isConnected
            ?? connectionMonitor.isAirPodsProConnected
        var disconnectedStart: Date? = stateAtStart ? nil : range.lowerBound
        var intervals: [DisconnectedInterval] = []

        for routePoint in routePoints where routePoint.timestamp > range.lowerBound && routePoint.timestamp <= range.upperBound {
            if routePoint.isConnected {
                if let start = disconnectedStart, start < routePoint.timestamp {
                    intervals.append(DisconnectedInterval(
                        id: "gap-\(routePoint.id.uuidString)",
                        start: start,
                        end: routePoint.timestamp
                    ))
                }
                disconnectedStart = nil
            } else if disconnectedStart == nil {
                disconnectedStart = routePoint.timestamp
            }
        }

        if let start = disconnectedStart, start < range.upperBound {
            intervals.append(DisconnectedInterval(
                id: "gap-end-\(start.timeIntervalSince1970)",
                start: start,
                end: range.upperBound
            ))
        }
        return intervals
    }

    private var chartHeartRateRange: ClosedRange<Double> {
        guard !visibleHeartRateHistory.isEmpty else {
            return 50...180
        }
        let values = visibleHeartRateHistory.map(\.bpm)
        let minimum = max(30, (values.min() ?? 50) - 10)
        let maximum = max(minimum + 20, (values.max() ?? 180) + 10)
        return Double(minimum)...Double(maximum)
    }

    private var chartSummary: String {
        guard let latest = visibleHeartRateHistory.last else {
            return selectedChartRange == .all
                ? PulsePodsCopy.text("本次测量全部数据", "All session data")
                : PulsePodsCopy.text("最近 \(selectedChartRange.rawValue)", "Last \(selectedChartRange.rawValue)")
        }
        if selectedChartRange == .all {
            return PulsePodsCopy.text(
                "本次测量 · \(visibleHeartRateHistory.count) 个样本",
                "This session · \(visibleHeartRateHistory.count) samples"
            )
        }
        let time = latest.timestamp.formatted(.dateTime.locale(PulsePodsCopy.locale).hour().minute())
        return PulsePodsCopy.text(
            "最近 \(selectedChartRange.rawValue) · 更新于 \(time)",
            "Last \(selectedChartRange.rawValue) · Updated \(time)"
        )
    }

    private var averageHeartRate: Int? {
        guard !visibleHeartRateHistory.isEmpty else { return nil }
        let total = visibleHeartRateHistory.reduce(0) { $0 + $1.bpm }
        return Int((Double(total) / Double(visibleHeartRateHistory.count)).rounded())
    }

    private var maximumHeartRate: Int? {
        visibleHeartRateHistory.map(\.bpm).max()
    }

    private var minimumHeartRate: Int? {
        visibleHeartRateHistory.map(\.bpm).min()
    }

    private var xAxisDateFormat: Date.FormatStyle {
        switch selectedChartRange {
        case .all, .hour, .threeHours, .twelveHours:
            .dateTime.locale(PulsePodsCopy.locale).hour().minute()
        case .fiveMinutes, .minute:
            .dateTime.locale(PulsePodsCopy.locale).minute().second()
        }
    }
}

@available(iOS 26.0, *)
private struct HeartRateRangeStatView: View {
    let title: String
    let value: Int?
    let color: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value.map(String.init) ?? "--")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
        }
    }
}

@available(iOS 26.0, *)
private struct HeartRatePulseIcon: View {
    let bpm: Int?
    let isMeasuring: Bool

    var body: some View {
        TimelineView(
            .animation(minimumInterval: 1.0 / 30.0, paused: !isMeasuring || bpm == nil)
        ) { timeline in
            Image(systemName: "heart.fill")
                .font(.title2)
                .foregroundStyle(.pink)
                .scaleEffect(scale(at: timeline.date))
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    private func scale(at date: Date) -> CGFloat {
        guard isMeasuring, let bpm, bpm > 0 else { return 1 }

        let beatInterval = 60.0 / Double(bpm)
        let beatPhase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: beatInterval) / beatInterval
        let firstBeat = exp(-pow((beatPhase - 0.13) / 0.055, 2))
        let secondBeat = exp(-pow((beatPhase - 0.31) / 0.07, 2)) * 0.62
        return CGFloat(1 + 0.22 * max(firstBeat, secondBeat))
    }
}

@available(iOS 26.0, *)
private struct HoldToStopMeasurementButton: View {
    let onStop: () -> Void

    @State private var holdProgress = 0.0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.orange)

                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.red.opacity(0.55))
                    .frame(width: geometry.size.width * holdProgress)

                HStack(spacing: 9) {
                    Image(systemName: holdProgress > 0 ? "hand.point.up.left.fill" : "hand.tap.fill")
                    Text(PulsePodsCopy.text(
                        holdProgress > 0 ? "继续按住，结束测量…" : "长按 1 秒结束测量",
                        holdProgress > 0 ? "Keep holding to end…" : "Hold for 1 second to end"
                    ))
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(height: 56)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onLongPressGesture(
            minimumDuration: 1,
            maximumDistance: 80,
            perform: onStop,
            onPressingChanged: { isPressing in
                if isPressing {
                    holdProgress = 0
                    withAnimation(.linear(duration: 1)) {
                        holdProgress = 1
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) {
                        holdProgress = 0
                    }
                }
            }
        )
        .accessibilityElement()
        .accessibilityLabel(PulsePodsCopy.text("长按 1 秒结束测量", "Hold for 1 second to end measurement"))
    }
}

@available(iOS 26.0, *)
private struct HeartRateHistoryListView: View {
    @State private var records = HeartRateHistoryStore.load()

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "还没有历史记录",
                    systemImage: "heart.text.square",
                    description: Text("结束一次心率测量后，记录会显示在这里。")
                )
            } else {
                List(records) { record in
                    NavigationLink {
                        HeartRateHistoryDetailView(record: record)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "heart.fill")
                                .foregroundStyle(.pink)
                                .frame(width: 34, height: 34)
                                .background(.pink.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title)
                                    .font(.body.weight(.medium))
                Text(PulsePodsCopy.text(
                    "\(record.samples.count) 个心率样本",
                    "\(record.samples.count) heart rate samples"
                ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let average = Self.average(for: record.samples) {
                                Text("\(average) BPM")
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("历史记录")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { records = HeartRateHistoryStore.load() }
    }

    private static func average(for samples: [HeartRatePoint]) -> Int? {
        guard !samples.isEmpty else { return nil }
        let total = samples.reduce(0) { $0 + $1.bpm }
        return Int((Double(total) / Double(samples.count)).rounded())
    }
}

@available(iOS 26.0, *)
private struct HeartRateHistoryDetailView: View {
    let record: HeartRateHistoryRecord

    private var averageHeartRate: Int? {
        guard !record.samples.isEmpty else { return nil }
        let total = record.samples.reduce(0) { $0 + $1.bpm }
        return Int((Double(total) / Double(record.samples.count)).rounded())
    }

    private var heartRateRange: ClosedRange<Double> {
        guard !record.samples.isEmpty else { return 50...180 }
        let values = record.samples.map(\.bpm)
        let lower = max(30, (values.min() ?? 50) - 10)
        let upper = max(lower + 20, (values.max() ?? 180) + 10)
        return Double(lower)...Double(upper)
    }

    private var timeRange: ClosedRange<Date> {
        guard let first = record.samples.first?.timestamp,
              let last = record.samples.last?.timestamp else {
            return record.endDate.addingTimeInterval(-30)...record.endDate.addingTimeInterval(30)
        }
        guard first < last else { return first.addingTimeInterval(-30)...first.addingTimeInterval(30) }
        return first...last
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("平均心率")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(averageHeartRate.map(String.init) ?? "--")
                                .font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(.orange)
                            Text("BPM")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("测量结束")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(record.title)
                            .font(.subheadline.weight(.medium))
                    }
                }

                Chart {
                    if let averageHeartRate {
                        RuleMark(y: .value("平均心率", averageHeartRate))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                            .foregroundStyle(Color.orange.opacity(0.9))
                    }
                    ForEach(record.samples) { point in
                        LineMark(
                            x: .value("时间", point.timestamp),
                            y: .value("心率", point.bpm)
                        )
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(Color.pink.gradient)
                    }
                }
                .chartXScale(domain: timeRange)
                .chartYScale(domain: heartRateRange)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
                            .foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(date, format: .dateTime.hour().minute().second())
                                    .font(.system(size: 10, design: .rounded))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7, dash: [3, 4]))
                            .foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let bpm = value.as(Int.self) {
                                Text("\(bpm)")
                                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                            }
                        }
                    }
                }
                .frame(height: 280)
                .padding(16)
                .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                Text(PulsePodsCopy.text(
                    "共 \(record.samples.count) 个心率样本",
                    "\(record.samples.count) heart rate samples"
                ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(record.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
