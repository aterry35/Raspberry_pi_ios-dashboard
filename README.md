# Raspberry Pi iOS Dashboard

An iOS dashboard for Raspberry Pi projects that combines MQTT control, Sense HAT telemetry, RTSP viewing, and a simple HTTP camera viewer in one SwiftUI app.

## What the app does

- Connects to an MQTT broker from the app
- Reads live Sense HAT telemetry from Pi-side MQTT topics
- Sends Sense HAT control messages such as:
  - `read_once`
  - `blink`
  - `lights_off`
  - `show_text`
  - `start_snake`
  - `stop_snake`
- Starts and stops a SmartCam RTSP stream over MQTT
- Plays RTSP video in-app using `MobileVLCKit`
- Opens a plain HTTP camera feed in-app
- Sends camera pan/tilt commands over MQTT
- Publishes arbitrary MQTT topic/payload messages from a raw publisher tab

## Main tabs

- `MQTT`
  Configure the broker, connect or disconnect, and inspect the session log.

- `Sense HAT`
  View temperature, humidity, pressure, accelerometer, gyroscope, and orientation values. Send Sense HAT control messages and manage the snake game.

- `Publish`
  Send any MQTT topic and payload manually. Useful for diagnostics and quick broker testing.

- `RTSP`
  Send MQTT commands to start or stop the Pi-side stream, then open the RTSP player locally in the app.

- `Cam`
  Open a simple HTTP camera stream and send pan/tilt MQTT commands.

## MQTT topics used by the app

### Sense HAT

- `sensehat/pi3/control`
- `sensehat/pi3/status`
- `pi3/monitor/status`

### SmartCam

- `smartcam/pi3/control`
- `smartcam/pi3/status`
- `smartcam/pi3/person`

### Camera movement

- `camera/pan`
- `camera/tilt`

For the detailed topic contracts, see:

- [PI3_SENSEHAT_MQTT_TOPICS.md](./PI3_SENSEHAT_MQTT_TOPICS.md)
- [TOPIC_DESIGN_DETAILS.md](./TOPIC_DESIGN_DETAILS.md)

## Tech stack

- SwiftUI
- Network framework MQTT client
- `MobileVLCKit` for RTSP playback
- `WKWebView` for the HTTP camera page
- CocoaPods for iOS dependency management

## Requirements

- macOS with Xcode
- CocoaPods
- iOS 18.6+

## Setup

1. Clone the repository.
2. Install pods:

```bash
pod install
```

3. Open the workspace, not the project:

```bash
open SenseHat_dashboard.xcworkspace
```

4. Build and run on a simulator or device.

## Important run notes

- Use the `SenseHat_dashboard.xcworkspace` file. Do not open the `.xcodeproj` directly when working with RTSP playback.
- The app requires Local Network access on device.
- The broker address, RTSP URL, and HTTP camera URL are configurable in the app UI.
- If your Pi-side RTSP service is on-demand, start the stream over MQTT first, then open the local RTSP player.

## Project structure

- [SenseHat_dashboard/ContentView.swift](./SenseHat_dashboard/ContentView.swift)
  Main dashboard UI and tab layout

- [SenseHat_dashboard/MQTTManager.swift](./SenseHat_dashboard/MQTTManager.swift)
  MQTT topic handling, publish/subscribe logic, and app-facing state

- [SenseHat_dashboard/SimpleMQTTClient.swift](./SenseHat_dashboard/SimpleMQTTClient.swift)
  Lightweight MQTT client built on Apple Network framework sockets

- [SenseHat_dashboard/RTSPPlayerView.swift](./SenseHat_dashboard/RTSPPlayerView.swift)
  RTSP playback wrapper around `MobileVLCKit`

- [SenseHat_dashboard/HTTPStreamView.swift](./SenseHat_dashboard/HTTPStreamView.swift)
  Embedded HTTP camera viewer

- [SenseHat_dashboard/SenseHatReading.swift](./SenseHat_dashboard/SenseHatReading.swift)
  Decoding and formatting for Sense HAT telemetry

## Troubleshooting

- If `MobileVLCKit.framework` is not found, run `pod install` and reopen the workspace.
- If device builds fail during the CocoaPods embed step, clean DerivedData and rebuild from the workspace.
- If the RTSP view is blank but desktop VLC works, confirm the Pi stream is running and the iPhone has Local Network permission enabled.
- If MQTT actions do not appear to send, verify the app is connected to the broker on the `MQTT` tab and check the session log.

## Status

This app is an active prototype for a Raspberry Pi control dashboard. The MQTT contracts are evolving with the Pi-side services, and the UI is being updated as those features stabilize.
