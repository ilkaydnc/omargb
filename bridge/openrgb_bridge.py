#!/usr/bin/env python3
"""openrgb-bridge: a stdlib-only bridge between the Omarchy shell and OpenRGB.

The Omarchy shell is a QML process without TCP sockets, and the OpenRGB SDK is
a binary protocol on TCP port 6742. This script sits in between: the shell
spawns it, writes one JSON command per line on stdin, and reads one JSON event
per line on stdout. It keeps a single connection to the SDK server, reconnects
on its own, and re-reads device state after every change so the shell always
shows what the server believes.

No third-party packages: the protocol is small enough to speak with `struct`.
Protocol reference: OpenRGB `NetworkProtocol.h` and `RGBController.cpp`
(GetDeviceDescription / SetModeDescription).

Usage from a terminal, for debugging:

    openrgb_bridge.py --once                       # dump state as JSON and exit
    openrgb_bridge.py --once --cmd '{"op":"set_all","color":"#ff0000"}'
    echo '{"op":"refresh"}' | openrgb_bridge.py    # the shell's mode

Events (stdout):
    {"event":"hello","version":1,"openrgbBinary":"/usr/bin/openrgb"|null}
    {"event":"state","connected":bool,"host":..,"port":..,"protocol":n,
     "serverProtocol":n,"error":"..."|"","devices":[...]}
    {"event":"profiles","profiles":["..."]}
    {"event":"result","id":..,"op":"..","ok":bool,"error":"..."}

Commands (stdin), all optionally carrying an "id" echoed in the result:
    {"op":"refresh"}
    {"op":"connect","host":"127.0.0.1","port":6742}
    {"op":"set_color","device":0,"color":"#rrggbb"}          # whole device
    {"op":"set_color","device":0,"zone":1,"color":"#rrggbb"} # one zone
    {"op":"set_mode","device":0,"mode":2}                    # optional "color"
    {"op":"set_brightness","device":0,"value":50}
    {"op":"set_speed","device":0,"value":50}
    {"op":"set_all","color":"#rrggbb"}
    Any set_* may carry "quiet":true: apply, but skip the read-back and the
    state event. Slider drags stream these and finish with one loud write.
    {"op":"save","device":0}                                 # save active mode to flash
    {"op":"profiles"} / {"op":"load_profile","name":".."} / {"op":"save_profile","name":".."}
    {"op":"start_server"}                                    # spawn `openrgb --server`
    {"op":"quit"}
"""

import argparse
import collections
import errno
import json
import os
import select
import shutil
import socket
import struct
import subprocess
import sys
import time

BRIDGE_VERSION = 1

MAGIC = b"ORGB"
HEADER = struct.Struct("<4sIII")  # magic, device index, packet id, payload size

# The newest protocol revision this bridge knows how to parse. The server
# serializes with min(server, client), so declaring 4 keeps a newer server
# talking a layout we understand.
DEFAULT_PROTOCOL = 4
CLIENT_NAME = "Omarchy"

PKT_REQUEST_CONTROLLER_COUNT = 0
PKT_REQUEST_CONTROLLER_DATA = 1
PKT_REQUEST_PROTOCOL_VERSION = 40
PKT_SET_CLIENT_NAME = 50
PKT_DEVICE_LIST_UPDATED = 100
PKT_REQUEST_PROFILE_LIST = 150
PKT_REQUEST_LOAD_PROFILE = 151
PKT_REQUEST_SAVE_PROFILE = 152
PKT_REQUEST_DELETE_PROFILE = 153
PKT_RGBCONTROLLER_RESIZEZONE = 1000
PKT_RGBCONTROLLER_UPDATELEDS = 1050
PKT_RGBCONTROLLER_UPDATEZONELEDS = 1051
PKT_RGBCONTROLLER_UPDATESINGLELED = 1052
PKT_RGBCONTROLLER_SETCUSTOMMODE = 1100
PKT_RGBCONTROLLER_UPDATEMODE = 1101
PKT_RGBCONTROLLER_SAVEMODE = 1102

MODE_FLAG_HAS_SPEED = 1 << 0
MODE_FLAG_HAS_DIRECTION_LR = 1 << 1
MODE_FLAG_HAS_DIRECTION_UD = 1 << 2
MODE_FLAG_HAS_DIRECTION_HV = 1 << 3
MODE_FLAG_HAS_BRIGHTNESS = 1 << 4
MODE_FLAG_HAS_PER_LED_COLOR = 1 << 5
MODE_FLAG_HAS_MODE_SPECIFIC_COLOR = 1 << 6
MODE_FLAG_HAS_RANDOM_COLOR = 1 << 7
MODE_FLAG_MANUAL_SAVE = 1 << 8
MODE_FLAG_AUTOMATIC_SAVE = 1 << 9

