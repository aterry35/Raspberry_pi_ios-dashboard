//
//  ContentView.swift
//  SenseHat_dashboard
//
//  Created by Agnelterry Thiburcius on 4/3/26.
//

import SwiftUI
import UIKit

private enum DashboardTab: Hashable {
    case mqtt
    case senseHat
    case publish
    case stream
    case cam
}

private enum DashboardPalette {
    static let background = Color(red: 0.03, green: 0.05, blue: 0.10)
    static let surface = Color(red: 0.07, green: 0.10, blue: 0.16)
    static let blue = Color(red: 0.23, green: 0.59, blue: 0.98)
    static let cyan = Color(red: 0.18, green: 0.82, blue: 0.86)
    static let green = Color(red: 0.20, green: 0.83, blue: 0.52)
    static let amber = Color(red: 0.97, green: 0.72, blue: 0.22)
    static let violet = Color(red: 0.58, green: 0.43, blue: 0.96)
    static let rose = Color(red: 0.95, green: 0.38, blue: 0.60)
    static let slate = Color(red: 0.50, green: 0.60, blue: 0.75)
    static let fieldFill = LinearGradient(
        colors: [
            Color.white.opacity(0.08),
            Color.black.opacity(0.18)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct ContentView: View {
    @AppStorage("brokerIPAddress") private var ipAddress: String = "192.168.1.247"
    @AppStorage("brokerPort") private var port: String = "1884"
    @AppStorage("rtspStreamURL") private var rtspStreamURL: String = "rtsp://192.168.1.236:8554/stream"
    @AppStorage("cameraHTTPURL") private var cameraHTTPURL: String = "http://192.168.1.225"
    @AppStorage("didClearLegacyLocalDefaults") private var didClearLegacyLocalDefaults: Bool = false

    @StateObject private var mqttManager = MQTTManager()
    @State private var selectedTab: DashboardTab = .mqtt
    @State private var customMessage: String = ""
    @State private var publisherTopic: String = ""
    @State private var publisherPayload: String = ""
    @State private var activeStreamURL: String?
    @State private var streamPlaybackState: RTSPPlaybackState = .idle
    @State private var streamStatusMessage: String = "Player idle. Send the SmartCam MQTT command first, then tap Start Player to open the RTSP viewer."
    @State private var streamLastError: String?
    @State private var streamReloadToken: Int = 0
    @State private var activeCameraURL: String?
    @State private var cameraStreamState: HTTPStreamState = .idle
    @State private var cameraStatusMessage: String = "Tap Load Cam to open the HTTP camera feed."
    @State private var cameraLastError: String?
    @State private var cameraReloadToken: Int = 0

    private let twoColumnLayout = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14)
    ]

    var body: some View {
        ZStack {
            backgroundView

            TabView(selection: $selectedTab) {
                configurationTab
                    .tag(DashboardTab.mqtt)
                    .tabItem {
                        Label("MQTT", systemImage: "antenna.radiowaves.left.and.right")
                    }

                senseHatTab
                    .tag(DashboardTab.senseHat)
                    .tabItem {
                        Label("Sense HAT", systemImage: "sensor.tag.radiowaves.forward")
                    }

                publishTab
                    .tag(DashboardTab.publish)
                    .tabItem {
                        Label("Publish", systemImage: "paperplane.circle")
                    }

                streamTab
                    .tag(DashboardTab.stream)
                    .tabItem {
                        Label("RTSP", systemImage: "video.circle")
                    }

                camTab
                    .tag(DashboardTab.cam)
                    .tabItem {
                        Label("Cam", systemImage: "camera.viewfinder")
                    }
            }
            .toolbarColorScheme(.dark, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .toolbarBackground(Color.black.opacity(0.88), for: .tabBar)
        }
        .preferredColorScheme(.dark)
        .task {
            migrateBrokerDefaultsIfNeeded()
            if shouldAutoConnect(for: selectedTab) {
                connectUsingSavedSettingsIfNeeded()
            }
        }
        .task(id: selectedTab) {
            await runSenseHatPollingLoopIfNeeded()
        }
        .onChange(of: selectedTab) { _, newValue in
            if shouldAutoConnect(for: newValue) {
                connectUsingSavedSettingsIfNeeded()
            }
        }
        .onChange(of: mqttManager.smartCamStreamState) { _, _ in
            syncStreamWithSmartCamStatus()
        }
        .onChange(of: mqttManager.smartCamRTSPURL) { _, _ in
            syncStreamWithSmartCamStatus()
        }
    }

    private var backgroundView: some View {
        ZStack {
            DashboardPalette.background
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color.black,
                    DashboardPalette.surface.opacity(0.94),
                    Color.black
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            RadialGradient(
                colors: [DashboardPalette.blue.opacity(0.34), .clear],
                center: .topLeading,
                startRadius: 40,
                endRadius: 380
            )
            .offset(x: -90, y: -130)

            RadialGradient(
                colors: [DashboardPalette.green.opacity(0.24), .clear],
                center: .bottomTrailing,
                startRadius: 70,
                endRadius: 420
            )
            .offset(x: 120, y: 180)

            RadialGradient(
                colors: [DashboardPalette.violet.opacity(0.22), .clear],
                center: .center,
                startRadius: 20,
                endRadius: 320
            )

            VStack {
                HStack {
                    Circle()
                        .fill(DashboardPalette.cyan.opacity(0.65))
                        .frame(width: 140, height: 140)
                        .blur(radius: 90)
                    Spacer()
                }
                Spacer()
                HStack {
                    Spacer()
                    Circle()
                        .fill(DashboardPalette.rose.opacity(0.45))
                        .frame(width: 180, height: 180)
                        .blur(radius: 120)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 40)
            .ignoresSafeArea()
        }
    }

    private var configurationTab: some View {
        ConfigurationTabView(
            heroCard: heroCard,
            brokerSettingsCard: brokerSettingsCard,
            mqttContractCard: mqttContractCard,
            logCard: logCard
        )
    }

    private var senseHatTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                liveTelemetryCard
                sensorGrid
                controlsCard
                snakeGameCard
                diagnosticsCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .padding(.bottom, 24)
        }
    }

    private var publishTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                publisherHeroCard
                publisherComposerCard
                publisherQuickTopicsCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .padding(.bottom, 24)
        }
    }

    private var streamTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                streamHeroCard
                streamViewerCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .padding(.bottom, 24)
        }
    }

    private var camTab: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                camHeroCard
                camViewerCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .padding(.bottom, 24)
        }
    }

    private var heroCard: some View {
        DashboardPanel(tint: mqttManager.connectionTint, badge: "Night Console") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sense HAT Link")
                        .font(.system(size: 31, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(mqttManager.connectionTitle)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(mqttManager.connectionTint)

                    Text(mqttManager.connectionDetail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.76))

                    HStack(spacing: 10) {
                        StatusPill(
                            label: mqttManager.isConnected ? "Broker Live" : "Idle",
                            tint: mqttManager.connectionTint
                        )
                        StatusPill(
                            label: shouldAutoConnect(for: selectedTab) ? "Auto Connect Armed" : "Ready",
                            tint: DashboardPalette.slate
                        )
                    }
                }

                Spacer(minLength: 0)

                ZStack {
                    Circle()
                        .fill(mqttManager.connectionTint.opacity(0.18))
                        .frame(width: 72, height: 72)

                    Image(systemName: mqttManager.connectionIconName)
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(mqttManager.connectionTint)
                }
            }
        }
    }

    private var publisherHeroCard: some View {
        DashboardPanel(tint: DashboardPalette.rose, badge: "Raw Publisher") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Any Topic, Any Payload")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Use this tab to send plain text or JSON payloads to any MQTT topic on the broker session opened from this app.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.76))
                    }

                    Spacer(minLength: 0)

                    StatusPill(
                        label: mqttManager.isConnected ? "Session Reused" : "Needs Broker",
                        tint: mqttManager.isConnected ? DashboardPalette.rose : DashboardPalette.slate
                    )
                }

                HStack(spacing: 12) {
                    DataHighlightTile(
                        label: "Connected Broker",
                        value: mqttManager.activeBrokerSummary,
                        icon: "network",
                        tint: DashboardPalette.rose
                    )

                    DataHighlightTile(
                        label: "Payload Mode",
                        value: payloadModeLabel,
                        icon: payloadLooksLikeJSON ? "curlybraces.square.fill" : "text.bubble.fill",
                        tint: payloadLooksLikeJSON ? DashboardPalette.cyan : DashboardPalette.amber
                    )
                }
            }
        }
    }

    private var streamHeroCard: some View {
        DashboardPanel(tint: DashboardPalette.violet, badge: "RTSP Viewer") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Live Camera Stream")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("The stream is on-demand. Use the SmartCam controls to send MQTT start or stop, then use the Player controls to open or close the RTSP viewer independently.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.76))
                    }

                    Spacer(minLength: 0)

                    StatusPill(
                        label: streamPlaybackState.label,
                        tint: streamStatusTint
                    )
                }

                HStack(spacing: 12) {
                    DataHighlightTile(
                        label: "SmartCam MQTT",
                        value: smartCamStateLabel,
                        icon: "switch.2",
                        tint: smartCamStateTint
                    )

                    DataHighlightTile(
                        label: "Player State",
                        value: streamPlaybackState.label,
                        icon: streamStateIconName,
                        tint: streamStatusTint
                    )
                }

                contractRow(label: "Control Topic", value: mqttManager.smartCamControlTopic)
                contractRow(label: "Status Topic", value: mqttManager.smartCamStatusTopic)
                contractRow(label: "RTSP URL", value: activeStreamURL ?? mqttManager.smartCamRTSPURL ?? rtspStreamURL)
            }
        }
    }

    private var brokerSettingsCard: some View {
        BrokerSettingsCardView(
            ipAddress: $ipAddress,
            port: $port,
            twoColumnLayout: twoColumnLayout,
            onSave: saveBrokerSettings,
            onConnect: { connectUsingSavedSettings(forceReconnect: true) },
            onDisconnect: mqttManager.disconnect,
            onReset: resetDefaults,
            buttonBuilder: flatActionButton
        )
    }

    private var mqttContractCard: some View {
        DashboardPanel(tint: DashboardPalette.cyan, badge: "Topic Map") {
            VStack(alignment: .leading, spacing: 12) {
                contractRow(label: "Broker", value: "\(ipAddress):\(port)")
                contractRow(label: "Sense Status", value: mqttManager.senseHatStatusTopic)
                contractRow(label: "Sense Ctrl", value: mqttManager.senseHatControlTopic)
                contractRow(label: "Snake Ctrl", value: mqttManager.senseHatControlTopic)
                contractRow(label: "Snake Status", value: mqttManager.senseHatStatusTopic)
                contractRow(label: "Pi Monitor", value: mqttManager.piMonitorStatusTopic)
                contractRow(label: "Cam Ctrl", value: mqttManager.smartCamControlTopic)
                contractRow(label: "Cam Status", value: mqttManager.smartCamStatusTopic)
                contractRow(label: "Cam Pan", value: mqttManager.cameraPanTopic)
                contractRow(label: "Cam Tilt", value: mqttManager.cameraTiltTopic)
                contractRow(label: "Publisher", value: "The other MQTT clients on the same broker")
                contractRow(label: "Cadence", value: "~\(mqttManager.publishIntervalSeconds) seconds")

                Text("The Sense HAT tab now polls \(mqttManager.senseHatControlTopic) with read_once, uses that same control topic for snake commands, listens for replies on \(mqttManager.senseHatStatusTopic), and keeps \(mqttManager.piMonitorStatusTopic) available for Pi-side diagnostics.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.top, 6)
            }
        }
    }

    private var logCard: some View {
        DashboardPanel(tint: DashboardPalette.violet, badge: "Session Log") {
            ScrollView {
                Text(mqttManager.logsText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    )
            }
            .frame(height: 210)
        }
    }

    private var liveTelemetryCard: some View {
        DashboardPanel(tint: DashboardPalette.green, badge: "Live Feed") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sense HAT Stream")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text(mqttManager.isConnected ? "Broker session is active. The app sends read_once requests and listens for Sense HAT status replies." : "Open this page to auto-connect and start polling the Sense HAT status topic.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.76))
                    }

                    Spacer(minLength: 0)

                    StatusPill(
                        label: mqttManager.isConnected ? "Listening" : "Standby",
                        tint: mqttManager.isConnected ? DashboardPalette.green : DashboardPalette.slate
                    )
                }

                HStack(spacing: 12) {
                    DataHighlightTile(
                        label: "Temperature",
                        value: mqttManager.temperatureValue,
                        icon: "thermometer.medium",
                        tint: DashboardPalette.blue
                    )

                    DataHighlightTile(
                        label: "Pressure",
                        value: mqttManager.pressureValue,
                        icon: "gauge.medium",
                        tint: DashboardPalette.cyan
                    )
                }

                if let reading = mqttManager.latestReading {
                    Text("Last update: \(reading.timestampDate.formatted(date: .abbreviated, time: .standard))")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.68))
                } else {
                    Text("No Sense HAT reading received yet. Confirm the Pi 3 is replying on \(mqttManager.senseHatStatusTopic) after each read_once request.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.68))
                }
            }
        }
    }

    private var sensorGrid: some View {
        LazyVGrid(columns: twoColumnLayout, spacing: 14) {
            MetricTile(
                title: "Temperature",
                value: mqttManager.temperatureValue,
                icon: "thermometer.sun.fill",
                tint: DashboardPalette.blue
            )
            MetricTile(
                title: "Humidity",
                value: mqttManager.humidityValue,
                icon: "humidity.fill",
                tint: DashboardPalette.green
            )
            MetricTile(
                title: "Pressure",
                value: mqttManager.pressureValue,
                icon: "gauge.open.with.lines.needle.33percent",
                tint: DashboardPalette.cyan
            )
            MetricTile(
                title: "Acceleration",
                value: mqttManager.accelerationValue,
                icon: "move.3d",
                tint: DashboardPalette.violet
            )
            MetricTile(
                title: "Gyroscope",
                value: mqttManager.gyroscopeValue,
                icon: "gyroscope",
                tint: DashboardPalette.amber
            )
            MetricTile(
                title: "Orientation",
                value: mqttManager.orientationValue,
                icon: "angle",
                tint: DashboardPalette.rose
            )
        }
    }

    private var controlsCard: some View {
        DashboardPanel(tint: DashboardPalette.amber, badge: "Command Deck") {
            VStack(alignment: .leading, spacing: 16) {
                Text("These controls publish the live Sense HAT JSON actions you verified on the Pi 3, including blink, lights_off, read_once, and snake commands.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))

                LazyVGrid(columns: twoColumnLayout, spacing: 12) {
                    commandTile(
                        title: "Read Sensors",
                        subtitle: "Publish read_once",
                        icon: "waveform.path.ecg.rectangle.fill",
                        tint: DashboardPalette.green
                    ) {
                        connectUsingSavedSettingsIfNeeded()
                        mqttManager.requestSenseHatReading()
                    }

                    commandTile(
                        title: "Blink",
                        subtitle: "Publish blink",
                        icon: "lightbulb.max.fill",
                        tint: DashboardPalette.green
                    ) {
                        connectUsingSavedSettingsIfNeeded()
                        mqttManager.blinkSenseHat()
                    }

                    commandTile(
                        title: "Lights Off",
                        subtitle: "Publish lights_off",
                        icon: "moon.stars.fill",
                        tint: DashboardPalette.rose
                    ) {
                        connectUsingSavedSettingsIfNeeded()
                        mqttManager.lightsOff()
                    }

                    commandTile(
                        title: "Clear Matrix",
                        subtitle: "Publish clear",
                        icon: "sparkles.square.filled.on.square",
                        tint: DashboardPalette.violet
                    ) {
                        connectUsingSavedSettingsIfNeeded()
                        mqttManager.clearSenseHatDisplay()
                    }

                    commandTile(
                        title: "Show Time",
                        subtitle: "Publish show_text",
                        icon: "clock.fill",
                        tint: DashboardPalette.amber
                    ) {
                        connectUsingSavedSettingsIfNeeded()
                        mqttManager.showTime()
                    }

                    commandTile(
                        title: "Reconnect Feed",
                        subtitle: "Refresh the session",
                        icon: "arrow.clockwise.circle.fill",
                        tint: DashboardPalette.blue
                    ) {
                        connectUsingSavedSettings(forceReconnect: true)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Custom Message")
                        .font(.headline)
                        .foregroundStyle(.white)

                    TextField("Type a message for the Sense HAT display", text: $customMessage)
                        .padding(14)
                        .background(DashboardPalette.fieldFill)
                        .foregroundStyle(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        performButtonAction {
                            let message = customMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !message.isEmpty else {
                                mqttManager.recordUIEvent("Skipped publish because the custom message was empty.")
                                return
                            }

                            connectUsingSavedSettingsIfNeeded()
                            mqttManager.sendMessage(message)
                            customMessage = ""
                        }
                    } label: {
                        HStack {
                            Image(systemName: "paperplane.fill")
                            Text("Send Message")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(DashboardPressButtonStyle())
                    .foregroundStyle(.white)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [DashboardPalette.blue.opacity(0.9), DashboardPalette.violet.opacity(0.92)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .disabled(!mqttManager.isConnected)
                    .opacity(mqttManager.isConnected ? 1 : 0.55)
                }
            }
        }
    }

    private var snakeGameCard: some View {
        DashboardPanel(tint: DashboardPalette.cyan, badge: "Snake Game") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Use the Sense HAT control topic to start or stop the interactive snake game on the Pi 3.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))

                HStack(spacing: 12) {
                    DataHighlightTile(
                        label: "Snake State",
                        value: mqttManager.snakeState.replacingOccurrences(of: "_", with: " ").capitalized,
                        icon: "gamecontroller.fill",
                        tint: snakeStateTint
                    )

                    DataHighlightTile(
                        label: "Mode",
                        value: mqttManager.snakeMode.replacingOccurrences(of: "_", with: " ").capitalized,
                        icon: "square.grid.3x3.fill",
                        tint: DashboardPalette.violet
                    )
                }

                LazyVGrid(columns: twoColumnLayout, spacing: 12) {
                    flatActionButton(
                        title: "Start Snake",
                        subtitle: "Publish start_snake",
                        icon: "play.circle.fill",
                        tint: DashboardPalette.green
                    ) {
                        connectUsingSavedSettingsIfNeeded()
                        mqttManager.startSnakeGame()
                    }

                    flatActionButton(
                        title: "Stop Snake",
                        subtitle: "Publish stop_snake",
                        icon: "stop.circle.fill",
                        tint: DashboardPalette.rose
                    ) {
                        connectUsingSavedSettingsIfNeeded()
                        mqttManager.stopSnakeGame()
                    }
                }

                Text(mqttManager.snakeStatusDetail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private var diagnosticsCard: some View {
        DashboardPanel(tint: DashboardPalette.slate, badge: "Diagnostics") {
            VStack(alignment: .leading, spacing: 12) {
                contractRow(label: "Connection", value: mqttManager.connectionTitle)
                contractRow(label: "Broker", value: mqttManager.activeBrokerSummary)
                contractRow(label: "Status Topic", value: mqttManager.senseHatStatusTopic)
                contractRow(label: "Control Topic", value: mqttManager.senseHatControlTopic)
                contractRow(label: "Monitor Topic", value: mqttManager.piMonitorStatusTopic)
                contractRow(label: "Last Sent", value: mqttManager.lastSentCommand ?? "None")
                contractRow(label: "Decode Error", value: mqttManager.lastDecodeError ?? "None")

                VStack(alignment: .leading, spacing: 8) {
                    Text("Last Raw Payload")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))

                    Text(mqttManager.lastRawPayload ?? "No telemetry payload received yet.")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.black.opacity(0.25))
                        )
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Last Pi Monitor Payload")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))

                    Text(mqttManager.lastPiMonitorPayload ?? "No Pi monitor payload received yet.")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.black.opacity(0.25))
                        )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Last Snake Status Payload")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))

                    Text(mqttManager.snakeLastStatusPayload ?? "No snake status payload received yet.")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.86))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(Color.black.opacity(0.25))
                        )
                }
            }
        }
    }

    private var publisherComposerCard: some View {
        DashboardPanel(tint: DashboardPalette.blue, badge: "Composer") {
            VStack(alignment: .leading, spacing: 16) {
                fieldStack(title: "MQTT Topic", text: $publisherTopic, keyboardType: .default)

                VStack(alignment: .leading, spacing: 8) {
                    Text("PAYLOAD")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.58))

                    ZStack(alignment: .topLeading) {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(DashboardPalette.fieldFill)

                        if publisherPayload.isEmpty {
                            Text("Paste a raw message or JSON body here")
                                .foregroundStyle(.white.opacity(0.34))
                                .padding(.horizontal, 18)
                                .padding(.vertical, 18)
                        }

                        TextEditor(text: $publisherPayload)
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .foregroundStyle(.white)
                            .frame(minHeight: 180)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                }

                HStack(spacing: 10) {
                    StatusPill(
                        label: payloadLooksLikeJSON ? "JSON Candidate" : "Text Payload",
                        tint: payloadLooksLikeJSON ? DashboardPalette.cyan : DashboardPalette.amber
                    )

                    if !publisherTopic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        StatusPill(
                            label: "Topic Ready",
                            tint: DashboardPalette.green
                        )
                    }
                }

                Button {
                    performButtonAction {
                        mqttManager.publish(topic: publisherTopic, payload: publisherPayload)
                    }
                } label: {
                    HStack {
                        Image(systemName: "paperplane.fill")
                        Text("Publish Payload")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                }
                .buttonStyle(DashboardPressButtonStyle())
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [DashboardPalette.green.opacity(0.95), DashboardPalette.blue.opacity(0.88)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .disabled(!mqttManager.isConnected)
                .opacity(mqttManager.isConnected ? 1 : 0.55)
            }
        }
    }

    private var publisherQuickTopicsCard: some View {
        DashboardPanel(tint: DashboardPalette.violet, badge: "Quick Fill") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Seed the composer with a known topic, then replace it with any custom topic you want.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))

                LazyVGrid(columns: twoColumnLayout, spacing: 12) {
                    flatActionButton(
                        title: "Sense HAT Status",
                        subtitle: "Use status topic",
                        icon: "waveform.path.ecg.rectangle.fill",
                        tint: DashboardPalette.cyan
                    ) {
                        publisherTopic = mqttManager.senseHatStatusTopic
                    }

                    flatActionButton(
                        title: "Sense HAT Control",
                        subtitle: "Use control topic",
                        icon: "switch.2",
                        tint: DashboardPalette.violet
                    ) {
                        publisherTopic = mqttManager.senseHatControlTopic
                        publisherPayload = #"{"action":"read_once"}"#
                    }

                    flatActionButton(
                        title: "Blink",
                        subtitle: "Use Sense HAT control",
                        icon: "lightbulb.max.fill",
                        tint: DashboardPalette.green
                    ) {
                        publisherTopic = mqttManager.senseHatControlTopic
                        publisherPayload = #"{"action":"blink"}"#
                    }

                    flatActionButton(
                        title: "Snake Start",
                        subtitle: "Use Sense HAT control",
                        icon: "gamecontroller.fill",
                        tint: DashboardPalette.cyan
                    ) {
                        publisherTopic = mqttManager.senseHatControlTopic
                        publisherPayload = #"{"action":"start_snake"}"#
                    }

                    flatActionButton(
                        title: "Snake Stop",
                        subtitle: "Use Sense HAT control",
                        icon: "stop.circle.fill",
                        tint: DashboardPalette.rose
                    ) {
                        publisherTopic = mqttManager.senseHatControlTopic
                        publisherPayload = #"{"action":"stop_snake"}"#
                    }

                    flatActionButton(
                        title: "SmartCam Control",
                        subtitle: "Use stream control topic",
                        icon: "video.badge.waveform.fill",
                        tint: DashboardPalette.green
                    ) {
                        publisherTopic = mqttManager.smartCamControlTopic
                        publisherPayload = #"{"action":"start_stream"}"#
                    }

                    flatActionButton(
                        title: "SmartCam Status",
                        subtitle: "Use status topic",
                        icon: "dot.radiowaves.left.and.right",
                        tint: DashboardPalette.violet
                    ) {
                        publisherTopic = mqttManager.smartCamStatusTopic
                    }

                    flatActionButton(
                        title: "Pi Monitor Status",
                        subtitle: "Use monitor topic",
                        icon: "desktopcomputer.trianglebadge.exclamationmark",
                        tint: DashboardPalette.amber
                    ) {
                        publisherTopic = mqttManager.piMonitorStatusTopic
                    }

                    flatActionButton(
                        title: "Sample JSON",
                        subtitle: "Drop in JSON payload",
                        icon: "curlybraces.square.fill",
                        tint: DashboardPalette.blue
                    ) {
                        publisherPayload = """
                        {
                          "message": "Hello from iOS",
                          "sent_at": "\(Date.now.formatted(date: .abbreviated, time: .standard))"
                        }
                        """
                    }

                    flatActionButton(
                        title: "Clear Composer",
                        subtitle: "Reset topic and payload",
                        icon: "eraser.fill",
                        tint: DashboardPalette.rose
                    ) {
                        publisherTopic = ""
                        publisherPayload = ""
                    }
                }
            }
        }
    }

    private var streamViewerCard: some View {
        DashboardPanel(tint: DashboardPalette.cyan, badge: "Viewer") {
            VStack(alignment: .leading, spacing: 16) {
                fieldStack(title: "Stream URL", text: $rtspStreamURL, keyboardType: .URL)

                VStack(alignment: .leading, spacing: 12) {
                    Text("SMARTCAM SERVER")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.58))

                    LazyVGrid(columns: twoColumnLayout, spacing: 12) {
                        flatActionButton(
                            title: "Start Stream",
                            subtitle: "Send MQTT start_stream",
                            icon: "play.circle.fill",
                            tint: DashboardPalette.green
                        ) {
                            startStream()
                        }

                        flatActionButton(
                            title: "Stop Stream",
                            subtitle: "Send MQTT stop_stream",
                            icon: "stop.circle.fill",
                            tint: DashboardPalette.rose
                        ) {
                            stopStream()
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("LOCAL PLAYER")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.58))

                    LazyVGrid(columns: twoColumnLayout, spacing: 12) {
                        flatActionButton(
                            title: "Start Player",
                            subtitle: "Open RTSP locally",
                            icon: "video.fill",
                            tint: DashboardPalette.cyan
                        ) {
                            startPlayer()
                        }

                        flatActionButton(
                            title: "Stop Player",
                            subtitle: "Close local viewer",
                            icon: "video.slash.fill",
                            tint: DashboardPalette.slate
                        ) {
                            stopPlayer()
                        }
                    }
                }

                RTSPPlayerView(
                    streamURL: activeStreamURL,
                    reloadToken: streamReloadToken,
                    onStateChange: handleStreamPlayerUpdate
                )
                    .frame(minHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    )

                VStack(alignment: .leading, spacing: 8) {
                    Text(streamStatusMessage)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.72))

                    Text(mqttManager.smartCamStatusDetail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.68))
                }

                if let streamLastError {
                    Text(streamLastError)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(DashboardPalette.rose.opacity(0.18))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(DashboardPalette.rose.opacity(0.42), lineWidth: 1)
                        )
                }

            }
        }
    }

    private var camHeroCard: some View {
        DashboardPanel(tint: DashboardPalette.blue, badge: "HTTP Camera") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Camera Feed")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("This tab loads a plain HTTP camera stream from the address you enter below. The default is the current local camera IP.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.76))
                    }

                    Spacer(minLength: 0)

                    StatusPill(
                        label: cameraStreamState.label,
                        tint: cameraStatusTint
                    )
                }

                HStack(spacing: 12) {
                    DataHighlightTile(
                        label: "Camera State",
                        value: cameraStreamState.label,
                        icon: cameraStateIconName,
                        tint: cameraStatusTint
                    )

                    DataHighlightTile(
                        label: "Protocol",
                        value: "HTTP",
                        icon: "network",
                        tint: DashboardPalette.cyan
                    )
                }

                contractRow(label: "Camera URL", value: activeCameraURL ?? cameraHTTPURL)
                contractRow(label: "Pan Topic", value: mqttManager.cameraPanTopic)
                contractRow(label: "Tilt Topic", value: mqttManager.cameraTiltTopic)
            }
        }
    }

    private var camViewerCard: some View {
        DashboardPanel(tint: DashboardPalette.green, badge: "Cam Viewer") {
            VStack(alignment: .leading, spacing: 16) {
                fieldStack(title: "Camera URL", text: $cameraHTTPURL, keyboardType: .URL)

                LazyVGrid(columns: twoColumnLayout, spacing: 12) {
                    flatActionButton(
                        title: "Load Cam",
                        subtitle: "Open HTTP feed",
                        icon: "play.circle.fill",
                        tint: DashboardPalette.green
                    ) {
                        startCameraFeed()
                    }

                    flatActionButton(
                        title: "Stop Cam",
                        subtitle: "Close web viewer",
                        icon: "stop.circle.fill",
                        tint: DashboardPalette.rose
                    ) {
                        stopCameraFeed()
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Camera Motion")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))

                    Text("These controls publish camera movement commands to the same MQTT broker session used by the rest of the dashboard.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.68))

                    LazyVGrid(columns: twoColumnLayout, spacing: 12) {
                        flatActionButton(
                            title: "Pan Left",
                            subtitle: "camera/pan <- left",
                            icon: "arrow.left.circle.fill",
                            tint: DashboardPalette.cyan
                        ) {
                            connectUsingSavedSettingsIfNeeded()
                            mqttManager.panCameraLeft()
                        }

                        flatActionButton(
                            title: "Pan Right",
                            subtitle: "camera/pan <- right",
                            icon: "arrow.right.circle.fill",
                            tint: DashboardPalette.cyan
                        ) {
                            connectUsingSavedSettingsIfNeeded()
                            mqttManager.panCameraRight()
                        }

                        flatActionButton(
                            title: "Tilt Up",
                            subtitle: "camera/tilt <- up",
                            icon: "arrow.up.circle.fill",
                            tint: DashboardPalette.amber
                        ) {
                            connectUsingSavedSettingsIfNeeded()
                            mqttManager.tiltCameraUp()
                        }

                        flatActionButton(
                            title: "Tilt Down",
                            subtitle: "camera/tilt <- down",
                            icon: "arrow.down.circle.fill",
                            tint: DashboardPalette.amber
                        ) {
                            connectUsingSavedSettingsIfNeeded()
                            mqttManager.tiltCameraDown()
                        }
                    }
                }

                HTTPStreamView(
                    urlString: activeCameraURL,
                    reloadToken: cameraReloadToken,
                    onStateChange: handleCameraStreamUpdate
                )
                .frame(minHeight: 260)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.28))
                )

                Text(cameraStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))

                if let cameraLastError {
                    Text(cameraLastError)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(DashboardPalette.rose.opacity(0.18))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(DashboardPalette.rose.opacity(0.42), lineWidth: 1)
                        )
                }
            }
        }
    }

    private func fieldStack(title: String, text: Binding<String>, keyboardType: UIKeyboardType) -> some View {
        DashboardTextFieldSection(
            title: title,
            text: text,
            keyboardType: keyboardType
        )
    }

    private func flatActionButton(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            performButtonAction(action)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3.weight(.semibold))
                Text(title)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(0.36),
                                Color.black.opacity(0.30)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(tint.opacity(0.60), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(DashboardPressButtonStyle())
        .foregroundStyle(.white)
    }

    private func commandTile(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            performButtonAction(action)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.60))
                }

                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.70))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.34), DashboardPalette.surface.opacity(0.92)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(tint.opacity(0.55), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(DashboardPressButtonStyle())
        .foregroundStyle(.white)
        .shadow(color: tint.opacity(0.22), radius: 18, x: 0, y: 10)
    }

    private func contractRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 86, alignment: .leading)

            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var payloadLooksLikeJSON: Bool {
        let trimmedPayload = publisherPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPayload.isEmpty else {
            return false
        }

        return trimmedPayload.hasPrefix("{") || trimmedPayload.hasPrefix("[")
    }

    private var payloadModeLabel: String {
        payloadLooksLikeJSON ? "JSON / UTF-8" : "Text / UTF-8"
    }

    private var smartCamStateLabel: String {
        let rawValue = mqttManager.smartCamStreamState.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else {
            return "Standby"
        }

        return rawValue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private var smartCamStateTint: Color {
        switch mqttManager.smartCamStreamState.lowercased() {
        case "running", "already_running":
            return DashboardPalette.green
        case "requested", "waiting_for_broker", "stopping":
            return DashboardPalette.cyan
        case "stopped":
            return DashboardPalette.slate
        case "ignored":
            return DashboardPalette.amber
        case "failed", "decode_error":
            return DashboardPalette.rose
        default:
            return DashboardPalette.violet
        }
    }

    private var snakeStateTint: Color {
        switch mqttManager.snakeState.lowercased() {
        case "waiting_start", "already_running":
            return DashboardPalette.green
        case "requested", "stopping":
            return DashboardPalette.cyan
        case "stopped":
            return DashboardPalette.slate
        case "decode_error":
            return DashboardPalette.rose
        default:
            return DashboardPalette.amber
        }
    }

    private var streamStatusTint: Color {
        switch streamPlaybackState {
        case .idle, .stopped:
            return DashboardPalette.slate
        case .opening:
            return DashboardPalette.cyan
        case .buffering, .paused, .unavailable:
            return DashboardPalette.amber
        case .playing:
            return DashboardPalette.green
        case .ended:
            return DashboardPalette.violet
        case .error:
            return DashboardPalette.rose
        }
    }

    private var streamStateIconName: String {
        switch streamPlaybackState {
        case .idle:
            return "video.circle"
        case .opening:
            return "antenna.radiowaves.left.and.right"
        case .buffering:
            return "arrow.triangle.2.circlepath.circle"
        case .playing:
            return "play.rectangle.fill"
        case .paused:
            return "pause.rectangle.fill"
        case .stopped:
            return "stop.circle.fill"
        case .ended:
            return "flag.checkered.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "video.slash.fill"
        }
    }

    private var cameraStatusTint: Color {
        switch cameraStreamState {
        case .idle, .stopped:
            return DashboardPalette.slate
        case .loading:
            return DashboardPalette.cyan
        case .loaded:
            return DashboardPalette.green
        case .failed:
            return DashboardPalette.rose
        }
    }

    private var cameraStateIconName: String {
        switch cameraStreamState {
        case .idle:
            return "camera.viewfinder"
        case .loading:
            return "arrow.triangle.2.circlepath.circle"
        case .loaded:
            return "camera.fill"
        case .stopped:
            return "stop.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private func saveBrokerSettings() {
        let trimmedIP = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)

        ipAddress = trimmedIP
        port = trimmedPort

        guard !trimmedIP.isEmpty else {
            mqttManager.recordUIEvent("Broker settings were not saved because the IP address is empty.")
            return
        }

        guard let portValue = Int(trimmedPort), (1...65535).contains(portValue) else {
            mqttManager.recordUIEvent("Broker settings were not saved because '\(trimmedPort)' is not a valid port.")
            return
        }

        mqttManager.recordUIEvent("Saved broker settings for \(trimmedIP):\(portValue).")
    }

    private func resetDefaults() {
        ipAddress = "192.168.1.247"
        port = "1884"
        rtspStreamURL = "rtsp://192.168.1.236:8554/stream"
        cameraHTTPURL = "http://192.168.1.225"
        mqttManager.recordUIEvent("Restored the generic broker defaults.")
    }

    private func migrateBrokerDefaultsIfNeeded() {
        if ipAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ipAddress = "192.168.1.247"
        }

        if port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            port = "1884"
        }

        if rtspStreamURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rtspStreamURL = "rtsp://192.168.1.236:8554/stream"
        }

        if cameraHTTPURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            cameraHTTPURL = "http://192.168.1.225"
        }

        if !didClearLegacyLocalDefaults {
            didClearLegacyLocalDefaults = true
        }
    }

    private func connectUsingSavedSettings(forceReconnect: Bool = false) {
        saveBrokerSettings()

        guard !ipAddress.isEmpty, !port.isEmpty else {
            return
        }

        if forceReconnect {
            mqttManager.connect(host: ipAddress, portText: port)
        } else {
            mqttManager.connectIfNeeded(host: ipAddress, portText: port)
        }
    }

    private func connectUsingSavedSettingsIfNeeded() {
        connectUsingSavedSettings(forceReconnect: false)
    }

    private func shouldAutoConnect(for tab: DashboardTab) -> Bool {
        tab == .senseHat || tab == .publish || tab == .stream
    }

    private func runSenseHatPollingLoopIfNeeded() async {
        guard selectedTab == .senseHat else {
            return
        }

        if mqttManager.isConnected {
            mqttManager.requestSenseHatReading()
        } else {
            connectUsingSavedSettingsIfNeeded()
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(Double(mqttManager.publishIntervalSeconds)))
            } catch {
                break
            }

            if Task.isCancelled {
                break
            }

            if mqttManager.isConnected {
                mqttManager.requestSenseHatReading()
            } else {
                connectUsingSavedSettingsIfNeeded()
            }
        }
    }

    private func startStream() {
        let trimmedURL = rtspStreamURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            streamLastError = nil
            streamStatusMessage = "Enter an RTSP stream URL before sending the SmartCam start command."
            return
        }

        guard let normalizedURL = normalizedStreamURL(from: trimmedURL) else {
            streamLastError = "Use a full RTSP URL like rtsp://camera.local:8554/stream or enter a bare host we can prefix with rtsp://."
            streamStatusMessage = "The RTSP URL is not valid, so the SmartCam start command was not sent."
            return
        }

        rtspStreamURL = normalizedURL
        streamLastError = nil
        streamStatusMessage = "Sending start_stream to \(mqttManager.smartCamControlTopic). Tap Start Player after SmartCam reports the stream is running."
        connectUsingSavedSettingsIfNeeded()
        mqttManager.requestSmartCamStreamStart(preferredRTSPURL: normalizedURL)
    }

    private func stopStream() {
        streamLastError = nil
        streamStatusMessage = "Sending stop_stream to \(mqttManager.smartCamControlTopic). The local player stays independent until you stop it."
        mqttManager.requestSmartCamStreamStop()
    }

    private func startPlayer() {
        let candidateURL = mqttManager.smartCamRTSPURL ?? rtspStreamURL
        let trimmedURL = candidateURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            streamPlaybackState = .idle
            streamLastError = nil
            streamStatusMessage = "Enter an RTSP stream URL before starting the local player."
            return
        }

        guard let normalizedURL = normalizedStreamURL(from: trimmedURL) else {
            streamPlaybackState = .error
            streamLastError = "Use a full RTSP URL like rtsp://camera.local:8554/stream or enter a bare host we can prefix with rtsp://."
            streamStatusMessage = "The RTSP URL is not valid."
            return
        }

        rtspStreamURL = normalizedURL
        activeStreamURL = normalizedURL
        streamReloadToken &+= 1
        streamPlaybackState = .opening
        streamLastError = nil
        streamStatusMessage = "Opening the local RTSP player for \(normalizedURL)."
    }

    private func stopPlayer() {
        activeStreamURL = nil
        streamPlaybackState = .stopped
        streamLastError = nil
        streamStatusMessage = "Stopped the local RTSP player."
    }

    private func startCameraFeed() {
        let trimmedURL = cameraHTTPURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedURL.isEmpty else {
            cameraStreamState = .idle
            cameraLastError = nil
            cameraStatusMessage = "Enter an HTTP camera URL before loading the viewer."
            return
        }

        guard let normalizedURL = normalizedCameraURL(from: trimmedURL) else {
            cameraStreamState = .failed
            cameraLastError = "Use an HTTP URL like http://camera.local or enter a bare host name that we can prefix with http://."
            cameraStatusMessage = "The camera URL is not valid."
            return
        }

        cameraHTTPURL = normalizedURL
        activeCameraURL = normalizedURL
        cameraReloadToken &+= 1
        cameraStreamState = .loading
        cameraLastError = nil
        cameraStatusMessage = "Loading the HTTP camera feed from \(normalizedURL)."
    }

    private func stopCameraFeed() {
        activeCameraURL = nil
        cameraStreamState = .stopped
        cameraLastError = nil
        cameraStatusMessage = "Stopped the HTTP camera viewer."
    }

    private func normalizedStreamURL(from rawValue: String) -> String? {
        let prefixedValue = rawValue.contains("://") ? rawValue : "rtsp://\(rawValue)"

        guard
            let components = URLComponents(string: prefixedValue),
            let scheme = components.scheme?.lowercased(),
            ["rtsp", "rtsps", "http", "https"].contains(scheme),
            let host = components.host,
            !host.isEmpty
        else {
            return nil
        }

        return components.string
    }

    private func normalizedCameraURL(from rawValue: String) -> String? {
        let prefixedValue = rawValue.contains("://") ? rawValue : "http://\(rawValue)"

        guard
            let components = URLComponents(string: prefixedValue),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = components.host,
            !host.isEmpty
        else {
            return nil
        }

        return components.string
    }

    private func handleStreamPlayerUpdate(state: RTSPPlaybackState, message: String) {
        streamPlaybackState = state
        streamStatusMessage = message

        switch state {
        case .error, .unavailable:
            streamLastError = message
        default:
            streamLastError = nil
        }
    }

    private func syncStreamWithSmartCamStatus() {
        guard
            let advertisedURL = mqttManager.smartCamRTSPURL,
            let normalizedURL = normalizedStreamURL(from: advertisedURL)
        else {
            return
        }

        if rtspStreamURL != normalizedURL {
            rtspStreamURL = normalizedURL
        }

        if let activeStreamURL, activeStreamURL != normalizedURL {
            self.activeStreamURL = normalizedURL
            streamReloadToken &+= 1
            streamPlaybackState = .opening
            streamLastError = nil
            streamStatusMessage = "SmartCam published a new RTSP URL. Reopening the local player."
        }
    }

    private func handleCameraStreamUpdate(state: HTTPStreamState, message: String) {
        cameraStreamState = state
        cameraStatusMessage = message

        switch state {
        case .failed:
            cameraLastError = message
        default:
            cameraLastError = nil
        }
    }

    private func performButtonAction(_ action: () -> Void) {
        DashboardHaptics.tap()
        action()
    }
}

