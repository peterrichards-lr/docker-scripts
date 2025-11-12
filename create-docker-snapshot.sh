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

LIFERAY_ROOT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--root)
      shift
      if [[ -z "$1" ]]; then
        echo "Error: --root requires a path"
        exit 1
      fi
      LIFERAY_ROOT_ARG="$1"
      ;;
    -h|--help)
      echo "Usage: $0 [-r|--root PATH]"
      exit 0
      ;;
    *)
      ;;
  esac
  shift
done

if [[ -n "$LIFERAY_ROOT_ARG" ]]; then
  LIFERAY_ROOT="$LIFERAY_ROOT_ARG"
else
  default_root="$(pwd)"
  read_config "Liferay Root" LIFERAY_ROOT "$default_root"
fi
[[ ! "$LIFERAY_ROOT" =~ ^(\.\/|\/).+$ ]] && LIFERAY_ROOT="./$LIFERAY_ROOT"

DEPLOY_VOLUME="$LIFERAY_ROOT/deploy"
DATA_VOLUME="$LIFERAY_ROOT/data"
SCRIPT_VOLUME="$LIFERAY_ROOT/scripts"
FILES_VOLUME="$LIFERAY_ROOT/files"
CX_VOLUME="$LIFERAY_ROOT/osgi/client-extensions"
STATE_VOLUME="$LIFERAY_ROOT/osgi/state"
BACKUPS_DIR="$LIFERAY_ROOT/backups"

mkdir -p "$BACKUPS_DIR"

CONTAINER_NAME=$(echo "$LIFERAY_ROOT" | sed -e 's:.*/::' -e 's/[\.]/-/g')
container_running=$(docker ps --format '{{.Names}}' | grep -x "$CONTAINER_NAME" >/dev/null 2>&1 && echo "Y" || echo "N")

STOP_CONTAINER_DEFAULT=Y
read_config "Stop container during backup" STOP_CONTAINER "$STOP_CONTAINER_DEFAULT"

if [[ "${STOP_CONTAINER:u}" == "Y" && "$container_running" == "Y" ]]; then
  info_custom "${Yellow}Stopping ${Green}$CONTAINER_NAME"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
fi

timestamp=$(date +"%Y%m%d-%H%M%S")
checkpoint_dir="$BACKUPS_DIR/$timestamp"
mkdir -p "$checkpoint_dir"

read_config "Snapshot Name (optional)" SNAPSHOT_NAME ""

jdbc_url=""
jdbc_user=""
jdbc_pass=""

if [[ -f "$FILES_VOLUME/portal-ext.properties" ]]; then
  jdbc_url=$(read_db_prop "jdbc.default.url")
  jdbc_user=$(read_db_prop "jdbc.default.username")
  jdbc_pass=$(read_db_prop "jdbc.default.password")
fi

if [[ -z "$jdbc_url" ]]; then
  info "No JDBC configuration detected; creating filesystem snapshot"
  tar --exclude="$BACKUPS_DIR" -czf "$checkpoint_dir/filesystem.tar.gz" -C "$LIFERAY_ROOT" .
  printf "type=hypersonic\n" > "$checkpoint_dir/meta"
  [[ -n "$SNAPSHOT_NAME" ]] && printf "name=%s\n" "$SNAPSHOT_NAME" >> "$checkpoint_dir/meta"
else
  echo "$jdbc_url" | grep -qi "postgresql" && dbtype="postgresql"
  echo "$jdbc_url" | grep -qi "mysql" && dbtype="${dbtype:-mysql}"
  printf "type=%s\n" "$dbtype" > "$checkpoint_dir/meta"
  [[ -n "$SNAPSHOT_NAME" ]] && printf "name=%s\n" "$SNAPSHOT_NAME" >> "$checkpoint_dir/meta"

  if [[ "$dbtype" == "postgresql" ]]; then
    dbname=$(echo "$jdbc_url" | sed -E 's#^jdbc:postgresql://[^/]+/([^?]+).*#\1#')
    info "Dumping PostgreSQL database: $dbname"
    PGPASSWORD="$jdbc_pass" pg_dump -h localhost -p 5432 -U "$jdbc_user" -d "$dbname" | gzip > "$checkpoint_dir/db-postgresql.sql.gz"
  else
    dbname=$(echo "$jdbc_url" | sed -E 's#^jdbc:mysql://[^/]+/([^?]+).*#\1#')
    info "Dumping MySQL database: $dbname"
    mysqldump -h localhost -P 3306 -u "$jdbc_user" -p"$jdbc_pass" --databases "$dbname" | gzip > "$checkpoint_dir/db-mysql.sql.gz"
  fi

  info "Archiving Liferay volumes"
  tar -czf "$checkpoint_dir/files.tar.gz" -C "$LIFERAY_ROOT" files scripts osgi data deploy 2>/dev/null
fi

if [[ "${STOP_CONTAINER:u}" == "Y" && "$container_running" == "Y" ]]; then
  info_custom "${Yellow}Starting ${Green}$CONTAINER_NAME"
  docker start "$CONTAINER_NAME" >/dev/null 2>&1
fi

if [[ -n "$SNAPSHOT_NAME" ]]; then
  info_custom "${Green}Backup created:${Color_Off} $checkpoint_dir  ${BYellow}($SNAPSHOT_NAME)"
else
  info_custom "${Green}Backup created:${Color_Off} $checkpoint_dir"
fi