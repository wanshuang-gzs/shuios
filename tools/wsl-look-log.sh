#!/bin/bash
set -u
echo "--- /tmp/stop.log ---"
cat /tmp/stop.log 2>&1 | head -20
echo "--- /tmp/stop-done.log ---"
cat /tmp/stop-done.log 2>&1 | head -5
echo "--- ps ---"
ps -o pid,comm -C ssh,sshpass 2>/dev/null | head -5
