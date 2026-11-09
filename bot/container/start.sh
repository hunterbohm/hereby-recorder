#!/bin/sh
set -e
export XDG_RUNTIME_DIR=/tmp/runtime
mkdir -p -m 700 $XDG_RUNTIME_DIR
Xvfb :99 -screen 0 1280x720x24 -nolisten tcp >/tmp/xvfb.log 2>&1 &
pulseaudio --daemonize=yes --exit-idle-time=-1 --log-target=file:/tmp/pulse.log
# Pulse pauses a sink nobody plays into, which would pause the recording during quiet stretches too.
pactl unload-module module-suspend-on-idle 2>/dev/null || true
pactl load-module module-null-sink sink_name=meet sink_properties=device.description=meet >/dev/null
pactl load-module module-null-sink sink_name=mic sink_properties=device.description=mic >/dev/null
pactl set-default-sink meet
pactl load-module module-remap-source master=mic.monitor source_name=micin source_properties=device.description=micin >/dev/null
pactl set-default-source micin
exec node /app/driver.mjs