MODE_COLORS_NONE = 0
MODE_COLORS_PER_LED = 1
MODE_COLORS_MODE_SPECIFIC = 2
MODE_COLORS_RANDOM = 3

COLOR_MODE_NAMES = {
    MODE_COLORS_NONE: "none",
    MODE_COLORS_PER_LED: "perLed",
    MODE_COLORS_MODE_SPECIFIC: "modeSpecific",
    MODE_COLORS_RANDOM: "random",
}

DEVICE_TYPES = [
    "motherboard", "dram", "gpu", "cooler", "ledstrip", "keyboard", "mouse",
    "mousemat", "headset", "headset_stand", "gamepad", "light", "speaker",
    "virtual", "storage", "case", "microphone", "accessory", "keypad",
    "laptop", "monitor",
]

ZONE_TYPES = {0: "single", 1: "linear", 2: "matrix"}

# Modes that make a good home for "just make it this color" requests, in
# order of preference when the active mode cannot take a color.
COLOR_MODE_PREFERENCE = ("static", "direct", "custom")

# How often to re-read the server for changes made by other clients, and how
# long to stay away after our own writes so a drag is not raced.
POLL_INTERVAL = 2.0
POLL_WRITE_HOLDOFF = 1.0

# Ceilings on what the peer may make this process allocate or loop over. The
# bridge runs unsandboxed and the port is only as trustworthy as whoever bound
# it first, so a packet header or device count is a claim, not an instruction.
# A controller with thousands of LEDs serializes to well under 1 MiB.
MAX_PACKET_SIZE = 4 * 1024 * 1024
MAX_DEVICES = 256


class ProtocolError(Exception):
    pass


class CommandError(Exception):
    pass


def log(*parts):
    sys.stderr.write("openrgb-bridge: " + " ".join(str(p) for p in parts) + "\n")
    sys.stderr.flush()


def parse_hex(value):
    s = str(value or "").strip()
    if s.startswith("#"):
        s = s[1:]
    if len(s) == 8:  # QML colors come out as #aarrggbb when alpha < 1
        s = s[2:]
    if len(s) == 3:
        s = "".join(ch * 2 for ch in s)
    if len(s) != 6:
        raise CommandError("invalid color %r" % (value,))
    try:
        return int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16)
    except ValueError:
        raise CommandError("invalid color %r" % (value,))


def to_hex(r, g, b):
    return "#%02x%02x%02x" % (r, g, b)


class Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0

    def _take(self, fmt):
        st = struct.Struct(fmt)
        if self.pos + st.size > len(self.data):
            raise ProtocolError("truncated controller data at byte %d" % self.pos)
        value = st.unpack_from(self.data, self.pos)[0]
        self.pos += st.size
        return value

    def u16(self):
        return self._take("<H")

    def u32(self):
        return self._take("<I")

    def i32(self):
        return self._take("<i")

    def skip(self, n):
        if self.pos + n > len(self.data):
            raise ProtocolError("truncated controller data at byte %d" % self.pos)
        self.pos += n

    def string(self):
        n = self.u16()
        raw = self.data[self.pos:self.pos + n]
        if len(raw) != n:
            raise ProtocolError("truncated string at byte %d" % self.pos)
        self.pos += n
        return raw.split(b"\0", 1)[0].decode("utf-8", "replace")

    def color(self):
        # RGBColor is 0x00BBGGRR, i.e. bytes R, G, B, 0 on the wire.
        r = self._take("<B")
        g = self._take("<B")
        b = self._take("<B")
        self._take("<B")
        return to_hex(r, g, b)


class Writer:
    def __init__(self):
        self.parts = []

    def u16(self, v):
        self.parts.append(struct.pack("<H", v))

    def u32(self, v):
        self.parts.append(struct.pack("<I", v))

    def i32(self, v):
        self.parts.append(struct.pack("<i", v))

    def string(self, s):
        raw = str(s).encode("utf-8") + b"\0"
        self.u16(len(raw))
        self.parts.append(raw)

    def color(self, hexstr):
        r, g, b = parse_hex(hexstr)
        self.parts.append(struct.pack("<BBBB", r, g, b, 0))

    def bytes(self):
        return b"".join(self.parts)


