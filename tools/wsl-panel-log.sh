#!/bin/bash
set -u
tail -30 /tmp/shui-panel-rebuild.log 2>/dev/null || echo "(no log)"
