# PI3_MQTT_Monitor Topic Design Details

This document explains each MQTT topic used by the unified Raspberry Pi 3 MQTT Monitor system, what changed from the older Sense HAT design, and how clients should use the topics.

## Broker
- Host: `<MQTT_BROKER_HOST>`
- Port: `<MQTT_BROKER_PORT>`

---

# Topic groups

The system now has three topic groups:

1. **Global monitor topics**
2. **SmartCam topics**
3. **Sense HAT topics**

The new design separates features by namespace so one Pi-side service can handle multiple capabilities cleanly.

---

# 1. Global monitor topics

## `pi3/monitor/status`
### Purpose
General status messages from the unified Pi 3 MQTT monitor service.

### Publisher
- Pi 3 MQTT monitor service

### Typical payload
```json
{
  "state": "monitor_online",
  "ts": "2026-04-08 19:30:00",
  "host": "pi3",
  "topics": [
    "smartcam/pi3/control",
    "sensehat/pi3/control",
    "greenhouse/sensehat/led_text"
  ]
}
```

### Why it exists
This topic gives app developers one place to observe monitor health without needing to watch feature-specific topics.

---

# 2. SmartCam topics

## `smartcam/pi3/control`
### Purpose
Control the Pi 3 webcam/RTSP stream.

### Direction
- Client -> Pi 3

### Default behavior
The SmartCam RTSP stream is intended to be **on-demand**, not always-on.

That means:
- the user/app should publish `start_stream` when it wants the RTSP stream to become available
- the user/app should publish `stop_stream` when it is done

Target operational model:
- RTSP is **not assumed to be running by default**
- MQTT control is the mechanism that turns streaming on/off

### Supported payloads
#### Start stream
```json
{"action":"start_stream"}
```

#### Stop stream
```json
{"action":"stop_stream"}
```

#### Start all Pi-side SmartCam work
```json
{"action":"start_all"}
```

#### Stop all Pi-side SmartCam work
```json
{"action":"stop_all"}
```

### Why it exists
This is the new normalized control topic for SmartCam.
It keeps stream-control logic separate from Sense HAT logic.

---

## `smartcam/pi3/status`
### Purpose
Reports the result of SmartCam control actions and stream state.

### Direction
- Pi 3 -> Client

### Example payload
```json
{
  "state": "handled",
  "topic": "smartcam/pi3/control",
  "handler": "smartcam",
  "result": {
    "state": "running",
    "rtsp": "rtsp://<SMARTCAM_HOST>:8554/stream"
  },
  "ts": "2026-04-08 19:35:00"
}
```

### Result states currently used
- `running`
- `stopped`
- `failed`
- `already_running`
- `ignored`

### Why it exists
Clients should not guess stream state. They should observe it here.

---

## `smartcam/pi3/person`
### Purpose
Person detection event output from the Ubuntu Coral detector.

### Direction
- Ubuntu detector -> Client

### Example detected payload
```json
{
  "event": "person_detected",
  "timestamp": "2026-04-08 19:45:00",
  "source": "rtsp://<SMARTCAM_HOST>:8554/stream",
  "count": 1,
  "top_detection": {
    "label": "person",
    "score": 0.82,
    "bbox": {
      "xmin": 10,
      "ymin": 20,
      "xmax": 100,
      "ymax": 200
    }
  },
  "inferenceMs": 18.4
}
```

### Example cleared payload
```json
{
  "event": "person_cleared",
  "timestamp": "2026-04-08 19:45:10",
  "source": "rtsp://<SMARTCAM_HOST>:8554/stream"
}
```

### Why it exists
This keeps AI detection output separate from stream lifecycle control.

---

# 3. Sense HAT topics

There are **two Sense HAT topic styles** now:

1. **Legacy compatibility topics**
2. **New normalized topics**

The reason both exist is to avoid breaking your current app while still moving toward a cleaner unified MQTT architecture.

---

## Legacy topic: `greenhouse/sensehat/readings`
### Purpose
Original sensor-data topic used by the earlier Sense HAT integration and your current app.

### Direction
- Pi 3 -> Client

