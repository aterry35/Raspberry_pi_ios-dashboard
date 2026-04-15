//
//  SimpleMQTTClient.swift
//  SenseHat_dashboard
//
//  Created by Codex on 4/3/26.
//

import Foundation
import Network

final class SimpleMQTTClient {
    enum State: Equatable {
        case disconnected
        case connecting(host: String, port: UInt16)
        case connected(host: String, port: UInt16)
        case failed(String)
    }

    struct Message {
        let topic: String
        let payload: Data
        let isRetained: Bool
    }

    var onStateChange: ((State) -> Void)?
    var onMessage: ((Message) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "SenseHatDashboard.SimpleMQTTClient")
    private var connection: NWConnection?
    private var receiveBuffer = Data()
    private var packetIdentifier: UInt16 = 0
    private var pingTimer: DispatchSourceTimer?
    private var reconnectTopics = Set<String>()
    private var clientState: State = .disconnected
    private var currentHost: String = ""
    private var currentPort: UInt16 = 1883
    private var clientID: String = ""
    private var hasReceivedConnAck = false

    func connect(host: String, port: UInt16) {
        queue.async {
            if case .connected(let currentHost, let currentPort) = self.clientState,
               currentHost == host,
               currentPort == port {
                self.log("Already connected to \(host):\(port).")
                self.subscribeToReconnectTopics()
                return
            }

            self.disconnectInternal(emitState: false)

            self.currentHost = host
            self.currentPort = port
            self.clientID = "ios-sensehat-\(UUID().uuidString.prefix(8))"
            self.updateState(.connecting(host: host, port: port))

            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                self.updateState(.failed("The MQTT port \(port) is invalid."))
                return
            }

            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard
                    let self,
                    let connection,
                    self.connection === connection
                else {
                    return
                }

                self.handleConnectionState(state, connection: connection)
            }
            connection.start(queue: self.queue)
        }
    }

    func disconnect() {
        queue.async {
            self.disconnectInternal(emitState: true)
        }
    }

    func subscribe(topic: String) {
        queue.async {
            self.reconnectTopics.insert(topic)

            guard self.hasReceivedConnAck else {
                self.log("Queued subscription for \(topic) until the broker session is ready.")
                return
            }

            self.sendSubscribePacket(topic: topic)
        }
    }

    func publish(topic: String, string: String) {
        guard let payload = string.data(using: .utf8) else {
            log("Skipped publish because the payload could not be encoded as UTF-8.")
            return
        }

        queue.async {
            guard self.hasReceivedConnAck else {
                self.log("Skipped publish to \(topic) because the broker connection is not ready.")
                return
            }

            self.sendPublishPacket(topic: topic, payload: payload)
        }
    }

    private func handleConnectionState(_ state: NWConnection.State, connection: NWConnection) {
        switch state {
        case .ready:
            log("TCP connection established with \(currentHost):\(currentPort).")
            startReceiveLoop(connection: connection)
            sendConnectPacket()

        case .failed(let error):
            log("TCP connection failed: \(error.localizedDescription)")
            teardownConnection()
            updateState(.failed("MQTT socket failed: \(error.localizedDescription)"))

        case .cancelled:
            teardownConnection()

            if case .failed = clientState {
                return
            }

            updateState(.disconnected)

        default:
            break
        }
    }

    private func disconnectInternal(emitState: Bool) {
        if hasReceivedConnAck {
            send(Data([0xE0, 0x00]))
        }

        teardownConnection()

        if emitState {
            updateState(.disconnected)
        } else {
            clientState = .disconnected
        }
    }

    private func teardownConnection() {
        stopPingTimer()
        receiveBuffer.removeAll()
        hasReceivedConnAck = false

        let existingConnection = connection
        connection = nil
        existingConnection?.stateUpdateHandler = nil
        existingConnection?.cancel()
    }

    private func startReceiveLoop(connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak connection] data, _, isComplete, error in
            guard
                let self,
                let connection,
                self.connection === connection
            else {
                return
            }

            if let error {
                self.log("Receive loop ended with error: \(error.localizedDescription)")
                self.teardownConnection()
                self.updateState(.failed("Receive loop ended: \(error.localizedDescription)"))
                return
            }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.parseReceiveBuffer()
            }

            if isComplete {
                self.log("Broker closed the TCP connection.")
                self.teardownConnection()
                self.updateState(.disconnected)
                return
            }

            self.startReceiveLoop(connection: connection)
        }
    }

    private func parseReceiveBuffer() {
        while true {
            guard receiveBuffer.count > 1 else {
                return
            }

            guard let remainingLength = decodeRemainingLength(from: receiveBuffer, startIndex: 1) else {
                return
            }

            let totalHeaderLength = 1 + remainingLength.encodedBytes
            let totalPacketLength = totalHeaderLength + remainingLength.value

            guard receiveBuffer.count >= totalPacketLength else {
                return
            }

            let fixedHeader = receiveBuffer[0]
            let packetBody = receiveBuffer.subdata(in: totalHeaderLength..<totalPacketLength)
            receiveBuffer.removeSubrange(0..<totalPacketLength)
            handlePacket(fixedHeader: fixedHeader, body: packetBody)
        }
    }

    private func handlePacket(fixedHeader: UInt8, body: Data) {
        let packetType = fixedHeader >> 4

        switch packetType {
        case 2:
            handleConnAck(body)

        case 3:
            handlePublish(fixedHeader: fixedHeader, body: body)

        case 9:
            log("Broker acknowledged the subscription request.")

        case 13:
            log("Received MQTT ping response.")

        default:
            log("Received MQTT packet type \(packetType), which is not explicitly handled.")
        }
    }

    private func handleConnAck(_ body: Data) {
        guard body.count >= 2 else {
            updateState(.failed("Received a malformed CONNACK packet."))
            return
        }

        let returnCode = body[1]

        guard returnCode == 0 else {
            updateState(.failed("Broker rejected the MQTT CONNECT request with return code \(returnCode)."))
            return
        }

        hasReceivedConnAck = true
        updateState(.connected(host: currentHost, port: currentPort))
        log("MQTT CONNECT acknowledged by the broker.")
        startPingTimer()
        subscribeToReconnectTopics()
    }

    private func handlePublish(fixedHeader: UInt8, body: Data) {
        guard body.count >= 2 else {
            log("Received a malformed PUBLISH packet.")
            return
        }

        let topicLength = Int(body[0]) << 8 | Int(body[1])
        let qos = (fixedHeader & 0x06) >> 1
        let retain = (fixedHeader & 0x01) == 0x01

        guard body.count >= 2 + topicLength else {
            log("Received a PUBLISH packet with an invalid topic length.")
            return
        }

        let topicStart = 2
        let topicEnd = topicStart + topicLength
        let topicData = body.subdata(in: topicStart..<topicEnd)
        guard let topic = String(data: topicData, encoding: .utf8) else {
            log("Received a PUBLISH packet with a non UTF-8 topic.")
            return
        }

        var payloadStart = topicEnd
        if qos > 0 {
            guard body.count >= payloadStart + 2 else {
                log("Received a QoS PUBLISH packet without a packet identifier.")
                return
            }
            payloadStart += 2
        }

        let payload = body.subdata(in: payloadStart..<body.count)
        emitMessage(Message(topic: topic, payload: payload, isRetained: retain))
    }

    private func sendConnectPacket() {
        var variableHeader = Data()
        variableHeader.append(contentsOf: [0x00, 0x04])
        variableHeader.append("MQTT".data(using: .utf8) ?? Data())
        variableHeader.append(0x04)
        variableHeader.append(0x02)
        variableHeader.append(contentsOf: [0x00, 0x3C])

        let payload = encodeString(clientID)
        let remainingLength = variableHeader.count + payload.count

        var packet = Data([0x10])
        packet.append(encodeRemainingLength(remainingLength))
        packet.append(variableHeader)
        packet.append(payload)

        send(packet)
        log("Sent MQTT CONNECT for client id \(clientID).")
    }

    private func sendSubscribePacket(topic: String) {
        packetIdentifier &+= 1
        if packetIdentifier == 0 {
            packetIdentifier = 1
        }

        var variableHeader = Data()
        variableHeader.append(UInt8(packetIdentifier >> 8))
        variableHeader.append(UInt8(packetIdentifier & 0xFF))

        var payload = encodeString(topic)
        payload.append(0x00)

        var packet = Data([0x82])
        packet.append(encodeRemainingLength(variableHeader.count + payload.count))
        packet.append(variableHeader)
        packet.append(payload)

        send(packet)
        log("Subscribed to \(topic).")
    }

    private func sendPublishPacket(topic: String, payload: Data) {
        let variableHeader = encodeString(topic)

        var packet = Data([0x30])
        packet.append(encodeRemainingLength(variableHeader.count + payload.count))
        packet.append(variableHeader)
        packet.append(payload)

        send(packet)
    }

    private func startPingTimer() {
        stopPingTimer()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak self] in
            self?.send(Data([0xC0, 0x00]))
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPingTimer() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func subscribeToReconnectTopics() {
        for topic in reconnectTopics.sorted() {
            sendSubscribePacket(topic: topic)
        }
    }

    private func send(_ packet: Data) {
        connection?.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error {
                self?.log("MQTT send failed: \(error.localizedDescription)")
            }
        })
    }

    private func encodeString(_ string: String) -> Data {
        let stringData = string.data(using: .utf8) ?? Data()
        let length = UInt16(stringData.count)

        var data = Data()
        data.append(UInt8(length >> 8))
        data.append(UInt8(length & 0xFF))
        data.append(stringData)
        return data
    }

    private func encodeRemainingLength(_ value: Int) -> Data {
        var encoded = Data()
        var remainingValue = value

        repeat {
            var byte = UInt8(remainingValue % 128)
            remainingValue /= 128

            if remainingValue > 0 {
                byte |= 0x80
            }

            encoded.append(byte)
        } while remainingValue > 0

        return encoded
    }

    private func decodeRemainingLength(from data: Data, startIndex: Int) -> (value: Int, encodedBytes: Int)? {
        var multiplier = 1
        var value = 0
        var offset = startIndex

        while offset < data.count {
            let encodedByte = Int(data[offset])
            value += (encodedByte & 127) * multiplier

            if multiplier > 128 * 128 * 128 {
                return nil
            }

            if (encodedByte & 128) == 0 {
                return (value, offset - startIndex + 1)
            }

            multiplier *= 128
            offset += 1
        }

        return nil
    }

    private func updateState(_ newState: State) {
        guard clientState != newState else {
            return
        }

        clientState = newState
        let callback = onStateChange
        DispatchQueue.main.async {
            callback?(newState)
        }
    }

    private func emitMessage(_ message: Message) {
        let callback = onMessage
        DispatchQueue.main.async {
            callback?(message)
        }
    }

    private func log(_ message: String) {
        let callback = onLog
        DispatchQueue.main.async {
            callback?(message)
        }
    }
}
