#!/usr/bin/env python3
"""A tiny fake OpenRGB SDK server for exercising the bridge without hardware.

It speaks protocol version 4, serves two made-up devices, and applies
UpdateLEDs / UpdateMode / SaveMode packets to its in-memory state so tests can
read back what the bridge wrote. Run it by hand to develop the panel without
OpenRGB installed:

    python3 tests/mock_server.py --port 6742
"""

import argparse
import socket
import struct
import sys
import threading

sys.path.insert(0, __import__("os").path.join(__import__("os").path.dirname(__file__), "..", "bridge"))
import openrgb_bridge as p  # noqa: E402

SERVER_PROTOCOL = 4


def rgb(hexstr):
    r, g, b = p.parse_hex(hexstr)
    return struct.pack("<BBBB", r, g, b, 0)


def make_mode(name, value, flags, color_mode, colors, speed=(0, 0, 0), brightness=(0, 0, 0)):
    return {
        "name": name, "value": value, "flags": flags,
        "speedMin": speed[0], "speedMax": speed[1], "speed": speed[2],
        "brightnessMin": brightness[0], "brightnessMax": brightness[1], "brightness": brightness[2],
        "colorsMin": 0 if color_mode != p.MODE_COLORS_MODE_SPECIFIC else 1,
        "colorsMax": 0 if color_mode != p.MODE_COLORS_MODE_SPECIFIC else 1,
        "direction": 0, "colorMode": color_mode, "colors": list(colors),
    }


def make_devices():
    keyboard = {
        "type": 5, "name": "Mock Apex Pro", "vendor": "SteelSeries", "description": "Mock keyboard",
        "version": "1.0", "serial": "KB-1", "location": "HID: /dev/hidraw9",
        "activeMode": 0,
        "modes": [
            make_mode("Direct", 0, p.MODE_FLAG_HAS_PER_LED_COLOR, p.MODE_COLORS_PER_LED, []),
            make_mode("Static", 1, p.MODE_FLAG_HAS_MODE_SPECIFIC_COLOR | p.MODE_FLAG_HAS_BRIGHTNESS | p.MODE_FLAG_MANUAL_SAVE,
                      p.MODE_COLORS_MODE_SPECIFIC, ["#102030"], brightness=(0, 100, 80)),
            make_mode("Rainbow Wave", 2, p.MODE_FLAG_HAS_SPEED, p.MODE_COLORS_NONE, [], speed=(0, 100, 50)),
        ],
        "zones": [
            {"name": "Keyboard", "type": 2, "ledsMin": 6, "ledsMax": 6, "ledsCount": 6,
             "matrix": (2, 3, [0, 1, 2, 3, 4, 5]), "segments": []},
        ],
        "leds": ["Key: %d" % i for i in range(6)],
        "colors": ["#000000"] * 6,
    }
    strip = {
        "type": 4, "name": "Mock LED Strip", "vendor": "Generic", "description": "Mock strip",
        "version": "", "serial": "", "location": "",
        "activeMode": 1,
        "modes": [
            make_mode("Off", 0, 0, p.MODE_COLORS_NONE, []),
            make_mode("Direct", 1, p.MODE_FLAG_HAS_PER_LED_COLOR, p.MODE_COLORS_PER_LED, []),
            make_mode("Custom", 2, p.MODE_FLAG_HAS_PER_LED_COLOR, p.MODE_COLORS_PER_LED, []),
        ],
        "zones": [
            {"name": "Strip A", "type": 1, "ledsMin": 1, "ledsMax": 8, "ledsCount": 4, "matrix": None,
             "segments": [{"name": "Front", "type": 1, "startIdx": 0, "ledsCount": 2}]},
            {"name": "Strip B", "type": 1, "ledsMin": 1, "ledsMax": 8, "ledsCount": 2, "matrix": None, "segments": []},
        ],
        "leds": ["LED %d" % i for i in range(6)],
        "colors": ["#ff0000", "#ff0000", "#00ff00", "#00ff00", "#0000ff", "#0000ff"],
    }
    return [keyboard, strip]


