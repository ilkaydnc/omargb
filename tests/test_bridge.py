#!/usr/bin/env python3
"""Bridge tests against the mock server. Run: python3 -m unittest discover tests"""

import json
import os
import subprocess
import sys
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "bridge"))
sys.path.insert(0, HERE)

import openrgb_bridge as bridge  # noqa: E402
from mock_server import MockServer  # noqa: E402

BRIDGE = os.path.join(HERE, "..", "bridge", "openrgb_bridge.py")


class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.server = MockServer().start()

    def tearDown(self):
        self.server.stop()

    def once(self, *cmds):
        argv = [sys.executable, BRIDGE, "--port", str(self.server.port), "--once"]
        for c in cmds:
            argv += ["--cmd", json.dumps(c)]
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=20)
        self.assertEqual(proc.stderr, "")
        return json.loads(proc.stdout), proc.returncode

    def test_handshake_and_parse(self):
        state, code = self.once()
        self.assertEqual(code, 0)
        self.assertTrue(state["connected"])
        self.assertEqual(state["protocol"], 4)
        self.assertEqual(self.server.client_name, "Omarchy")
        self.assertEqual(state["profiles"], ["Default", "Gaming"])
        self.assertEqual([d["name"] for d in state["devices"]], ["Mock Apex Pro", "Mock LED Strip"])

        kb = state["devices"][0]
        self.assertEqual(kb["typeName"], "keyboard")
        self.assertEqual(kb["ledCount"], 6)
        self.assertEqual(kb["zones"][0]["typeName"], "matrix")
        self.assertEqual([m["name"] for m in kb["modes"]], ["Direct", "Static", "Rainbow Wave"])
        self.assertTrue(kb["modes"][1]["hasBrightness"])
        self.assertTrue(kb["modes"][1]["canSave"])
        self.assertTrue(kb["modes"][2]["hasSpeed"])
        self.assertFalse(kb["modes"][2]["acceptsColor"])
        self.assertEqual(kb["color"], "#000000")
        self.assertTrue(kb["uniform"])
        self.assertNotIn("_colors", kb)

        strip = state["devices"][1]
        self.assertEqual(strip["zones"][0]["segments"][0]["name"], "Front")
        self.assertEqual(strip["color"], "#ff0000")  # most common wins ties by order
        self.assertFalse(strip["uniform"])

    def test_set_color_per_led(self):
        state, code = self.once({"op": "set_color", "device": 0, "color": "#ff8800"})
        self.assertEqual(code, 0)
        self.assertEqual(self.server.devices[0]["colors"], ["#ff8800"] * 6)
        self.assertEqual(state["devices"][0]["color"], "#ff8800")

    def test_set_color_zone(self):
        state, code = self.once({"op": "set_color", "device": 1, "zone": 1, "color": "#123456"})
        self.assertEqual(code, 0)
        self.assertEqual(self.server.devices[1]["colors"][4:], ["#123456", "#123456"])
        self.assertEqual(self.server.devices[1]["colors"][:4], ["#ff0000", "#ff0000", "#00ff00", "#00ff00"])

    def test_set_mode_specific_color(self):
        state, code = self.once({"op": "set_mode", "device": 0, "mode": 1, "color": "#00ff00"})
        self.assertEqual(code, 0)
        kb = self.server.devices[0]
        self.assertEqual(kb["activeMode"], 1)
        self.assertEqual(kb["modes"][1]["colors"], ["#00ff00"])
        self.assertEqual(state["devices"][0]["color"], "#00ff00")
        self.assertTrue(state["devices"][0]["supportsColor"])

    def test_color_on_colorless_mode_switches_to_static(self):
        state, code = self.once({"op": "set_mode", "device": 0, "mode": 2},
                                {"op": "set_color", "device": 0, "color": "#0000ff"})
        self.assertEqual(code, 0)
        kb = self.server.devices[0]
        self.assertEqual(kb["activeMode"], 1)
        self.assertEqual(kb["modes"][1]["colors"], ["#0000ff"])

    def test_brightness_and_speed_clamped(self):
        state, code = self.once({"op": "set_mode", "device": 0, "mode": 1},
                                {"op": "set_brightness", "device": 0, "value": 250},
                                {"op": "set_mode", "device": 0, "mode": 2},
                                {"op": "set_speed", "device": 0, "value": -5})
        self.assertEqual(code, 0)
        kb = self.server.devices[0]
        self.assertEqual(kb["modes"][1]["brightness"], 100)
        self.assertEqual(kb["modes"][2]["speed"], 0)

    def test_brightness_on_mode_without_it_fails(self):
        state, code = self.once({"op": "set_brightness", "device": 0, "value": 10})
        self.assertEqual(code, 1)
        self.assertFalse(state["results"][0]["ok"])
        self.assertIn("no brightness control", state["results"][0]["error"])

    def test_set_all(self):
        state, code = self.once({"op": "set_all", "color": "#abcdef"})
        self.assertEqual(code, 0)
        self.assertEqual(self.server.devices[0]["colors"], ["#abcdef"] * 6)
        self.assertEqual(self.server.devices[1]["colors"], ["#abcdef"] * 6)
        self.assertEqual([d["color"] for d in state["devices"]], ["#abcdef", "#abcdef"])

    def test_save_and_profiles(self):
        state, code = self.once({"op": "set_mode", "device": 0, "mode": 1},
                                {"op": "save", "device": 0},
                                {"op": "save_profile", "name": "Work"},
                                {"op": "load_profile", "name": "Gaming"})
        self.assertEqual(code, 0)
        self.assertEqual(self.server.saved_modes, [(0, 1)])
        self.assertEqual(self.server.saved_profiles, ["Work"])
        self.assertEqual(self.server.loaded_profiles, ["Gaming"])
        self.assertIn("Work", state["profiles"])

    def test_save_unsupported_mode_fails(self):
        state, code = self.once({"op": "save", "device": 0})
        self.assertEqual(code, 1)
        self.assertIn("cannot save", state["results"][0]["error"])

    def test_stream_mode_reconnects_and_reports(self):
        proc = subprocess.Popen([sys.executable, BRIDGE, "--port", str(self.server.port)],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            hello = json.loads(proc.stdout.readline())
            self.assertEqual(hello["event"], "hello")
            state = json.loads(proc.stdout.readline())
            self.assertEqual(state["event"], "state")
            self.assertTrue(state["connected"])
            profiles = json.loads(proc.stdout.readline())
            self.assertEqual(profiles["event"], "profiles")

            proc.stdin.write(json.dumps({"op": "set_color", "device": 0, "color": "#010203", "id": 7}) + "\n")
            proc.stdin.flush()
            state = json.loads(proc.stdout.readline())
            self.assertEqual(state["event"], "state")
            self.assertEqual(state["devices"][0]["color"], "#010203")
            result = json.loads(proc.stdout.readline())
            self.assertEqual(result, {"event": "result", "op": "set_color", "ok": True, "id": 7})

            proc.stdin.write(json.dumps({"op": "quit"}) + "\n")
            proc.stdin.flush()
            self.assertEqual(proc.wait(timeout=5), 0)
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=5)
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                stream.close()

    def test_connection_refused_is_reported(self):
        self.server.stop()
        proc = subprocess.Popen([sys.executable, BRIDGE, "--port", str(self.server.port)],
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            json.loads(proc.stdout.readline())  # hello
            state = json.loads(proc.stdout.readline())
            self.assertFalse(state["connected"])
            self.assertIn("no OpenRGB server", state["error"])
            self.assertEqual(state["devices"], [])
        finally:
            proc.kill()
            proc.wait(timeout=5)
            for stream in (proc.stdin, proc.stdout, proc.stderr):
                stream.close()


class QuietFrameTest(unittest.TestCase):
    def setUp(self):
        self.server = MockServer().start()

    def tearDown(self):
        self.server.stop()

    def test_quiet_applies_the_color_but_stays_silent(self):
        events = []
        br = bridge.Bridge("127.0.0.1", self.server.port, 4, emit=events.append)
        br.connect()
        events.clear()
        br.execute({"op": "set_all", "color": "#010203", "quiet": True})
        self.assertEqual(events, [], "a quiet frame must not publish anything")
        # A quiet frame deliberately never reads anything back, so nothing has
        # forced the server to have processed it yet. One round trip does: the
        # mock handles a connection's packets in order, so a reply to a later
        # request proves the earlier write landed.
        br.request(0, bridge.PKT_REQUEST_CONTROLLER_COUNT,
                   expect=bridge.PKT_REQUEST_CONTROLLER_COUNT)
        self.assertEqual(self.server.devices[0]["colors"], ["#010203"] * 6)
        # A failure still reports, so a broken effect cannot run silently.
        br.execute({"op": "set_color", "device": 99, "color": "#010203", "quiet": True})
        self.assertEqual([e["event"] for e in events], ["result"])
        self.assertFalse(events[0]["ok"])
        br.close()


class PollTest(unittest.TestCase):
    """The change poll is what makes the panel a mirror rather than a one-way
    remote: writes from other clients show up with no server notification."""

    def setUp(self):
        self.server = MockServer().start()
        self.events = []
        self.br = bridge.Bridge("127.0.0.1", self.server.port, 4, emit=self.events.append)
        self.br.connect()
        self.events.clear()

    def tearDown(self):
        self.br.close()
        self.server.stop()

    def states(self):
        return [e for e in self.events if e.get("event") == "state"]

    def test_external_change_is_published(self):
        with self.server.lock:
            self.server.devices[1]["colors"] = ["#123456"] * 6
        self.br.poll_devices()
        self.assertEqual(len(self.states()), 1)
        self.assertEqual(self.states()[0]["devices"][1]["color"], "#123456")

    def test_no_change_publishes_nothing(self):
        self.br.poll_devices()
        self.assertEqual(self.events, [], "an unchanged poll must stay silent")

    def test_tick_polls_when_due(self):
        with self.server.lock:
            self.server.devices[1]["colors"] = ["#654321"] * 6
        self.br.last_poll = 0.0
        self.br.last_write = 0.0
        self.br.tick()
        self.assertEqual(len(self.states()), 1)

    def test_own_writes_hold_the_poll_off(self):
        # A drag streams quiet writes; the poll must not race their read-backs.
        self.br.execute({"op": "set_color", "device": 1, "color": "#0000ff", "quiet": True})
        with self.server.lock:
            self.server.devices[1]["colors"] = ["#111111"] * 6
        self.br.last_poll = 0.0
        self.br.tick()
        self.assertEqual(self.states(), [])


class HostileServerTest(unittest.TestCase):
    """Whoever binds the port first is the server. Its headers are claims,
    not instructions: a declared size or count must not drive allocation."""

    def serve(self, handler):
        import socket, struct, threading
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)

        def run():
            conn, _ = listener.accept()
            try:
                handler(conn)
            finally:
                conn.close()
                listener.close()

        threading.Thread(target=run, daemon=True).start()
        return listener.getsockname()[1]

    @staticmethod
    def read_header(conn):
        buf = b""
        while len(buf) < bridge.HEADER.size:
            chunk = conn.recv(bridge.HEADER.size - len(buf))
            if not chunk:
                raise ConnectionError
            buf += chunk
        return bridge.HEADER.unpack(buf)

    def test_huge_packet_header_is_refused(self):
        def handler(conn):
            # Reply to the version request with a header announcing 4 GiB.
            _, dev, pkt, size = self.read_header(conn)
            conn.recv(size)
            conn.sendall(bridge.HEADER.pack(bridge.MAGIC, 0, pkt, 0xFFFFFFFF))
            # Then feed it bytes for a while: a bridge without a ceiling would
            # keep reading, and this test would hang instead of returning.
            try:
                for _ in range(64):
                    conn.sendall(b"\0" * 65536)
            except OSError:
                pass

        port = self.serve(handler)
        br = bridge.Bridge("127.0.0.1", port, 4)
        with self.assertRaises(bridge.ProtocolError) as caught:
            br.connect()
        self.assertIn("ceiling", str(caught.exception))
        self.assertFalse(br.connected)

    def test_absurd_device_count_is_refused(self):
        def handler(conn):
            import struct
            while True:
                try:
                    _, dev, pkt, size = self.read_header(conn)
                except ConnectionError:
                    return
                if size:
                    conn.recv(size)
                if pkt == bridge.PKT_REQUEST_PROTOCOL_VERSION:
                    conn.sendall(bridge.HEADER.pack(bridge.MAGIC, 0, pkt, 4) + struct.pack("<I", 4))
                elif pkt == bridge.PKT_REQUEST_CONTROLLER_COUNT:
                    conn.sendall(bridge.HEADER.pack(bridge.MAGIC, 0, pkt, 4) + struct.pack("<I", 50_000_000))

        port = self.serve(handler)
        br = bridge.Bridge("127.0.0.1", port, 4)
        with self.assertRaises(bridge.ProtocolError) as caught:
            br.connect()
        self.assertIn("ceiling", str(caught.exception))
        self.assertEqual(br.devices, [])


class CoalesceTest(unittest.TestCase):
    def test_keeps_last_slider_update_per_device(self):
        cmds = [
            {"op": "set_color", "device": 0, "color": "#000001"},
            {"op": "set_color", "device": 1, "color": "#000002"},
            {"op": "refresh"},
            {"op": "set_color", "device": 0, "color": "#000003"},
            {"op": "set_all", "color": "#000004"},
            {"op": "set_all", "color": "#000005"},
        ]
        kept = bridge.coalesce(cmds)
        self.assertEqual(kept, [cmds[1], cmds[2], cmds[3], cmds[5]])


if __name__ == "__main__":
    unittest.main()
