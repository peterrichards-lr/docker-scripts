#!/bin/zsh

Color_Off='\033[0m'
Green='\033[0;32m'
Yellow='\033[0;33m'
White='\033[0;37m'
BYellow='\033[1;33m'

info() { [[ -n $* ]] && echo -e "${Yellow}$1${Color_Off}"; }
info_custom() { [[ -n $* ]] && echo -e "$1${Color_Off}"; }
read_config() { if [[ -n $* ]]; then local ANSWER; echo -n -e "${White}$1 [${Green}$3${White}]: ${Color_Off}"; read -r ANSWER; eval "$2=${ANSWER:-$3}"; fi }

read_db_prop() { grep -E "^$1=" "$FILES_VOLUME/portal-ext.properties" | sed -e "s/^$1=//"; }

default_root="$(pwd)"
read_config "Liferay Root" LIFERAY_ROOT "$default_root"
[[ ! "$LIFERAY_ROOT" =~ ^(\.\/|\/).+$ ]] && LIFERAY_ROOT="./$LIFERAY_ROOT"

DEPLOY_VOLUME="$LIFERAY_ROOT/deploy"
DATA_VOLUME="$LIFERAY_ROOT/data"
SCRIPT_VOLUME="$LIFERAY_ROOT/scripts"
FILES_VOLUME="$LIFERAY_ROOT/files"
CX_VOLUME="$LIFERAY_ROOT/osgi/client-extensions"
STATE_VOLUME="$LIFERAY_ROOT/osgi/state"
BACKUPS_DIR="$LIFERAY_ROOT/backups"

CHECKPOINTS=()
if [[ -d "$BACKUPS_DIR" ]]; then
  IFS=$'\n' CHECKPOINTS=($(ls -1 "$BACKUPS_DIR" 2>/dev/null | sort -r))
  unset IFS
fi
latest_checkpoint="${CHECKPOINTS[1]}"