def serialize_device(dev, version):
    w = p.Writer()
    w.i32(dev["type"])
    w.string(dev["name"])
    if version >= 1:
        w.string(dev["vendor"])
    w.string(dev["description"])
    w.string(dev["version"])
    w.string(dev["serial"])
    w.string(dev["location"])
    w.u16(len(dev["modes"]))
    w.i32(dev["activeMode"])
    for m in dev["modes"]:
        w.string(m["name"])
        w.i32(m["value"])
        w.u32(m["flags"])
        w.u32(m["speedMin"])
        w.u32(m["speedMax"])
        if version >= 3:
            w.u32(m["brightnessMin"])
            w.u32(m["brightnessMax"])
        w.u32(m["colorsMin"])
        w.u32(m["colorsMax"])
        w.u32(m["speed"])
        if version >= 3:
            w.u32(m["brightness"])
        w.u32(m["direction"])
        w.u32(m["colorMode"])
        w.u16(len(m["colors"]))
        for c in m["colors"]:
            w.color(c)
    w.u16(len(dev["zones"]))
    for z in dev["zones"]:
        w.string(z["name"])
        w.i32(z["type"])
        w.u32(z["ledsMin"])
        w.u32(z["ledsMax"])
        w.u32(z["ledsCount"])
        if z["matrix"]:
            h, wd, cells = z["matrix"]
            w.u16(4 * (2 + h * wd))
            w.u32(h)
            w.u32(wd)
            for cell in cells:
                w.u32(cell)
        else:
            w.u16(0)
        if version >= 4:
            w.u16(len(z["segments"]))
            for s in z["segments"]:
                w.string(s["name"])
                w.i32(s["type"])
                w.u32(s["startIdx"])
                w.u32(s["ledsCount"])
    w.u16(len(dev["leds"]))
    for name in dev["leds"]:
        w.string(name)
        w.u32(0)
    w.u16(len(dev["colors"]))
    for c in dev["colors"]:
        w.color(c)
    body = w.bytes()
    return struct.pack("<I", len(body) + 4) + body