def parse_controller(data, version, index):
    r = Reader(data)
    r.u32()  # total size, repeated inside the payload
    dev_type = r.i32()
    name = r.string()
    vendor = r.string() if version >= 1 else ""
    description = r.string()
    fw_version = r.string()
    serial = r.string()
    location = r.string()

    num_modes = r.u16()
    active_mode = r.i32()
    modes = []
    for i in range(num_modes):
        m = {"index": i, "name": r.string(), "value": r.i32(), "flags": r.u32()}
        m["speedMin"] = r.u32()
        m["speedMax"] = r.u32()
        if version >= 3:
            m["brightnessMin"] = r.u32()
            m["brightnessMax"] = r.u32()
        else:
            m["brightnessMin"] = 0
            m["brightnessMax"] = 0
        m["colorsMin"] = r.u32()
        m["colorsMax"] = r.u32()
        m["speed"] = r.u32()
        m["brightness"] = r.u32() if version >= 3 else 0
        m["direction"] = r.u32()
        m["colorMode"] = r.u32()
        n = r.u16()
        m["colors"] = [r.color() for _ in range(n)]
        flags = m["flags"]
        m["colorModeName"] = COLOR_MODE_NAMES.get(m["colorMode"], "unknown")
        m["hasSpeed"] = bool(flags & MODE_FLAG_HAS_SPEED)
        m["hasBrightness"] = bool(flags & MODE_FLAG_HAS_BRIGHTNESS) and version >= 3 \
            and m["brightnessMax"] > m["brightnessMin"]
        m["hasDirection"] = bool(flags & (MODE_FLAG_HAS_DIRECTION_LR | MODE_FLAG_HAS_DIRECTION_UD
                                          | MODE_FLAG_HAS_DIRECTION_HV))
        m["acceptsColor"] = m["colorMode"] in (MODE_COLORS_PER_LED, MODE_COLORS_MODE_SPECIFIC)
        m["canSave"] = bool(flags & MODE_FLAG_MANUAL_SAVE)
        modes.append(m)

    num_zones = r.u16()
    zones = []
    for i in range(num_zones):
        z = {"index": i, "name": r.string(), "type": r.i32()}
        z["typeName"] = ZONE_TYPES.get(z["type"], "unknown")
        z["ledsMin"] = r.u32()
        z["ledsMax"] = r.u32()
        z["ledsCount"] = r.u32()
        matrix_len = r.u16()
        if matrix_len:
            # height, width, then height*width map entries; all inside matrix_len.
            r.skip(matrix_len)
        if version >= 4:
            num_segments = r.u16()
            segments = []
            for _ in range(num_segments):
                seg = {"name": r.string(), "type": r.i32(), "startIdx": r.u32(), "ledsCount": r.u32()}
                segments.append(seg)
            z["segments"] = segments
        if version >= 5:
            z["flags"] = r.u32()
        zones.append(z)

    num_leds = r.u16()
    led_names = []
    for _ in range(num_leds):
        led_names.append(r.string())
        r.u32()  # led value (vendor-specific)

    num_colors = r.u16()
    colors = [r.color() for _ in range(num_colors)]

    return {
        "index": index,
        "name": name,
        "vendor": vendor,
        "type": dev_type,
        "typeName": DEVICE_TYPES[dev_type] if 0 <= dev_type < len(DEVICE_TYPES) else "unknown",
        "description": description,
        "version": fw_version,
        "serial": serial,
        "location": location,
        "activeMode": active_mode,
        "modes": modes,
        "zones": zones,
        "ledCount": num_leds,
        "_colors": colors,
    }


def summarize_colors(dev):
    """Representative color for the bar and hero: what most LEDs show in
    per-LED modes, the first mode color otherwise."""
    modes = dev["modes"]
    active_mode = dev["activeMode"]
    colors = dev["_colors"]
    active = modes[active_mode] if 0 <= active_mode < len(modes) else None
    color = None
    uniform = True
    if active and active["colorMode"] == MODE_COLORS_PER_LED and colors:
        counted = collections.Counter(colors)
        color, count = counted.most_common(1)[0]
        uniform = count == len(colors)
    elif active and active["colorMode"] == MODE_COLORS_MODE_SPECIFIC and active["colors"]:
        color = active["colors"][0]
        uniform = len(set(active["colors"])) == 1
    return {
        "color": color,
        "uniform": uniform,
        "supportsColor": bool(active and active["acceptsColor"]),
    }


