#!/bin/sh
# Szelessav OpenWrt 25 - Domoticz telepito (GitHub)
set -e

case "${1:-en}" in
	hu|HU) DB_LANG=HU ;;
	*) DB_LANG=EN ;;
esac

GH="https://raw.githubusercontent.com/szelessavalapitvany"
FIRMWARE="$GH/smarthome-firmware/main/OpenWrt_25"
TMPDIR_INSTALL="$(mktemp -d /tmp/smarthome.XXXXXX)"
trap 'rm -rf "$TMPDIR_INSTALL"' EXIT HUP INT TERM

log() { logger -t smarthome_add "$*"; echo "$*"; }

download() {
	dest="$1"
	url="$2"
	mkdir -p "$(dirname "$dest")"
	curl -fL --retry 3 --connect-timeout 15 -o "${dest}.download" "$url" || {
		rm -f "${dest}.download"
		log "ERROR: download failed: $url"
		exit 1
	}
	[ -s "${dest}.download" ] || { log "ERROR: empty file: $url"; exit 1; }
	mv -f "${dest}.download" "$dest"
}

# Download the repository as ZIP, without git clone and git history.
# Try main then master for repositories that use the older default branch.
repository_zip() {
	repo="$1"
	archive="$TMPDIR_INSTALL/repository.zip"
	rm -f "$archive"
	for branch in main master; do
		if curl -fsSL --retry 2 --connect-timeout 15 \
			-o "$archive" "https://github.com/szelessavalapitvany/$repo/archive/refs/heads/$branch.zip"; then
			if unzip -t "$archive" >/dev/null 2>&1; then
				printf '%s\n' "$branch"
				return 0
			fi
		fi
	done
	log "ERROR: GitHub ZIP unavailable: $repo"
	exit 1
}

extract_repo() {
	repo="$1"
	branch="$(repository_zip "$repo")"
	rm -rf "$TMPDIR_INSTALL/repo"
	mkdir -p "$TMPDIR_INSTALL/repo"
	unzip -q "$TMPDIR_INSTALL/repository.zip" -d "$TMPDIR_INSTALL/repo"
	REPO_ROOT="$TMPDIR_INSTALL/repo/$repo-$branch"
	[ -d "$REPO_ROOT" ] || { log "ERROR: ZIP layout invalid: $repo"; exit 1; }
}

log "Starting smart-home installation (database: $DB_LANG)"
apk update
apk add curl
apk add bind-host
apk add unzip
apk add domoticz
apk add git-http
apk add mosquitto-nossl
apk add luci-app-mosquitto

log "Installing Domoticz Light/Dark themes"
mkdir -p /usr/share/domoticz/www/styles
extract_repo "Domoticz-Szelessav-Themes"
for theme in szelessav_dark szelessav_light; do
	[ -d "$REPO_ROOT/$theme" ] || { log "ERROR: missing theme: $theme"; exit 1; }
	cp -R "$REPO_ROOT/$theme" /usr/share/domoticz/www/styles/
done

download /usr/share/domoticz/www/favicon.ico "$FIRMWARE/favicon.ico"

log "Installing Domoticz plugins and viewers"
mkdir -p /etc/domoticz/plugins /usr/share/domoticz/www/templates

install_plugin() {
	plugin="$1"
	repo="$2"
	extract_repo "$repo"
	dest="/etc/domoticz/plugins/$plugin"
	mkdir -p "$dest"
	# Includes plugin.py, translations, support files and subfolders.
	cp -R "$REPO_ROOT/." "$dest/"
	# The viewer needs to be visible in Domoticz www/templates.
	if [ -d "$REPO_ROOT/viewer" ]; then
		find "$REPO_ROOT/viewer" -maxdepth 1 -type f -exec cp -f {} /usr/share/domoticz/www/templates/ \;
	fi
	[ -f "$dest/plugin.py" ] || { log "ERROR: plugin.py missing in $repo"; exit 1; }
	log "Installed $plugin"
}

install_plugin ADA_P1_meter ADA_P1_meter_for_Domoticz
install_plugin ASC_Shutter_Redony Domoticz-ASC-Shutter-Controller
install_plugin Automatic_watering Domoticz-Automatic-Watering-System
install_plugin EV_Charge_Control EV_Charge_Control
install_plugin DSVT_HMV_ZONE_12 Domoticz-DSVT
install_plugin HomeWizard-Wifi-p1-plugin-Extended HomeWizard-Wifi-p1-plugin-Extended
install_plugin IR_climate_controller domoticz-ir-climate-controller
install_plugin JelenletKapcsolo Domoticz-JEK-Presence-Switch
install_plugin NapkollektorVezerlo Domoticz-Solar-Collector

log "Configuring Domoticz"
# Az init/config csere leallitas utan tortenik, nehogy a futo szolgaltatasra hasson.
/etc/init.d/domoticz stop 2>/dev/null || true