private struct ConfigurationTabView<Hero: View, Broker: View, TopicMap: View, LogCard: View>: View {
    let heroCard: Hero
    let brokerSettingsCard: Broker
    let mqttContractCard: TopicMap
    let logCard: LogCard

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                heroCard
                brokerSettingsCard
                mqttContractCard
                logCard
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .padding(.bottom, 24)
        }
    }
}

private struct BrokerSettingsCardView<ButtonContent: View>: View {
    @Binding var ipAddress: String
    @Binding var port: String
    let twoColumnLayout: [GridItem]
    let onSave: () -> Void
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onReset: () -> Void
    let buttonBuilder: (_ title: String, _ subtitle: String, _ icon: String, _ tint: Color, _ action: @escaping () -> Void) -> ButtonContent

    var body: some View {
        DashboardPanel(tint: DashboardPalette.blue, badge: "Broker Setup") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Keep the app pointed at the same MQTT broker as the publishing Sense HAT client.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.78))

                DashboardTextFieldSection(
                    title: "IP Address",
                    text: $ipAddress,
                    keyboardType: .numbersAndPunctuation
                )
                DashboardTextFieldSection(
                    title: "Port",
                    text: $port,
                    keyboardType: .numberPad
                )

                LazyVGrid(columns: twoColumnLayout, spacing: 12) {
                    buttonBuilder(
                        "Save Settings",
                        "Persist locally",
                        "tray.and.arrow.down.fill",
                        DashboardPalette.blue,
                        onSave
                    )

                    buttonBuilder(
                        "Connect Now",
                        "Open MQTT session",
                        "bolt.horizontal.fill",
                        DashboardPalette.green,
                        onConnect
                    )

                    buttonBuilder(
                        "Disconnect",
                        "Close socket",
                        "power",
                        DashboardPalette.rose,
                        onDisconnect
                    )

                    buttonBuilder(
                        "Reset Defaults",
                        "Restore broker values",
                        "arrow.counterclockwise",
                        DashboardPalette.amber,
                        onReset
                    )
                }
            }
        }
    }
}

