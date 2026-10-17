#!/usr/bin/env bash
# Notification Center with three test notifications (private bus).
source "$(dirname "$0")/../lib.sh"
vs_session
vs_reset
vs_notify
vs_sleep 2
vs_pointer abs 1850 12 sleep 300 click
vs_sleep 1
vs_capture notificationcenter