def mode_payload(mode_idx, mode, version):
    w = Writer()
    w.i32(mode_idx)
    w.string(mode["name"])
    w.i32(mode["value"])
    w.u32(mode["flags"])
    w.u32(mode["speedMin"])
    w.u32(mode["speedMax"])
    if version >= 3:
        w.u32(mode["brightnessMin"])
        w.u32(mode["brightnessMax"])
    w.u32(mode["colorsMin"])
    w.u32(mode["colorsMax"])
    w.u32(mode["speed"])
    if version >= 3:
        w.u32(mode["brightness"])
    w.u32(mode["direction"])
    w.u32(mode["colorMode"])
    w.u16(len(mode["colors"]))
    for c in mode["colors"]:
        w.color(c)
    body = w.bytes()
    return struct.pack("<I", len(body) + 4) + body


def leds_payload(colors):
    w = Writer()
    w.u16(len(colors))
    for c in colors:
        w.color(c)
    body = w.bytes()
    return struct.pack("<I", len(body) + 4) + body


def zone_leds_payload(zone_idx, colors):
    w = Writer()
    w.u32(zone_idx)
    w.u16(len(colors))
    for c in colors:
        w.color(c)
    body = w.bytes()
    return struct.pack("<I", len(body) + 4) + body


def public_device(dev):
    return {k: v for k, v in dev.items() if not k.startswith("_")}


