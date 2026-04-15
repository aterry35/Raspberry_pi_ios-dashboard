//
//  MQTTManager.swift
//  SenseHat_dashboard
//
//  Created by Codex on 4/3/26.
//

import Combine
import Foundation
import SwiftUI

@MainActor
final class MQTTManager: ObservableObject {
    let senseHatControlTopic = "sensehat/pi3/control"
    let senseHatStatusTopic = "sensehat/pi3/status"
    let piMonitorStatusTopic = "pi3/monitor/status"
    let smartCamControlTopic = "smartcam/pi3/control"
    let smartCamStatusTopic = "smartcam/pi3/status"
    let smartCamPersonTopic = "smartcam/pi3/person"
    let cameraPanTopic = "camera/pan"
    let cameraTiltTopic = "camera/tilt"
    let publishIntervalSeconds = 5

    @Published private(set) var connectionTitle: String = "Disconnected"
    @Published private(set) var connectionDetail: String = "Open the Sense HAT tab or tap Connect Now to establish an MQTT session."
    @Published private(set) var connectionTint: Color = .orange
    @Published private(set) var connectionIconName: String = "bolt.horizontal.circle"
    @Published private(set) var activeBrokerSummary: String = "Not connected"
    @Published private(set) var latestReading: SenseHatReading?
    @Published private(set) var lastRawPayload: String?
    @Published private(set) var lastDecodeError: String?
    @Published private(set) var lastSentCommand: String?
    @Published private(set) var snakeState: String = "idle"
    @Published private(set) var snakeMode: String = "snake"
    @Published private(set) var snakeStatusDetail: String = "Use the Sense HAT controls to start or stop the snake game."
    @Published private(set) var snakeLastStatusPayload: String?
    @Published private(set) var smartCamStreamState: String = "standby"
    @Published private(set) var smartCamStatusDetail: String = "Open the RTSP tab to connect to MQTT and control the SmartCam stream."
    @Published private(set) var smartCamRTSPURL: String?
    @Published private(set) var smartCamLastStatusPayload: String?
    @Published private(set) var lastPiMonitorPayload: String?
    @Published private(set) var logsText: String = ""

    var isConnected: Bool {
        if case .connected = clientState {
            return true
        }

        return false
    }

    var temperatureValue: String {
        latestReading?.formattedTemperature ?? "--.- C"
    }

    var humidityValue: String {
        latestReading?.formattedHumidity ?? "--.- %"
    }

    var pressureValue: String {
        latestReading?.formattedPressure ?? "----.- hPa"
    }

    var accelerationValue: String {
        latestReading?.formattedAcceleration ?? "x -- y -- z --"
    }

    var gyroscopeValue: String {
        latestReading?.formattedGyroscope ?? "x -- y -- z --"
    }

    var orientationValue: String {
        latestReading?.formattedOrientation ?? "p -- r -- y --"
    }

    private struct BrokerConfiguration: Equatable {
        let host: String
        let port: UInt16

        var summary: String {
            "\(host):\(port)"
        }
    }

    private let client = SimpleMQTTClient()
    private var clientState: SimpleMQTTClient.State = .disconnected
    private var desiredConfiguration: BrokerConfiguration?
    private var logEntries: [String] = []
    private let decoder = JSONDecoder()
    private var pendingControlPublishes: [PendingControlPublish] = []
    private var pendingSmartCamAction: PendingSmartCamAction?
    private var preferredSmartCamRTSPURL: String?

    private enum PendingSmartCamAction {
        case startStream(preferredRTSPURL: String)
        case stopStream
    }

    private struct PendingControlPublish {
        let topic: String
        let payload: String
        let actionLabel: String
    }

    private struct SmartCamStatusEnvelope: Decodable {
        let state: String?
        let topic: String?
        let handler: String?
        let result: SmartCamStatusResult?
        let ts: String?
    }

    private struct SmartCamStatusResult: Decodable {
        let state: String?
        let rtsp: String?
    }

    private struct SenseHatStatusEnvelope: Decodable {
        let state: String?
        let topic: String?
        let handler: String?
        let result: SenseHatStatusResult?
        let reading: SenseHatReading?
        let mode: String?
        let ts: String?
    }

