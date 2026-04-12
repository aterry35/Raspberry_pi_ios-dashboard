//
//  SenseHatReading.swift
//  SenseHat_dashboard
//
//  Created by Codex on 4/3/26.
//

import Foundation

struct SenseHatReading: Decodable, Equatable {
    let temperatureC: Double
    let humidityPct: Double
    let pressureHpa: Double
    let accel: Acceleration?
    let orientation: Orientation?
    let gyroscope: Acceleration?
    private let recordedAt: Date

    struct Acceleration: Decodable, Equatable {
        let x: Double
        let y: Double
        let z: Double
    }

    struct Orientation: Decodable, Equatable {
        let pitch: Double
        let roll: Double
        let yaw: Double
    }

    enum CodingKeys: String, CodingKey {
        case temperatureC = "temperature_c"
        case humidityPct = "humidity_pct"
        case pressureHpa = "pressure_hpa"
        case accel
        case accelerometer
        case orientation = "orientation_deg"
        case gyroscope
        case ts
    }

    init(
        temperatureC: Double,
        humidityPct: Double,
        pressureHpa: Double,
        accel: Acceleration?,
        orientation: Orientation?,
        gyroscope: Acceleration?,
        recordedAt: Date
    ) {
        self.temperatureC = temperatureC
        self.humidityPct = humidityPct
        self.pressureHpa = pressureHpa
        self.accel = accel
        self.orientation = orientation
        self.gyroscope = gyroscope
        self.recordedAt = recordedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        temperatureC = try container.decode(Double.self, forKey: .temperatureC)
        humidityPct = try container.decode(Double.self, forKey: .humidityPct)
        pressureHpa = try container.decode(Double.self, forKey: .pressureHpa)
        accel = try container.decodeIfPresent(Acceleration.self, forKey: .accelerometer)
            ?? container.decodeIfPresent(Acceleration.self, forKey: .accel)
        orientation = try container.decodeIfPresent(Orientation.self, forKey: .orientation)
        gyroscope = try container.decodeIfPresent(Acceleration.self, forKey: .gyroscope)

        if let unixTimestamp = try? container.decode(Int.self, forKey: .ts) {
            recordedAt = Date(timeIntervalSince1970: TimeInterval(unixTimestamp))
            return
        }

        if let unixTimestamp = try? container.decode(Double.self, forKey: .ts) {
            recordedAt = Date(timeIntervalSince1970: unixTimestamp)
            return
        }

        if let timestampString = try? container.decode(String.self, forKey: .ts),
           let timestampDate = Self.statusTimestampDate(from: timestampString) {
            recordedAt = timestampDate
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .ts,
            in: container,
            debugDescription: "Expected the Sense HAT timestamp to be a Unix time or a supported date string."
        )
    }

    var timestampDate: Date {
        recordedAt
    }

    var formattedTemperature: String {
        String(format: "%.1f C", temperatureC)
    }

    var formattedHumidity: String {
        String(format: "%.1f %%", humidityPct)
    }

    var formattedPressure: String {
        String(format: "%.1f hPa", pressureHpa)
    }

    var formattedAcceleration: String {
        guard let accel else {
            return "x --  y --  z --"
        }

        return String(format: "x %.2f  y %.2f  z %.2f", accel.x, accel.y, accel.z)
    }

    var formattedGyroscope: String {
        guard let gyroscope else {
            return "x --  y --  z --"
        }

        return String(format: "x %.2f  y %.2f  z %.2f", gyroscope.x, gyroscope.y, gyroscope.z)
    }

    var formattedOrientation: String {
        guard let orientation else {
            return "p --  r --  y --"
        }

        return String(format: "p %.1f  r %.1f  y %.1f", orientation.pitch, orientation.roll, orientation.yaw)
    }

    var summary: String {
        "\(formattedTemperature), \(formattedHumidity), \(formattedPressure)"
    }

    private static func statusTimestampDate(from rawValue: String) -> Date? {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }

        if let unixTimestamp = Double(trimmedValue) {
            return Date(timeIntervalSince1970: unixTimestamp)
        }

        if let parsedDate = statusTimestampFormatter.date(from: trimmedValue) {
            return parsedDate
        }

        return iso8601Formatter.date(from: trimmedValue)
    }

    private static let statusTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let iso8601Formatter = ISO8601DateFormatter()
}