class Bridge:
    def __init__(self, host, port, protocol, debug=False, emit=None):
        self.host = host
        self.port = port
        self.client_protocol = protocol
        self.debug = debug
        self.emit = emit or (lambda obj: None)
        self.sock = None
        self.version = 0
        self.server_version = 0
        self.devices = []
        self.profiles = []
        self.last_error = ""
        self.dirty = False
        self.dirty_since = 0.0
        self.next_connect = 0.0
        self.failures = 0
        self.server_process = None
        # Colors and modes have no change notification in the SDK, so external
        # writers (the OpenRGB GUI, another client) are caught by re-reading on
        # a timer and comparing against what was last published.
        self.last_write = 0.0
        self.last_poll = 0.0
        self._published = None

    # ------------------------------------------------------------ transport

    @property
    def connected(self):
        return self.sock is not None

    def send(self, dev_idx, pkt_id, payload=b""):
        if self.sock is None:
            raise ConnectionError("not connected")
        if pkt_id >= PKT_RGBCONTROLLER_RESIZEZONE or pkt_id in (
                PKT_REQUEST_LOAD_PROFILE, PKT_REQUEST_SAVE_PROFILE):
            self.last_write = time.monotonic()
        try:
            self.sock.sendall(HEADER.pack(MAGIC, dev_idx, pkt_id, len(payload)) + payload)
        except OSError as e:
            raise ConnectionError(str(e))

    def recv_exact(self, n):
        buf = bytearray()
        while len(buf) < n:
            try:
                chunk = self.sock.recv(n - len(buf))
            except socket.timeout:
                raise TimeoutError("timed out waiting for the OpenRGB server")
            except OSError as e:
                raise ConnectionError(str(e))
            if not chunk:
                raise ConnectionError("the OpenRGB server closed the connection")
            buf += chunk
        return bytes(buf)

    def recv_packet(self):
        magic, dev_idx, pkt_id, size = HEADER.unpack(self.recv_exact(HEADER.size))
        if magic != MAGIC:
            raise ProtocolError("bad packet magic %r" % (magic,))
        if size > MAX_PACKET_SIZE:
            raise ProtocolError("refusing a %d byte packet (ceiling %d)" % (size, MAX_PACKET_SIZE))
        payload = self.recv_exact(size) if size else b""
        return dev_idx, pkt_id, payload

    def handle_unsolicited(self, dev_idx, pkt_id, payload):
        if pkt_id == PKT_DEVICE_LIST_UPDATED:
            if not self.dirty:
                self.dirty_since = time.monotonic()
            self.dirty = True
        elif self.debug:
            log("ignoring unexpected packet", pkt_id, "for device", dev_idx)

    def request(self, dev_idx, pkt_id, payload=b"", expect=None, timeout=5.0):
        self.send(dev_idx, pkt_id, payload)
        if expect is None:
            return None
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("timed out waiting for packet %d" % expect)
            self.sock.settimeout(remaining)
            d, p, data = self.recv_packet()
            if p == expect and (expect != PKT_REQUEST_CONTROLLER_DATA or d == dev_idx):
                return data
            self.handle_unsolicited(d, p, data)

    # ------------------------------------------------------------ lifecycle

    def connect(self):
        self.close()
        try:
            sock = socket.create_connection((self.host, self.port), timeout=3.0)
        except OSError as e:
            raise ConnectionError(self.describe_connect_error(e))
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.sock = sock
        try:
            self.handshake()
            self.refresh_all()
            self.refresh_profiles()
        except Exception:
            self.close()
            raise

    def describe_connect_error(self, e):
        if isinstance(e, socket.timeout):
            return "connection to %s:%d timed out" % (self.host, self.port)
        if getattr(e, "errno", None) == errno.ECONNREFUSED:
            return "no OpenRGB server on %s:%d" % (self.host, self.port)
        return "cannot reach %s:%d: %s" % (self.host, self.port, e)

    def handshake(self):
        # Old servers (protocol 0) never answer the version request; a short
        # wait then falling back to 0 is what OpenRGB's own client does.
        try:
            data = self.request(0, PKT_REQUEST_PROTOCOL_VERSION, struct.pack("<I", self.client_protocol),
                                expect=PKT_REQUEST_PROTOCOL_VERSION, timeout=2.0)
            self.server_version = struct.unpack("<I", data[:4])[0]
        except TimeoutError:
            self.server_version = 0
        self.version = min(self.client_protocol, self.server_version)
        self.send(0, PKT_SET_CLIENT_NAME, CLIENT_NAME.encode("utf-8") + b"\0")

    def close(self):
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None
        self.dirty = False

    def drop(self, reason):
        self.close()
        self.last_error = str(reason)
        self.failures += 1
        self.next_connect = time.monotonic() + min(1.0 + self.failures, 8.0)
        self.emit_state()

    # ------------------------------------------------------------ reads

    def fetch_device(self, index):
        payload = struct.pack("<I", self.version) if self.version >= 1 else b""
        data = self.request(index, PKT_REQUEST_CONTROLLER_DATA, payload, expect=PKT_REQUEST_CONTROLLER_DATA)
        dev = parse_controller(data, self.version, index)
        dev.update(summarize_colors(dev))
        return dev

    def device_count(self):
        data = self.request(0, PKT_REQUEST_CONTROLLER_COUNT, expect=PKT_REQUEST_CONTROLLER_COUNT)
        if len(data) < 4:
            raise ProtocolError("truncated controller count")
        count = struct.unpack("<I", data[:4])[0]
        if count > MAX_DEVICES:
            raise ProtocolError("refusing to enumerate %d devices (ceiling %d)" % (count, MAX_DEVICES))
        return count

    def refresh_all(self):
        count = self.device_count()
        self.devices = [self.fetch_device(i) for i in range(count)]
        self.dirty = False
        self.failures = 0
        self.last_error = ""
        self.last_poll = time.monotonic()
        self.emit_state()

    def refresh_device(self, index):
        if 0 <= index < len(self.devices):
            self.devices[index] = self.fetch_device(index)

    def refresh_profiles(self):
        if self.version < 2:
            self.profiles = []
            return
        data = self.request(0, PKT_REQUEST_PROFILE_LIST, expect=PKT_REQUEST_PROFILE_LIST)
        r = Reader(data)
        r.u32()
        n = r.u16()
        self.profiles = [r.string() for _ in range(n)]
        self.emit({"event": "profiles", "profiles": self.profiles})

    def emit_state(self):
        devices = [public_device(d) for d in self.devices] if self.connected else []
        self._published = json.dumps(devices, sort_keys=True)
        self.emit({
            "event": "state",
            "connected": self.connected,
            "host": self.host,
            "port": self.port,
            "protocol": self.version,
            "serverProtocol": self.server_version,
            "error": "" if self.connected else self.last_error,
            # Re-checked on every report so an install that happens while the
            # bridge is already running shows up without a restart.
            "openrgbBinary": shutil.which("openrgb"),
            "devices": devices,
        })

    def poll_devices(self):
        """Re-read everything; republish only when something actually changed.

        This is what makes the panel a mirror rather than a one-way remote:
        colors set by the OpenRGB GUI, a game, or any other SDK client show up
        here within a couple of seconds. Comparing against the last published
        state keeps the shell quiet for the overwhelmingly common no-change
        case."""
        count = self.device_count()
        self.devices = [self.fetch_device(i) for i in range(count)]
        fresh = json.dumps([public_device(d) for d in self.devices], sort_keys=True)
        if fresh != self._published:
            self.emit_state()

    # ------------------------------------------------------------ writes

    def device(self, index):
        try:
            index = int(index)
        except (TypeError, ValueError):
            raise CommandError("device index required")
        if not 0 <= index < len(self.devices):
            raise CommandError("no device %d" % index)
        return self.devices[index]

    def active_mode(self, dev):
        i = dev["activeMode"]
        if not 0 <= i < len(dev["modes"]):
            raise CommandError("%s has no active mode" % dev["name"])
        return dev["modes"][i]

    def pick_color_mode(self, dev):
        """A mode that can hold a color, preferring the active one."""
        active = self.active_mode(dev)
        if active["acceptsColor"]:
            return active
        by_name = {m["name"].strip().lower(): m for m in dev["modes"] if m["acceptsColor"]}
        for name in COLOR_MODE_PREFERENCE:
            if name in by_name:
                return by_name[name]
        for m in dev["modes"]:
            if m["acceptsColor"]:
                return m
        raise CommandError("%s has no mode that takes a color" % dev["name"])

    def send_mode(self, dev, mode, save=False):
        pkt = PKT_RGBCONTROLLER_SAVEMODE if save else PKT_RGBCONTROLLER_UPDATEMODE
        self.send(dev["index"], pkt, mode_payload(mode["index"], mode, self.version))

    def apply_mode(self, dev, mode, color=None):
        """Switch `dev` to `mode`, carrying `color` into it when it takes one."""
        mode = dict(mode)
        mode["colors"] = list(mode["colors"])
        if mode["colorMode"] == MODE_COLORS_MODE_SPECIFIC:
            if color is None and not mode["colors"]:
                color = dev.get("color") or "#ffffff"
            if color is not None:
                want = max(mode["colorsMin"], min(max(len(mode["colors"]), 1), mode["colorsMax"] or 1))
                mode["colors"] = [color] * want
        self.send_mode(dev, mode)
        # Reflect the switch locally: quiet writes never re-read the device,
        # and the next command may depend on the mode this one just set.
        dev["activeMode"] = mode["index"]
        dev["modes"][mode["index"]] = mode
        if mode["colorMode"] == MODE_COLORS_PER_LED and color is not None and dev["ledCount"]:
            self.send(dev["index"], PKT_RGBCONTROLLER_UPDATELEDS,
                      leds_payload([color] * dev["ledCount"]))

    def set_color(self, dev, color, zone=None):
        mode = self.active_mode(dev)
        if not mode["acceptsColor"]:
            target = self.pick_color_mode(dev)
            self.apply_mode(dev, target, color)
            return
        if mode["colorMode"] == MODE_COLORS_PER_LED:
            if zone is None:
                if not dev["ledCount"]:
                    raise CommandError("%s has no LEDs" % dev["name"])
                self.send(dev["index"], PKT_RGBCONTROLLER_UPDATELEDS,
                          leds_payload([color] * dev["ledCount"]))
            else:
                zone = int(zone)
                if not 0 <= zone < len(dev["zones"]):
                    raise CommandError("no zone %d on %s" % (zone, dev["name"]))
                count = dev["zones"][zone]["ledsCount"]
                self.send(dev["index"], PKT_RGBCONTROLLER_UPDATEZONELEDS,
                          zone_leds_payload(zone, [color] * count))
        else:
            self.apply_mode(dev, mode, color)

    def set_mode(self, dev, mode_index, color=None):
        try:
            mode_index = int(mode_index)
        except (TypeError, ValueError):
            raise CommandError("mode index required")
        if not 0 <= mode_index < len(dev["modes"]):
            raise CommandError("no mode %d on %s" % (mode_index, dev["name"]))
        self.apply_mode(dev, dev["modes"][mode_index], color)

    def set_mode_field(self, dev, field, value, lo_key, hi_key, flag_key):
        mode = self.active_mode(dev)
        if not mode[flag_key]:
            raise CommandError("%s (%s) has no %s control" % (dev["name"], mode["name"], field))
        try:
            value = int(round(float(value)))
        except (TypeError, ValueError):
            raise CommandError("%s value required" % field)
        lo, hi = mode[lo_key], mode[hi_key]
        if hi >= lo:
            value = max(lo, min(hi, value))
        mode = dict(mode)
        mode[field] = value
        self.send_mode(dev, mode)

    def save_device(self, dev):
        mode = self.active_mode(dev)
        if not mode["canSave"]:
            raise CommandError("%s cannot save %s to the device" % (dev["name"], mode["name"]))
        self.send_mode(dev, mode, save=True)

    def load_profile(self, name):
        self.send(0, PKT_REQUEST_LOAD_PROFILE, str(name).encode("utf-8") + b"\0")

    def save_profile(self, name):
        self.send(0, PKT_REQUEST_SAVE_PROFILE, str(name).encode("utf-8") + b"\0")

    def start_server(self):
        binary = shutil.which("openrgb")
        if not binary:
            raise CommandError("openrgb is not installed")
        if self.server_process is not None and self.server_process.poll() is None:
            return
        cmd = [binary, "--server", "--server-port", str(self.port), "--noautoconnect"]
        self.server_process = subprocess.Popen(
            cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        # Give it a head start before the next reconnect attempt.
        self.next_connect = time.monotonic() + 1.5
        self.failures = 0

    # ------------------------------------------------------------ commands

    def run_command(self, cmd):
        op = str(cmd.get("op", ""))
        quiet = cmd.get("quiet") is True
        if op == "quit":
            raise SystemExit(0)
        if op == "start_server":
            self.start_server()
            return
        if op == "connect":
            host = str(cmd.get("host") or self.host)
            port = int(cmd.get("port") or self.port)
            if host != self.host or port != self.port or not self.connected:
                self.host, self.port = host, port
                self.close()
                self.failures = 0
                self.next_connect = 0.0
            return
        if not self.connected:
            raise CommandError(self.last_error or "not connected to OpenRGB")

        if op == "refresh":
            self.refresh_all()
            self.refresh_profiles()
            return
        if op == "profiles":
            self.refresh_profiles()
            return
        if op == "set_all":
            color = to_hex(*parse_hex(cmd.get("color")))
            errors = []
            for dev in list(self.devices):
                try:
                    self.set_color(dev, color)
                except CommandError as e:
                    errors.append(str(e))
            # A slider drag streams colors dozens of times a second.
            # Re-reading every device and republishing the list at that rate
            # would swamp the shell for nothing, so those writes stay quiet.
            if not quiet:
                for dev in list(self.devices):
                    self.refresh_device(dev["index"])
                self.emit_state()
            if errors and len(errors) == len(self.devices):
                raise CommandError("; ".join(errors))
            return
        if op == "load_profile":
            self.load_profile(cmd.get("name", ""))
            time.sleep(0.2)
            self.refresh_all()
            return
        if op == "save_profile":
            self.save_profile(cmd.get("name", ""))
            self.refresh_profiles()
            return

        dev = self.device(cmd.get("device"))
        if op == "set_color":
            color = to_hex(*parse_hex(cmd.get("color")))
            self.set_color(dev, color, cmd.get("zone"))
        elif op == "set_mode":
            color = cmd.get("color")
            self.set_mode(dev, cmd.get("mode"), to_hex(*parse_hex(color)) if color else None)
        elif op == "set_brightness":
            self.set_mode_field(dev, "brightness", cmd.get("value"), "brightnessMin", "brightnessMax", "hasBrightness")
        elif op == "set_speed":
            self.set_mode_field(dev, "speed", cmd.get("value"), "speedMin", "speedMax", "hasSpeed")
        elif op == "save":
            self.save_device(dev)
        else:
            raise CommandError("unknown op %r" % op)
        if not quiet:
            self.refresh_device(dev["index"])
            self.emit_state()

    def execute(self, cmd):
        op = str(cmd.get("op", ""))
        result = {"event": "result", "op": op, "ok": True}
        if "id" in cmd:
            result["id"] = cmd["id"]
        try:
            self.run_command(cmd)
        except CommandError as e:
            result["ok"] = False
            result["error"] = str(e)
        except (ConnectionError, TimeoutError, ProtocolError) as e:
            result["ok"] = False
            result["error"] = str(e)
            self.drop(e)
        # A quiet write that worked says nothing; failures always report, so
        # a broken drag surfaces instead of failing silently.
        if result["ok"] and cmd.get("quiet") is True:
            return
        self.emit(result)

    # ------------------------------------------------------------ main loop

    def tick(self):
        """Reconnect when due and flush pending device-list refreshes."""
        now = time.monotonic()
        if not self.connected and now >= self.next_connect:
            try:
                self.connect()
            except (ConnectionError, TimeoutError, ProtocolError) as e:
                self.drop(e)
        elif self.connected and self.dirty and now - self.dirty_since >= 0.3:
            try:
                self.refresh_all()
                self.refresh_profiles()
            except (ConnectionError, TimeoutError, ProtocolError) as e:
                self.drop(e)
        elif (self.connected and now - self.last_poll >= POLL_INTERVAL
                and now - self.last_write >= POLL_WRITE_HOLDOFF):
            # The holdoff keeps the poll away from a stream of writes: a drag
            # in progress would otherwise race its own read-backs.
            self.last_poll = now
            try:
                self.poll_devices()
            except (ConnectionError, TimeoutError, ProtocolError) as e:
                self.drop(e)

    def next_timeout(self):
        now = time.monotonic()
        if not self.connected:
            return max(0.05, self.next_connect - now)
        if self.dirty:
            return max(0.05, 0.3 - (now - self.dirty_since))
        return 1.0

    def pump_socket(self):
        """Read one unsolicited packet; the socket is known to be readable."""
        try:
            self.sock.settimeout(2.0)
            d, p, data = self.recv_packet()
            self.handle_unsolicited(d, p, data)
        except (ConnectionError, TimeoutError, ProtocolError) as e:
            self.drop(e)


def coalesce(commands):
    """Drop superseded slider updates: only the last set_* per device survives."""
    latest = {}
    for i, cmd in enumerate(commands):
        op = cmd.get("op")
        if op in ("set_color", "set_brightness", "set_speed"):
            key = (op, cmd.get("device"), cmd.get("zone"))
        elif op == "set_all":
            key = (op,)
        else:
            key = ("__unique__", i)
        latest[key] = i
    keep = set(latest.values())
    return [cmd for i, cmd in enumerate(commands) if i in keep]


def serve(bridge):
    emit = bridge.emit
    emit({"event": "hello", "version": BRIDGE_VERSION, "openrgbBinary": shutil.which("openrgb")})
    stdin_fd = sys.stdin.fileno()
    buffer = b""
    while True:
        bridge.tick()
        rlist = [stdin_fd]
        if bridge.sock is not None:
            rlist.append(bridge.sock)
        try:
            ready, _, _ = select.select(rlist, [], [], bridge.next_timeout())
        except InterruptedError:
            continue
        if bridge.sock is not None and bridge.sock in ready:
            bridge.pump_socket()
        if stdin_fd in ready:
            chunk = os.read(stdin_fd, 65536)
            if not chunk:
                return 0
            buffer += chunk
            lines = buffer.split(b"\n")
            buffer = lines.pop()
            commands = []
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    cmd = json.loads(line.decode("utf-8"))
                except ValueError:
                    emit({"event": "result", "ok": False, "error": "invalid JSON command"})
                    continue
                if isinstance(cmd, dict):
                    commands.append(cmd)
            for cmd in coalesce(commands):
                bridge.execute(cmd)


def main(argv=None):
    parser = argparse.ArgumentParser(description="Bridge between the Omarchy shell and the OpenRGB SDK server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6742)
    parser.add_argument("--protocol", type=int, default=DEFAULT_PROTOCOL,
                        help="highest SDK protocol version to negotiate (default %d)" % DEFAULT_PROTOCOL)
    parser.add_argument("--once", action="store_true", help="connect, run --cmd commands, print state, exit")
    parser.add_argument("--cmd", action="append", default=[], help="JSON command to run with --once")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args(argv)

    def emit(obj):
        try:
            sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
            sys.stdout.flush()
        except BrokenPipeError:
            raise SystemExit(0)

    bridge = Bridge(args.host, args.port, args.protocol, debug=args.debug, emit=emit)

    if args.once:
        events = []
        bridge.emit = events.append
        try:
            bridge.connect()
        except (ConnectionError, TimeoutError, ProtocolError) as e:
            print(json.dumps({"connected": False, "error": str(e)}, indent=2))
            return 1
        for raw in args.cmd:
            bridge.execute(json.loads(raw))
        results = [e for e in events if e.get("event") == "result"]
        state = {
            "connected": True, "protocol": bridge.version, "serverProtocol": bridge.server_version,
            "profiles": bridge.profiles, "results": results,
            "devices": [public_device(d) for d in bridge.devices],
        }
        print(json.dumps(state, indent=2))
        return 0 if all(r.get("ok") for r in results) else 1

    try:
        return serve(bridge)
    except KeyboardInterrupt:
        return 0
    finally:
        bridge.close()


if __name__ == "__main__":
    sys.exit(main())