private struct DashboardTextFieldSection: View {
    let title: String
    @Binding var text: String
    let keyboardType: UIKeyboardType

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.58))

            TextField(title, text: $text)
                .padding(14)
                .background(DashboardFieldBackground())
                .foregroundStyle(.white)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }
}

private struct DashboardFieldBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(DashboardPalette.fieldFill)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct DashboardPanel<Content: View>: View {
    let tint: Color
    let badge: String
    let content: Content

    init(tint: Color, badge: String, @ViewBuilder content: () -> Content) {
        self.tint = tint
        self.badge = badge
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusPill(label: badge, tint: tint)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(panelBackground)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.06),
                        tint.opacity(0.12),
                        Color.black.opacity(0.34)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .stroke(tint.opacity(0.40), lineWidth: 1)
            )
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.black.opacity(0.26))
            )
            .shadow(color: tint.opacity(0.16), radius: 24, x: 0, y: 18)
    }
}

private struct StatusPill: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label.uppercased())
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.22))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.55), lineWidth: 1)
            )
    }
}

private struct DashboardPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}

private enum DashboardHaptics {
    static func tap() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.20))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .foregroundStyle(tint)
            }

            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.84))

            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.20), Color.black.opacity(0.24)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(tint.opacity(0.40), lineWidth: 1)
        )
    }
}

private struct DataHighlightTile: View {
    let label: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.70))
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(tint.opacity(0.14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(tint.opacity(0.30), lineWidth: 1)
        )
    }
}

#if DEBUG
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
#endif