class MockServer:
    def __init__(self, host="127.0.0.1", port=0):
        self.devices = make_devices()
        self.profiles = ["Default", "Gaming"]
        self.loaded_profiles = []
        self.saved_profiles = []
        self.saved_modes = []
        self.client_name = None
        self.client_version = 0
        self.lock = threading.Lock()
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind((host, port))
        self.listener.listen(4)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self.accept_loop, daemon=True)
        self.stopped = False

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        self.stopped = True
        # close() alone leaves the listening socket alive while another thread
        # is blocked in accept(); shutdown() is what actually wakes it.
        try:
            self.listener.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            self.listener.close()
        except OSError:
            pass
        if self.thread.is_alive() and threading.current_thread() is not self.thread:
            self.thread.join(timeout=2)

    def accept_loop(self):
        while not self.stopped:
            try:
                conn, _ = self.listener.accept()
            except OSError:
                return
            threading.Thread(target=self.serve_client, args=(conn,), daemon=True).start()

    @staticmethod
    def recv_exact(conn, n):
        buf = b""
        while len(buf) < n:
            chunk = conn.recv(n - len(buf))
            if not chunk:
                raise ConnectionError
            buf += chunk
        return buf

    def reply(self, conn, dev_idx, pkt_id, payload=b""):
        conn.sendall(p.HEADER.pack(p.MAGIC, dev_idx, pkt_id, len(payload)) + payload)

    def serve_client(self, conn):
        try:
            while True:
                magic, dev_idx, pkt_id, size = p.HEADER.unpack(self.recv_exact(conn, p.HEADER.size))
                assert magic == p.MAGIC
                data = self.recv_exact(conn, size) if size else b""
                with self.lock:
                    self.handle(conn, dev_idx, pkt_id, data)
        except (ConnectionError, OSError, AssertionError):
            pass
        finally:
            conn.close()

    def handle(self, conn, dev_idx, pkt_id, data):
        if pkt_id == p.PKT_REQUEST_PROTOCOL_VERSION:
            self.client_version = min(SERVER_PROTOCOL, struct.unpack("<I", data[:4])[0])
            self.reply(conn, 0, pkt_id, struct.pack("<I", SERVER_PROTOCOL))
        elif pkt_id == p.PKT_SET_CLIENT_NAME:
            self.client_name = data.rstrip(b"\0").decode()
        elif pkt_id == p.PKT_REQUEST_CONTROLLER_COUNT:
            self.reply(conn, 0, pkt_id, struct.pack("<I", len(self.devices)))
        elif pkt_id == p.PKT_REQUEST_CONTROLLER_DATA:
            version = struct.unpack("<I", data[:4])[0] if len(data) >= 4 else 0
            self.reply(conn, dev_idx, pkt_id, serialize_device(self.devices[dev_idx], version))
        elif pkt_id == p.PKT_REQUEST_PROFILE_LIST:
            w = p.Writer()
            w.u16(len(self.profiles))
            for name in self.profiles:
                w.string(name)
            body = w.bytes()
            self.reply(conn, 0, pkt_id, struct.pack("<I", len(body) + 4) + body)
        elif pkt_id == p.PKT_REQUEST_LOAD_PROFILE:
            self.loaded_profiles.append(data.rstrip(b"\0").decode())
        elif pkt_id == p.PKT_REQUEST_SAVE_PROFILE:
            name = data.rstrip(b"\0").decode()
            self.saved_profiles.append(name)
            if name not in self.profiles:
                self.profiles.append(name)
        elif pkt_id == p.PKT_RGBCONTROLLER_UPDATELEDS:
            dev = self.devices[dev_idx]
            r = p.Reader(data)
            r.u32()
            n = r.u16()
            colors = [r.color() for _ in range(n)]
            dev["colors"][:len(colors)] = colors
        elif pkt_id == p.PKT_RGBCONTROLLER_UPDATEZONELEDS:
            dev = self.devices[dev_idx]
            r = p.Reader(data)
            r.u32()
            zone = r.u32()
            n = r.u16()
            colors = [r.color() for _ in range(n)]
            start = sum(z["ledsCount"] for z in dev["zones"][:zone])
            dev["colors"][start:start + n] = colors
        elif pkt_id in (p.PKT_RGBCONTROLLER_UPDATEMODE, p.PKT_RGBCONTROLLER_SAVEMODE):
            dev = self.devices[dev_idx]
            r = p.Reader(data)
            r.u32()
            idx = r.i32()
            mode = dev["modes"][idx]
            r.string()  # name is ignored, like the real server
            mode["value"] = r.i32()
            mode["flags"] = r.u32()
            mode["speedMin"] = r.u32()
            mode["speedMax"] = r.u32()
            if self.client_version >= 3:
                mode["brightnessMin"] = r.u32()
                mode["brightnessMax"] = r.u32()
            mode["colorsMin"] = r.u32()
            mode["colorsMax"] = r.u32()
            mode["speed"] = r.u32()
            if self.client_version >= 3:
                mode["brightness"] = r.u32()
            mode["direction"] = r.u32()
            mode["colorMode"] = r.u32()
            n = r.u16()
            mode["colors"] = [r.color() for _ in range(n)]
            dev["activeMode"] = idx
            if pkt_id == p.PKT_RGBCONTROLLER_SAVEMODE:
                self.saved_modes.append((dev_idx, idx))

    def push_device_list_updated(self):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=6742)
    args = parser.parse_args()
    server = MockServer(args.host, args.port).start()
    print("mock OpenRGB server listening on %s:%d" % (args.host, server.port), flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        server.stop()


if __name__ == "__main__":
    main()