### Example payload
```json
{
  "temperature_c": 43.80,
  "humidity_pct": 34.65,
  "pressure_hpa": 1012.35,
  "accel": {
    "x": -0.0086,
    "y": 0.0075,
    "z": 1.0104
  },
  "ts": 1775702659
}
```

### Why it exists
This is the **backward-compatible** topic your iOS app already knows how to parse.

### Recommendation
Keep supporting this topic until the iOS app fully migrates.

---

## Legacy topic: `greenhouse/sensehat/led_text`
### Purpose
Original command topic used to send LED matrix text messages to the Sense HAT.

### Direction
- Client -> Pi 3

### Current payload expectations
The merged monitor currently accepts JSON payloads such as:

```json
{"text":"Hello"}
```

or

```json
{"payload":"Hello"}
```

### Why it exists
This keeps older client behavior alive while the normalized command topic is introduced.

---

## New topic: `sensehat/pi3/control`
### Purpose
New normalized control topic for Sense HAT actions.

### Direction
- Client -> Pi 3

### Supported commands
#### Read sensor values once
```json
{"action":"read_once"}
```

#### Show LED text
```json
{"action":"show_text","text":"Hello"}
```

#### Clear LED matrix
```json
{"action":"clear"}
```

### Why it exists
This is the cleaner long-term command topic for Sense HAT in the unified Pi monitor.

---

## New topic: `sensehat/pi3/status`
### Purpose
New normalized response/status topic for Sense HAT command results.

### Direction
- Pi 3 -> Client

### Example sensor read response
```json
{
  "state": "handled",
  "topic": "sensehat/pi3/control",
  "handler": "sensehat",
  "result": {
    "state": "reading",
    "reading": {
      "ts": "2026-04-08 19:40:00",
      "temperature_c": 24.12,
      "humidity_pct": 52.71,
      "pressure_hpa": 1008.44
    }
  },
  "ts": "2026-04-08 19:40:00"
}
```

### Example show_text response
```json
{
  "state": "handled",
  "topic": "sensehat/pi3/control",
  "handler": "sensehat",
  "result": {
    "ok": true,
    "action": "show_text",
    "text": "Hello"
  },
  "ts": "2026-04-08 19:41:00"
}
```

### Why it exists
This gives the new unified monitor a consistent request/response model.

---

# What changed, and why?

## Old design
The older Sense HAT project effectively behaved like a dedicated feature-specific MQTT app using greenhouse-style topics:
- `greenhouse/sensehat/readings`
- `greenhouse/sensehat/led_text`

That worked fine when Sense HAT was the main feature.

## New design
Now the Pi 3 is acting as a multi-feature MQTT endpoint:
- SmartCam stream control
- Sense HAT functions
- future Pi-driven MQTT features

So the new naming groups features by subsystem:
- `smartcam/pi3/...`
- `sensehat/pi3/...`
- `pi3/monitor/...`

## Why this was changed
Because with one unified Pi-side service, normalized topic namespaces are easier to:
- understand
- document
- extend
- debug
- integrate into future clients

---

# Compatibility strategy

## Recommendation
Use a **dual-support** model during migration:

### Keep these legacy topics working
- `greenhouse/sensehat/readings`
- `greenhouse/sensehat/led_text`

### Add these normalized topics for new clients
- `sensehat/pi3/control`
- `sensehat/pi3/status`
- `smartcam/pi3/control`
- `smartcam/pi3/status`
- `smartcam/pi3/person`

This avoids breaking the current app while providing a cleaner long-term API.

---

# Recommended iOS client behavior

## For Sense HAT
If the current app already works with:
- `greenhouse/sensehat/readings`
- `greenhouse/sensehat/led_text`

then keep those paths for backward compatibility.

For future cleanup, prefer:
- command publish to `sensehat/pi3/control`
- read status from `sensehat/pi3/status`

## For SmartCam
Use:
- publish commands to `smartcam/pi3/control`
- read stream state from `smartcam/pi3/status`
- read person events from `smartcam/pi3/person`

## RTSP stream URL when active
`rtsp://<SMARTCAM_HOST>:8554/stream`

---

# Final recommendation
For your iOS coding agent:
- treat the **legacy Sense HAT topics** as backward-compatible support
- treat the **new normalized topics** as the long-term API contract
- prefer the normalized topics in new code
- preserve legacy support until the app is fully migrated
