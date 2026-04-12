# PI3 Sense HAT MQTT Topics

## Broker
- Host: `<MQTT_BROKER_HOST>`
- Port: `<MQTT_BROKER_PORT>`

## Final topic set

### 1. Sense HAT control
**Topic:** `sensehat/pi3/control`

Accepts JSON or plain text.

#### Read sensor data once
```json
{"action":"read_once"}
```

#### Show scrolling text
```json
{"action":"show_text","text":"hello"}
```

or plain text:
```text
hello
```

#### Turn LEDs on
```json
{"action":"lights_on"}
```

or

```json
{"action":"led_on"}
```

or plain text:
```text
lights on
```

#### Turn LEDs off
```json
{"action":"lights_off"}
```

or

```json
{"action":"led_off"}
```

or

```json
{"action":"clear"}
```

or plain text:
```text
lights off
```

### 2. Sense HAT status
**Topic:** `sensehat/pi3/status`

Returns command results and readings.

#### Example read response
```json
{
  "state": "handled",
  "topic": "sensehat/pi3/control",
  "handler": "sensehat",
  "ts": "2026-04-11 19:13:53",
  "result": {
    "state": "reading",
    "reading": {
      "ts": "2026-04-11 19:13:53",
      "temperature_c": 44.6,
      "humidity_pct": 30.39,
      "pressure_hpa": 1014.64,
      "orientation_deg": {
        "pitch": 2.01,
        "roll": 3.91,
        "yaw": 119.39
      },
      "accelerometer": {
        "x": -0.0064,
        "y": 0.0575,
        "z": 0.9148
      },
      "gyroscope": {
        "x": -0.2828,
        "y": 0.1215,
        "z": 0.2188
      }
    }
  },
  "reading": {
    "ts": "2026-04-11 19:13:53",
    "temperature_c": 44.6,
    "humidity_pct": 30.39,
    "pressure_hpa": 1014.64,
    "orientation_deg": {
      "pitch": 2.01,
      "roll": 3.91,
      "yaw": 119.39
    },
    "accelerometer": {
      "x": -0.0064,
      "y": 0.0575,
      "z": 0.9148
    },
    "gyroscope": {
      "x": -0.2828,
      "y": 0.1215,
      "z": 0.2188
    }
  }
}
```

### 3. Pi monitor status
**Topic:** `pi3/monitor/status`

General monitor lifecycle or JSON decode errors.

## Removed legacy topics
These are no longer part of the final design:
- `greenhouse/sensehat/readings`
- `greenhouse/sensehat/led_text`

## Verified working
- `sensehat/pi3/control` with `read_once`
- `sensehat/pi3/control` with `lights on`
- `sensehat/pi3/control` with `lights off`
- `sensehat/pi3/status`

## Sensor fields now included
- `temperature_c`
- `humidity_pct`
- `pressure_hpa`
- `orientation_deg.pitch`
- `orientation_deg.roll`
- `orientation_deg.yaw`
- `accelerometer.x`
- `accelerometer.y`
- `accelerometer.z`
- `gyroscope.x`
- `gyroscope.y`
- `gyroscope.z`
