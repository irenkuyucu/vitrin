#!/usr/bin/env python3
"""Tiny zwlr_virtual_pointer client (raw Wayland wire protocol, no libraries).

Usage: vptr.py W H  move X Y
       vptr.py W H  click X Y [button]
       vptr.py W H  drag X1 Y1 X2 Y2 [hold_ms_at_end [X3 Y3]]   (press, move in steps, hold, release)
W H is the logical size of the output the coordinates refer to.
"""
import os, socket, struct, sys, time

BTN = {"left": 0x110, "right": 0x111, "middle": 0x112}


class Wl:
    def __init__(self):
        path = os.path.join(os.environ["XDG_RUNTIME_DIR"], os.environ.get("WAYLAND_DISPLAY", "wayland-1"))
        self.s = socket.socket(socket.AF_UNIX); self.s.connect(path)
        self.next_id = 2
        self.buf = b""

    def new_id(self):
        i = self.next_id; self.next_id += 1; return i

    def send(self, obj, op, payload=b""):
        self.s.sendall(struct.pack("<II", obj, ((8 + len(payload)) << 16) | op) + payload)

    @staticmethod
    def string(s):
        b = s.encode() + b"\0"
        return struct.pack("<I", len(b)) + b + b"\0" * (-len(b) % 4)

    def events(self, until):
        """Read events until until(obj, op, data) returns a value."""
        while True:
            while len(self.buf) >= 8:
                obj, w = struct.unpack("<II", self.buf[:8]); size, op = w >> 16, w & 0xFFFF
                if len(self.buf) < size: break
                data, self.buf = self.buf[8:size], self.buf[size:]
                r = until(obj, op, data)
                if r is not None: return r
            chunk = self.s.recv(65536)
            if not chunk: raise SystemExit("compositor closed the connection")
            self.buf += chunk

    def roundtrip(self):
        cb = self.new_id()
        self.send(1, 0, struct.pack("<I", cb))
        self.events(lambda o, op, d: True if (o == cb and op == 0) else None)


def connect():
    wl = Wl()
    reg = wl.new_id()
    wl.send(1, 1, struct.pack("<I", reg))
    globals_ = {}

    def collect(o, op, d):
        if o == reg and op == 0:
            name, n = struct.unpack("<II", d[:8]); iface = d[8:8 + n - 1].decode()
            version = struct.unpack("<I", d[8 + n + (-n % 4):][:4])[0]
            globals_[iface] = (name, version)
        return None

    cb = wl.new_id(); wl.send(1, 0, struct.pack("<I", cb))
    wl.events(lambda o, op, d: True if (o == cb and op == 0) else collect(o, op, d))
    name, version = globals_["zwlr_virtual_pointer_manager_v1"]
    mgr = wl.new_id()
    wl.send(reg, 0, struct.pack("<I", name) + wl.string("zwlr_virtual_pointer_manager_v1") + struct.pack("<II", min(version, 2), mgr))
    ptr = wl.new_id()
    wl.send(mgr, 0, struct.pack("<II", 0, ptr))      # create_virtual_pointer(seat=null)
    return wl, ptr


def now_ms():
    return int(time.monotonic() * 1000) & 0xFFFFFFFF


def main():
    W, H, cmd = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
    a = sys.argv[4:]
    wl, ptr = connect()

    def move(x, y):
        wl.send(ptr, 1, struct.pack("<IIIII", now_ms(), int(x), int(y), W, H)); wl.send(ptr, 4)

    def button(code, down):
        wl.send(ptr, 2, struct.pack("<III", now_ms(), code, 1 if down else 0)); wl.send(ptr, 4)

    if cmd == "move":
        move(a[0], a[1])
    elif cmd == "click":
        move(a[0], a[1]); time.sleep(0.05)
        b = BTN[a[2]] if len(a) > 2 else BTN["left"]
        button(b, True); time.sleep(0.05); button(b, False)
    elif cmd == "drag":
        x1, y1, x2, y2 = map(float, a[:4]); hold = int(a[4]) if len(a) > 4 else 0
        move(x1, y1); time.sleep(0.1); button(BTN["left"], True); time.sleep(0.15)
        steps = 30
        for i in range(1, steps + 1):
            move(x1 + (x2 - x1) * i / steps, y1 + (y2 - y1) * i / steps); time.sleep(0.02)
        time.sleep(hold / 1000)
        if len(a) > 6:      # slide away to a harmless spot before letting go (no drop on the target)
            x3, y3 = float(a[5]), float(a[6])
            for i in range(1, 11):
                move(x2 + (x3 - x2) * i / 10, y2 + (y3 - y2) * i / 10); time.sleep(0.02)
        button(BTN["left"], False)
    wl.roundtrip()


main()