    private struct SenseHatStatusResult: Decodable {
        let state: String?
        let reading: SenseHatReading?
        let ok: Bool?
        let action: String?
        let text: String?
        let mode: String?
    }

    init() {
        client.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleStateChange(state)
            }
        }

        client.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handleMessage(message)
            }
        }

        client.onLog = { [weak self] message in
            Task { @MainActor in
                self?.appendLog(message)
            }
        }

        appendLog("MQTT manager initialized.")
    }

    func connectIfNeeded(host: String, portText: String) {
        guard let configuration = validateConfiguration(host: host, portText: portText) else {
            return
        }

        desiredConfiguration = configuration

        switch clientState {
        case .connecting(let currentHost, let currentPort), .connected(let currentHost, let currentPort):
            if currentHost == configuration.host, currentPort == configuration.port {
                appendLog("MQTT session is already targeting \(configuration.summary).")
                return
            }

        default:
            break
        }

        connect(configuration: configuration)
    }

    func connect(host: String, portText: String) {
        guard let configuration = validateConfiguration(host: host, portText: portText) else {
            return
        }

        desiredConfiguration = configuration
        connect(configuration: configuration)
    }

    func disconnect() {
        client.disconnect()
    }

    func requestSenseHatReading() {
        publishSenseHatControl(payload: #"{"action":"read_once"}"#, actionLabel: "read_once")
    }

    func blinkSenseHat() {
        publishSenseHatControl(payload: #"{"action":"blink"}"#, actionLabel: "blink")
    }

    func lightsOff() {
        publishSenseHatControl(payload: #"{"action":"lights_off"}"#, actionLabel: "lights_off")
    }

    func clearSenseHatDisplay() {
        publishSenseHatControl(payload: #"{"action":"clear"}"#, actionLabel: "clear")
    }

    func startSnakeGame() {
        publishSenseHatControl(payload: #"{"action":"start_snake"}"#, actionLabel: "start_snake")
        snakeState = "requested"
        snakeMode = "snake"
        snakeStatusDetail = "Requested start_snake on \(senseHatControlTopic). Waiting for \(senseHatStatusTopic)."
    }

    func stopSnakeGame() {
        publishSenseHatControl(payload: #"{"action":"stop_snake"}"#, actionLabel: "stop_snake")
        snakeState = "stopping"
        snakeMode = "snake"
        snakeStatusDetail = "Requested stop_snake on \(senseHatControlTopic). Waiting for \(senseHatStatusTopic)."
    }

    func panCameraLeft() {
        publishCameraControl(topic: cameraPanTopic, payload: "left", actionLabel: "pan left")
    }

    func panCameraRight() {
        publishCameraControl(topic: cameraPanTopic, payload: "right", actionLabel: "pan right")
    }

    func tiltCameraUp() {
        publishCameraControl(topic: cameraTiltTopic, payload: "up", actionLabel: "tilt up")
    }

    func tiltCameraDown() {
        publishCameraControl(topic: cameraTiltTopic, payload: "down", actionLabel: "tilt down")
    }

    func showTime() {
        let timestamp = Date.now.formatted(date: .omitted, time: .shortened)
        sendSenseHatDisplayText(timestamp)
    }

    func sendMessage(_ text: String) {
        sendSenseHatDisplayText(text)
    }

    func publish(topic: String, payload: String) {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTopic.isEmpty else {
            appendLog("Skipped publish because the topic field was empty.")
            return
        }

        guard !trimmedPayload.isEmpty else {
            appendLog("Skipped publish to \(trimmedTopic) because the payload field was empty.")
            return
        }

        guard isConnected else {
            appendLog("Publish skipped because the MQTT client is not connected.")
            return
        }

        client.publish(topic: trimmedTopic, string: trimmedPayload)
        lastSentCommand = "\(trimmedTopic) <- \(trimmedPayload)"
        appendLog("Published custom payload to \(trimmedTopic).")
    }

    func requestSmartCamStreamStart(preferredRTSPURL: String) {
        let trimmedURL = preferredRTSPURL.trimmingCharacters(in: .whitespacesAndNewlines)
        preferredSmartCamRTSPURL = trimmedURL.isEmpty ? nil : trimmedURL

        let payload = #"{"action":"start_stream"}"#
        guard isConnected else {
            pendingSmartCamAction = .startStream(preferredRTSPURL: preferredRTSPURL)
            smartCamStreamState = "waiting_for_broker"
            smartCamStatusDetail = "Waiting for the MQTT session before sending SmartCam start_stream."
            appendLog("Queued SmartCam start until the MQTT session is connected.")
            return
        }

        publishSmartCamControl(payload: payload, actionLabel: "start_stream")
        smartCamStreamState = "requested"
        smartCamStatusDetail = "Requested SmartCam start on \(smartCamControlTopic). Waiting for \(smartCamStatusTopic)."
    }

    func requestSmartCamStreamStop() {
        let payload = #"{"action":"stop_stream"}"#
        guard isConnected else {
            pendingSmartCamAction = nil
            smartCamStreamState = "stopped"
            smartCamStatusDetail = "MQTT was disconnected, so no stop_stream command was sent to SmartCam."
            appendLog("Skipped SmartCam stop because the MQTT client is not connected.")
            return
        }

        pendingSmartCamAction = nil
        publishSmartCamControl(payload: payload, actionLabel: "stop_stream")
        smartCamStreamState = "stopping"
        smartCamStatusDetail = "Requested SmartCam stop on \(smartCamControlTopic). Waiting for \(smartCamStatusTopic)."
    }

    func recordUIEvent(_ message: String) {
        appendLog(message)
    }

    private func connect(configuration: BrokerConfiguration) {
        activeBrokerSummary = configuration.summary
        appendLog("Connecting to \(configuration.summary).")
        client.connect(host: configuration.host, port: configuration.port)
    }

    private func validateConfiguration(host: String, portText: String) -> BrokerConfiguration? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedHost.isEmpty else {
            setFailureState("Enter the MQTT broker IP address before connecting.")
            appendLog("Connect skipped because the broker IP address is empty.")
            return nil
        }

        guard let portValue = UInt16(trimmedPort), (1...65535).contains(Int(portValue)) else {
            setFailureState("Use a numeric MQTT port between 1 and 65535.")
            appendLog("Connect skipped because '\(trimmedPort)' is not a valid port.")
            return nil
        }

        return BrokerConfiguration(host: trimmedHost, port: portValue)
    }

    private func sendSenseHatDisplayText(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedText.isEmpty else {
            appendLog("Skipped Sense HAT publish because the message was empty.")
            return
        }

        guard let payload = makeJSONString(from: ["action": "show_text", "text": trimmedText]) else {
            appendLog("Failed to encode the Sense HAT show_text payload.")
            return
        }

        publishSenseHatControl(payload: payload, actionLabel: "show_text")
    }

    private func publishSenseHatControl(payload: String, actionLabel: String) {
        guard isConnected else {
            queuePendingControlPublish(
                topic: senseHatControlTopic,
                payload: payload,
                actionLabel: "Sense HAT \(actionLabel)"
            )
            return
        }

        client.publish(topic: senseHatControlTopic, string: payload)
        lastSentCommand = "\(senseHatControlTopic) <- \(payload)"
        appendLog("Published Sense HAT action '\(actionLabel)' to \(senseHatControlTopic).")
    }

    private func queuePendingControlPublish(topic: String, payload: String, actionLabel: String) {
        pendingControlPublishes.append(
            PendingControlPublish(topic: topic, payload: payload, actionLabel: actionLabel)
        )
        appendLog("Queued \(actionLabel) until the MQTT session is connected.")
    }

    private func publishCameraControl(topic: String, payload: String, actionLabel: String) {
        guard isConnected else {
            queuePendingControlPublish(
                topic: topic,
                payload: payload,
                actionLabel: "camera \(actionLabel)"
            )
            return
        }

        client.publish(topic: topic, string: payload)
        lastSentCommand = "\(topic) <- \(payload)"
        appendLog("Published camera action '\(actionLabel)' to \(topic).")
    }

    private func makeJSONString(from object: [String: String]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    private func handleStateChange(_ state: SimpleMQTTClient.State) {
        clientState = state

        switch state {
        case .disconnected:
            connectionTitle = "Disconnected"
            connectionDetail = desiredConfiguration == nil
                ? "Open the Sense HAT tab or tap Connect Now to establish an MQTT session."
                : "The MQTT client is no longer connected. Reopen the Sense HAT tab or tap Connect Now to retry."
            connectionTint = .orange
            connectionIconName = "bolt.horizontal.circle"

        case .connecting(let host, let port):
            activeBrokerSummary = "\(host):\(port)"
            connectionTitle = "Connecting"
            connectionDetail = "Opening a TCP socket and MQTT session with \(activeBrokerSummary)."
            connectionTint = .yellow
            connectionIconName = "antenna.radiowaves.left.and.right.circle"

        case .connected(let host, let port):
            activeBrokerSummary = "\(host):\(port)"
            connectionTitle = "Connected"
            connectionDetail = "Subscribed to \(senseHatStatusTopic), \(smartCamStatusTopic), and \(piMonitorStatusTopic) on \(activeBrokerSummary)."
            connectionTint = .green
            connectionIconName = "bolt.horizontal.circle.fill"
            client.subscribe(topic: senseHatStatusTopic)
            client.subscribe(topic: piMonitorStatusTopic)
            client.subscribe(topic: smartCamStatusTopic)
            flushPendingControlPublishes()
            performPendingSmartCamActionIfNeeded()

        case .failed(let message):
            connectionTitle = "Connection Failed"
            connectionDetail = message
            connectionTint = .red
            connectionIconName = "exclamationmark.triangle.fill"
        }
    }

    private func handleMessage(_ message: SimpleMQTTClient.Message) {
        switch message.topic {
        case senseHatStatusTopic:
            handleSenseHatStatusMessage(message)

        case piMonitorStatusTopic:
            handlePiMonitorStatusMessage(message)

        case smartCamStatusTopic:
            handleSmartCamStatusMessage(message)

        default:
            appendLog("Received a message on \(message.topic), which is not handled by the dashboard.")
        }
    }

    private func handleSenseHatStatusMessage(_ message: SimpleMQTTClient.Message) {
        let rawPayload = String(decoding: message.payload, as: UTF8.self)
        lastRawPayload = rawPayload

        do {
            let status = try decoder.decode(SenseHatStatusEnvelope.self, from: message.payload)

            if let reading = status.result?.reading ?? status.reading {
                latestReading = reading
                lastDecodeError = nil
                appendLog("Sense HAT status updated: \(reading.summary).")
            }

            let resultState = status.result?.state ?? status.state ?? "unknown"
            let snakeModeValue = (status.result?.mode ?? status.mode ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if shouldTreatAsSnakeStatus(resultState: resultState, mode: snakeModeValue) {
                let normalizedState = resultState.trimmingCharacters(in: .whitespacesAndNewlines)
                snakeState = normalizedState.isEmpty ? "unknown" : normalizedState
                snakeMode = snakeModeValue.isEmpty ? "snake" : snakeModeValue
                snakeLastStatusPayload = rawPayload
                snakeStatusDetail = snakeDetailMessage(
                    for: snakeState,
                    mode: snakeMode,
                    timestamp: status.ts
                )
                appendLog("Snake status updated: \(snakeStatusDetail)")
                return
            }

            if status.result?.reading == nil, status.reading == nil {
                appendLog("Sense HAT status '\(resultState)' did not include a sensor reading.")
            }
        } catch {
            lastDecodeError = error.localizedDescription
            appendLog("Sense HAT status decode failed: \(error.localizedDescription)")
        }
    }

    private func handlePiMonitorStatusMessage(_ message: SimpleMQTTClient.Message) {
        let rawPayload = String(decoding: message.payload, as: UTF8.self)
        lastPiMonitorPayload = rawPayload
        appendLog("Pi monitor status received on \(piMonitorStatusTopic).")
    }

    private func flushPendingControlPublishes() {
        guard isConnected, !pendingControlPublishes.isEmpty else {
            return
        }

        let queuedPublishes = pendingControlPublishes
        pendingControlPublishes.removeAll()

        for publish in queuedPublishes {
            client.publish(topic: publish.topic, string: publish.payload)
            lastSentCommand = "\(publish.topic) <- \(publish.payload)"
            appendLog("Flushed queued \(publish.actionLabel) to \(publish.topic).")
        }
    }

    private func handleSmartCamStatusMessage(_ message: SimpleMQTTClient.Message) {
        let rawPayload = String(decoding: message.payload, as: UTF8.self)
        smartCamLastStatusPayload = rawPayload

        do {
            let status = try decoder.decode(SmartCamStatusEnvelope.self, from: message.payload)
            let resultState = (status.result?.state ?? status.state ?? "unknown").trimmingCharacters(in: .whitespacesAndNewlines)
            let advertisedURL = status.result?.rtsp?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveURL = advertisedURL?.isEmpty == false ? advertisedURL : preferredSmartCamRTSPURL

            if let effectiveURL, !effectiveURL.isEmpty {
                smartCamRTSPURL = effectiveURL
            }

            smartCamStreamState = resultState.isEmpty ? "unknown" : resultState
            smartCamStatusDetail = smartCamDetailMessage(
                for: smartCamStreamState,
                rtspURL: effectiveURL,
                timestamp: status.ts
            )

            appendLog("SmartCam status updated: \(smartCamStatusDetail)")
        } catch {
            smartCamStreamState = "decode_error"
            smartCamStatusDetail = "SmartCam status decode failed: \(error.localizedDescription)"
            appendLog("SmartCam status decode failed: \(error.localizedDescription)")
        }
    }

    private func publishSmartCamControl(payload: String, actionLabel: String) {
        client.publish(topic: smartCamControlTopic, string: payload)
        lastSentCommand = "\(smartCamControlTopic) <- \(payload)"
        appendLog("Published SmartCam action '\(actionLabel)' to \(smartCamControlTopic).")
    }

    private func performPendingSmartCamActionIfNeeded() {
        guard isConnected, let action = pendingSmartCamAction else {
            return
        }

        pendingSmartCamAction = nil

        switch action {
        case .startStream(let preferredRTSPURL):
            requestSmartCamStreamStart(preferredRTSPURL: preferredRTSPURL)

        case .stopStream:
            requestSmartCamStreamStop()
        }
    }

    private func smartCamDetailMessage(for state: String, rtspURL: String?, timestamp: String?) -> String {
        let suffix = timestamp.map { " (\($0))" } ?? ""

        switch state {
        case "running":
            if let rtspURL, !rtspURL.isEmpty {
                return "SmartCam reported the stream is running at \(rtspURL)\(suffix)."
            }
            return "SmartCam reported the stream is running\(suffix)."

        case "already_running":
            if let rtspURL, !rtspURL.isEmpty {
                return "SmartCam said the stream was already running at \(rtspURL)\(suffix)."
            }
            return "SmartCam said the stream was already running\(suffix)."

        case "stopped":
            return "SmartCam reported the stream is stopped\(suffix)."

        case "failed":
            return "SmartCam reported the stream request failed\(suffix)."

        case "ignored":
            return "SmartCam ignored the last request\(suffix)."

        case "waiting_for_broker":
            return smartCamStatusDetail

        default:
            return "SmartCam status changed to '\(state)'\(suffix)."
        }
    }

    private func snakeDetailMessage(for state: String, mode: String, timestamp: String?) -> String {
        let suffix = timestamp.map { " (\($0))" } ?? ""
        let modeSuffix = mode.isEmpty ? "" : " in \(mode) mode"

        switch state {
        case "waiting_start":
            return "Snake game is waiting to start\(modeSuffix)\(suffix)."
        case "already_running":
            return "Snake game is already running\(modeSuffix)\(suffix)."
        case "stopped":
            return "Snake game is stopped\(suffix)."
        case "requested", "stopping":
            return snakeStatusDetail
        default:
            return "Snake status changed to '\(state)'\(modeSuffix)\(suffix)."
        }
    }

    private func shouldTreatAsSnakeStatus(resultState: String, mode: String) -> Bool {
        let normalizedState = resultState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedMode = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalizedMode == "snake" {
            return true
        }

        if !normalizedMode.isEmpty {
            return false
        }

        switch normalizedState {
        case "waiting_start", "already_running", "requested", "stopping":
            return true
        default:
            return false
        }
    }

    private func setFailureState(_ message: String) {
        clientState = .failed(message)
        connectionTitle = "Configuration Error"
        connectionDetail = message
        connectionTint = .red
        connectionIconName = "exclamationmark.triangle.fill"
    }

    private func appendLog(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .standard)
        logEntries.append("[\(timestamp)] \(message)")

        if logEntries.count > 80 {
            logEntries.removeFirst(logEntries.count - 80)
        }

        logsText = logEntries.joined(separator: "\n")
    }
}