if [[ ${#CHECKPOINTS[@]} -eq 0 ]]; then
  info_custom "${Yellow}No backups found in:${Color_Off} $BACKUPS_DIR"
  exit 1
fi

read_config "Show list of available backups (Y/N)" SHOW_LIST "Y"
if [[ "${SHOW_LIST:u}" == "Y" ]]; then
  info_custom "${Yellow}Available backups for${Color_Off} $LIFERAY_ROOT/backups"
  idx=1
  for folder in "${CHECKPOINTS[@]}"; do
    name_line=$(sed -n 's/^name=//p' "$BACKUPS_DIR/$folder/meta" 2>/dev/null | head -n1)
    display_name=${name_line:-"(unnamed)"}
    echo "  [$idx] $display_name — $folder"
    idx=$((idx+1))
  done
fi

read_config "Select backup by number or enter folder name" CHECKPOINT_INPUT "$latest_checkpoint"

if [[ "$CHECKPOINT_INPUT" =~ ^[0-9]+$ ]]; then
  sel=$((CHECKPOINT_INPUT))
  if (( sel < 1 || sel > ${#CHECKPOINTS[@]} )); then
    info_custom "${Yellow}Invalid selection:${Color_Off} $CHECKPOINT_INPUT"
    exit 1
  fi
  CHECKPOINT="${CHECKPOINTS[$sel]}"
else
  CHECKPOINT="$CHECKPOINT_INPUT"
fi

CHECKPOINT_DIR="$BACKUPS_DIR/$CHECKPOINT"

if [[ ! -d "$CHECKPOINT_DIR" ]]; then
  info_custom "${Yellow}Checkpoint not found:${Color_Off} $CHECKPOINT_DIR"
  exit 1
fi

CONTAINER_NAME=$(echo "$LIFERAY_ROOT" | sed -e 's:.*/::' -e 's/[\.]/-/g')
container_exists=$(docker ps -a --format '{{.Names}}' | grep -x "$CONTAINER_NAME" >/dev/null 2>&1 && echo "Y" || echo "N")
container_running=$(docker ps --format '{{.Names}}' | grep -x "$CONTAINER_NAME" >/dev/null 2>&1 && echo "Y" || echo "N")

if [[ "$container_running" == "Y" ]]; then
  info_custom "${Yellow}Stopping ${Green}$CONTAINER_NAME"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
fi

type_line=$(cat "$CHECKPOINT_DIR/meta" 2>/dev/null | head -n1)
snapshot_type=$(echo "$type_line" | sed -E 's/^type=//')

if [[ "$snapshot_type" == "hypersonic" ]]; then
  archive="$CHECKPOINT_DIR/filesystem.tar.gz"
  if [[ -f "$archive" ]]; then
    find "$LIFERAY_ROOT" -mindepth 1 -maxdepth 1 ! -name "backups" -exec rm -rf {} +
    tar -xzf "$archive" -C "$LIFERAY_ROOT"
  else
    info "Missing filesystem archive"
    exit 1
  fi
else
  jdbc_url=$(read_db_prop "jdbc.default.url")
  jdbc_user=$(read_db_prop "jdbc.default.username")
  jdbc_pass=$(read_db_prop "jdbc.default.password")

  if echo "$snapshot_type" | grep -qi "postgresql"; then
    dbname=$(echo "$jdbc_url" | sed -E 's#^jdbc:postgresql://[^/]+/([^?]+).*#\1#')
    pghost=$(echo "$jdbc_url" | sed -E 's#^jdbc:postgresql://([^/:?]+).*$#\1#')
    pgport=$(echo "$jdbc_url" | sed -nE 's#^jdbc:postgresql://[^/:?]+:([0-9]+).*$#\1#p')
    [[ "$pghost" == "host.docker.internal" ]] && pghost="localhost"
    [[ -z "$pghost" || "$pghost" == "$jdbc_url" ]] && pghost="localhost"
    [[ -z "$pgport" ]] && pgport=5432

    info_custom "${Yellow}Resetting PostgreSQL database:${Color_Off} $dbname"
    PGPASSWORD="$jdbc_pass" psql -h "$pghost" -p "$pgport" -U "$jdbc_user" -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$dbname' AND pid <> pg_backend_pid();" >/dev/null 2>&1
    PGPASSWORD="$jdbc_pass" psql -h "$pghost" -p "$pgport" -U "$jdbc_user" -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$dbname\";" >/dev/null
    PGPASSWORD="$jdbc_pass" psql -h "$pghost" -p "$pgport" -U "$jdbc_user" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$dbname\" WITH TEMPLATE template0 ENCODING 'UTF8';" >/dev/null

    info_custom "${Yellow}Importing PostgreSQL dump into:${Color_Off} $dbname"
    gunzip -c "$CHECKPOINT_DIR/db-postgresql.sql.gz" | PGPASSWORD="$jdbc_pass" psql -h "$pghost" -p "$pgport" -U "$jdbc_user" -d "$dbname" >/dev/null
  else
    dbname=$(echo "$jdbc_url" | sed -E 's#^jdbc:mysql://[^/]+/([^?]+).*#\1#')
    myhost=$(echo "$jdbc_url" | sed -E 's#^jdbc:mysql://([^/:?]+).*$#\1#')
    myport=$(echo "$jdbc_url" | sed -nE 's#^jdbc:mysql://[^/:?]+:([0-9]+).*$#\1#p')
    [[ "$myhost" == "host.docker.internal" ]] && myhost="localhost"
    [[ -z "$myhost" || "$myhost" == "$jdbc_url" ]] && myhost="localhost"
    [[ -z "$myport" ]] && myport=3306

    mysql -h "$myhost" -P "$myport" -u "$jdbc_user" -p"$jdbc_pass" -e "DROP DATABASE IF EXISTS \`$dbname\`; CREATE DATABASE \`$dbname\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null
    gunzip -c "$CHECKPOINT_DIR/db-mysql.sql.gz" | mysql -h "$myhost" -P "$myport" -u "$jdbc_user" -p"$jdbc_pass" >/dev/null
  fi

  if [[ -f "$CHECKPOINT_DIR/files.tar.gz" ]]; then
    tar -xzf "$CHECKPOINT_DIR/files.tar.gz" -C "$LIFERAY_ROOT"
  fi
fi

DELETE_CHECKPOINT_DEFAULT=N
read_config "Delete checkpoint after install" DELETE_CHECKPOINT "$DELETE_CHECKPOINT_DEFAULT"

if [[ "${DELETE_CHECKPOINT:u}" == "Y" ]]; then
  rm -rf "$CHECKPOINT_DIR"
  info_custom "${Yellow}Deleted checkpoint:${Color_Off} $CHECKPOINT"
fi

if [[ "$container_exists" == "Y" ]]; then
  info_custom "${Yellow}Starting ${Green}$CONTAINER_NAME"
  docker start "$CONTAINER_NAME" >/dev/null 2>&1
fi

info_custom "${Green}Restore complete${Color_Off}"