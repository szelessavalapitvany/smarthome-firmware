#!/bin/sh

# Beállítások
MEM_LIMIT=50
DISK_LIMIT_KB=1024
RESTART_INTERVAL=1800
RESTART_STAMP=/tmp/domoticz_monitor_restart

restart_domoticz() {
    REASON="$1"
    NOW=$(date +%s)
    LAST=$(cat "$RESTART_STAMP" 2>/dev/null)

    case "$LAST" in
        ''|*[!0-9]*) LAST=0 ;;
    esac

    if [ $((NOW - LAST)) -lt "$RESTART_INTERVAL" ]; then
        echo "Újraindítás tiltva (30 perces védelem): $REASON"
        return 1
    fi

    echo "Domoticz újraindítás: $REASON"
    echo "$NOW" > "$RESTART_STAMP"

    /etc/init.d/domoticz restart
    return 0
}

# Domoticz PID
PID=$(pidof domoticz)

if [ -z "$PID" ]; then
    echo "Domoticz processz nem található."
    restart_domoticz "Domoticz nem fut"
    exit 1
fi

# Memóriaadatok
TOTAL_KB=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
AVAILABLE_KB=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo)

DOMOTICZ_KB=$(awk '/VmRSS:/ {print $2}' "/proc/$PID/status")

if [ -z "$DOMOTICZ_KB" ] || [ -z "$TOTAL_KB" ] || [ "$TOTAL_KB" -eq 0 ]; then
    echo "Memóriaadatok nem olvashatók."
    exit 1
fi

DOMOTICZMEM=$((DOMOTICZ_KB * 100 / TOTAL_KB))
MEMUSG=$(( (TOTAL_KB - AVAILABLE_KB) * 100 / TOTAL_KB ))

echo "Domoticz memóriahasználat: ${DOMOTICZMEM}% (${DOMOTICZ_KB} KiB)"
echo "Rendszer memóriahasználat: ${MEMUSG}%"

# Szabad overlay tárhely KiB-ban
DISKFREE_KB=$(df -k /overlay | awk 'NR==2 {print $4}')

# Domoticz kijelzés MiB-ban
DISKFREE=$(awk -v kb="$DISKFREE_KB" 'BEGIN {printf "%.1f", kb/1024}')

echo "Szabad tárhely: ${DISKFREE} MiB (${DISKFREE_KB} KiB)"

# Domoticz eszközök frissítése
curl --max-time 5 -s \
    "http://127.0.0.1:8080/json.htm?type=command&param=udevice&idx=1&nvalue=0&svalue=$DOMOTICZMEM" \
    >/dev/null 2>&1

curl --max-time 5 -s \
    "http://127.0.0.1:8080/json.htm?type=command&param=udevice&idx=2&nvalue=0&svalue=$MEMUSG" \
    >/dev/null 2>&1

curl --max-time 5 -s \
    "http://127.0.0.1:8080/json.htm?type=command&param=udevice&idx=3&nvalue=0&svalue=$DISKFREE" \
    >/dev/null 2>&1

# Újraindítási feltételek
if [ "$DOMOTICZMEM" -gt "$MEM_LIMIT" ]; then
    restart_domoticz "Magas memóriahasználat: ${DOMOTICZMEM}%"
    exit 1
fi

if [ "$DISKFREE_KB" -lt "$DISK_LIMIT_KB" ]; then
    restart_domoticz "Kevés szabad tárhely: ${DISKFREE} MiB"
    exit 1
fi

echo "Domoticz működik, memória és tárhely rendben."

exit 0