download "$TMPDIR_INSTALL/domoticz.config" "$FIRMWARE/config/domoticz"
download "$TMPDIR_INSTALL/domoticz.init" "$FIRMWARE/init.d/domoticz"
# Minimalis ellenorzes, nehogy HTML hibaoldalt telepitsunk.
grep -q 'config ' "$TMPDIR_INSTALL/domoticz.config" || { log "ERROR: invalid Domoticz config"; exit 1; }
grep -q '^#!/' "$TMPDIR_INSTALL/domoticz.init" || { log "ERROR: invalid Domoticz init"; exit 1; }
cp -f "$TMPDIR_INSTALL/domoticz.config" /etc/config/domoticz
cp -f "$TMPDIR_INSTALL/domoticz.init" /etc/init.d/domoticz
chmod 755 /etc/init.d/domoticz
rm -f /etc/init.d/domoticz.apk-new
# A rendszerben a Domoticz root-kent fut a /lib/domoticz irasi joga miatt.
sed -i 's/user "domoticz"/user "root"/g' /etc/init.d/domoticz
sed -i 's/\/var\/lib/\/lib/g' /etc/config/domoticz
sed -i 's/\/var\/lib/\/lib/g' /etc/init.d/domoticz
uci set 'domoticz.@domoticz[0].userdata=/lib/domoticz/'
uci commit domoticz

log "Configuring Mosquitto"
MOSQ=/etc/mosquitto/mosquitto.conf
[ -f "$MOSQ" ] || touch "$MOSQ"
grep -Eq '^[[:space:]]*user[[:space:]]+root[[:space:]]*$' "$MOSQ" || printf '\nuser root\n' >> "$MOSQ"
# Ne legyen duplikalt vagy ertek nelkuli allow_anonymous sor.
sed -i '/^[[:space:]]*allow_anonymous[[:space:]]*$/d' "$MOSQ"
grep -Eq '^[[:space:]]*allow_anonymous[[:space:]]+true[[:space:]]*$' "$MOSQ" || printf 'allow_anonymous true\n' >> "$MOSQ"
uci set mosquitto.owrt.use_uci='1'
uci set mosquitto.mosquitto.log_dest='syslog'
uci set mosquitto.mosquitto.allow_anonymous='true'
uci set mosquitto.mosquitto.port='1883'
uci commit mosquitto

log "Installing Domoticz data and database"
mkdir -p /lib/domoticz

download /lib/domoticz/MemoryLogging.sh "$FIRMWARE/MemoryLogging.sh"
chmod 755 /lib/domoticz/MemoryLogging.sh

# Root crontab: megorzi a mar meglevo sorokat, az ujakat csak egyszer adja hozza.
download "$TMPDIR_INSTALL/root.cron" "$FIRMWARE/crontabs/root"
mkdir -p /etc/crontabs
touch /etc/crontabs/root
while IFS= read -r cron_line || [ -n "$cron_line" ]; do
    case "$cron_line" in ''|'#'*) continue ;; esac
    grep -Fqx -- "$cron_line" /etc/crontabs/root || printf '%s\n' "$cron_line" >> /etc/crontabs/root
done < "$TMPDIR_INSTALL/root.cron"
/etc/init.d/cron restart

# A teljes alapadatbazist telepiti. Meglevo DB-rol mentest keszit.
download "$TMPDIR_INSTALL/domoticz.db" "$FIRMWARE/Database_${DB_LANG}/domoticz.db"
[ "$(head -c 16 "$TMPDIR_INSTALL/domoticz.db")" = "SQLite format 3" ] || {
	log "ERROR: invalid SQLite database"; exit 1;
}
if [ -f /lib/domoticz/domoticz.db ]; then
	cp -p /lib/domoticz/domoticz.db /lib/domoticz/domoticz.db.before-install.bak
fi
cp -f "$TMPDIR_INSTALL/domoticz.db" /lib/domoticz/domoticz.db
rm -f /lib/domoticz/domoticz.db-wal /lib/domoticz/domoticz.db-shm

log "Enabling and starting services"
/etc/init.d/mosquitto enable
/etc/init.d/domoticz enable
/etc/init.d/mosquitto restart
/etc/init.d/domoticz start

# Nem nyitjuk ki a Domoticz HTTP-portjat a WAN fele.
# A LAN iranyabol az alapertelmezett router firewall mukodes engedi az elerest.
# Korabbi, e telepito altal letrehozott WAN szabaly eltavolitasa.
if uci -q get firewall.domoticz >/dev/null 2>&1; then
    uci -q delete firewall.domoticz
    uci commit firewall
    /etc/init.d/firewall restart
fi

log "Refreshing LuCI"
rm -rf /tmp/luci-*
/etc/init.d/uhttpd restart
log "Installation finished"
