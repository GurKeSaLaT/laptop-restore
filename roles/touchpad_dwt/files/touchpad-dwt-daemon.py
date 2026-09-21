#!/usr/bin/env python3
"""
touchpad-dwt-daemon: custom "disable touchpad while typing".

Unlike libinput's built-in disable_while_typing (which keeps the touchpad
disabled for as long as ANY key is physically held down, plus a short
cooldown after release), this daemon only resets its lock on a genuine new
keydown. Autorepeat events from a held key do not extend the lock, so the
touchpad re-enables after TIMEOUT_SECONDS even while the key is still down.

It works below the compositor via EVIOCGRAB (exclusive device grab), so it
is independent of Hyprland/libinput's own config and needs no IPC calls.
Because of that, this daemon and libinput's own disable_while_typing would
otherwise both try to control the touchpad -- disable_while_typing should
be turned off in the compositor config before running this permanently.
"""

import fcntl
import os
import selectors
import signal
import sys
import time

import libevdev
import pyudev

TIMEOUT_SECONDS = 0.5

running = True


def handle_signal(signum, frame):
    global running
    running = False


def log(msg: str) -> None:
    print(msg, flush=True)


def find_keyboard(context: pyudev.Context) -> str | None:
    """Real physical keyboard: ID_INPUT_KEYBOARD=1, has a letter key (to
    exclude power/lid/hotkey-only devices), and has a physical bus path (to
    exclude virtual/uinput devices, e.g. ydotool's synthetic keyboard)."""
    for dev in context.list_devices(subsystem="input"):
        if dev.get("ID_INPUT_KEYBOARD") != "1" or dev.get("ID_PATH") is None:
            continue
        node = dev.device_node
        if not node or "/event" not in node:
            continue
        try:
            with open(node, "rb") as f:
                if libevdev.Device(f).has(libevdev.EV_KEY.KEY_A):
                    return node
        except OSError:
            continue
    return None


def find_touchpad(context: pyudev.Context) -> str | None:
    for dev in context.list_devices(subsystem="input"):
        if dev.get("ID_INPUT_TOUCHPAD") == "1" and dev.device_node and "/event" in dev.device_node:
            return dev.device_node
    return None


def main() -> int:
    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    context = pyudev.Context()
    keyboard_path = find_keyboard(context)
    touchpad_path = find_touchpad(context)
    if not keyboard_path or not touchpad_path:
        log(f"could not find devices (keyboard={keyboard_path}, touchpad={touchpad_path})")
        return 1

    try:
        kbd_file = open(keyboard_path, "rb")
        touchpad_file = open(touchpad_path, "rb")
    except OSError as e:
        log(f"failed to open input device: {e}")
        return 1

    fcntl.fcntl(kbd_file, fcntl.F_SETFL, os.O_NONBLOCK)

    keyboard = libevdev.Device(kbd_file)
    touchpad = libevdev.Device(touchpad_file)

    log(f"keyboard: {keyboard.name} ({keyboard_path})")
    log(f"touchpad: {touchpad.name} ({touchpad_path})")

    selector = selectors.DefaultSelector()
    selector.register(kbd_file, selectors.EVENT_READ)

    grabbed = False
    deadline = 0.0

    try:
        while running:
            timeout = None
            if grabbed:
                timeout = max(0.0, deadline - time.monotonic())

            events = selector.select(timeout)

            if not running:
                break

            if not events:
                # Timeout expired with no new keydown since the last one.
                touchpad.ungrab()
                grabbed = False
                log("touchpad released (timeout, no new keypress)")
                continue

            try:
                for ev in keyboard.events():
                    if not ev.matches(libevdev.EV_KEY):
                        continue
                    if ev.value != 1:  # ignore release (0) and autorepeat (2)
                        continue

                    if not grabbed:
                        touchpad.grab()
                        grabbed = True
                        log("touchpad grabbed (keypress)")
                    deadline = time.monotonic() + TIMEOUT_SECONDS
            except libevdev.EventsDroppedException:
                # We missed some events (e.g. buffer overrun); re-sync and
                # keep the current lock state rather than crash.
                for _ in keyboard.events():
                    pass
    finally:
        if grabbed:
            touchpad.ungrab()
        kbd_file.close()
        touchpad_file.close()
        log("daemon stopped, touchpad released")

    return 0


if __name__ == "__main__":
    sys.exit(main())
