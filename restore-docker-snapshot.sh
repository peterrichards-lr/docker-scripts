#!/bin/zsh

Color_Off='\033[0m'
Green='\033[0;32m'
Yellow='\033[0;33m'
White='\033[0;37m'
BYellow='\033[1;33m'
Red='\033[0;31m'
BRed='\033[1;31m'

info() { [[ -n $* && "$QUIET" != 1 ]] && echo -e "${Yellow}$1${Color_Off}"; }
info_custom() { [[ -n $* && "$QUIET" != 1 ]] && echo -e "$1${Color_Off}"; }
error() { echo -e "${BRed}Error:${Color_Off} $*" 1>&2; }
_die() { error "$*"; exit 1; }
read_config() {
  if [[ "$NON_INTERACTIVE" == 1 ]]; then
    eval "$2=$3"
    return
  fi
  if [[ -n $* ]]; then
    local ANSWER
    echo -n -e "${White}$1 [${Green}$3${White}]: ${Color_Off}"
    read -r ANSWER
    eval "$2=${ANSWER:-$3}"
  fi
}
read_db_prop() { grep -E "^$1=" "$FILES_VOLUME/portal-ext.properties" | sed -e "s/^$1=//"; }

LIFERAY_ROOT_ARG=""
BACKUPS_DIR_OVERRIDE=""
CONTAINER_NAME_OVERRIDE=""
NON_INTERACTIVE=0
QUIET=0
VERBOSE=0
INDEX_ARG=""
CHECKPOINT_ARG=""
NO_LIST=0
STOP_FLAG=""
NO_STOP_FLAG=""
PG_HOST_OVERRIDE=""
PG_PORT_OVERRIDE=""
MY_HOST_OVERRIDE=""
MY_PORT_OVERRIDE=""
DELETE_AFTER_FLAG=""
KEEP_CHECKPOINT_FLAG=""
FORMAT_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--root)
      shift; [[ -z "$1" ]] && _die "--root requires a path"; LIFERAY_ROOT_ARG="$1" ;;
    -b|--backups-dir)
      shift; [[ -z "$1" ]] && _die "--backups-dir requires a path"; BACKUPS_DIR_OVERRIDE="$1" ;;
    -c|--container)
      shift; [[ -z "$1" ]] && _die "--container requires a name"; CONTAINER_NAME_OVERRIDE="$1" ;;
    --non-interactive)
      NON_INTERACTIVE=1 ;;
    -i|--index)
      shift; [[ -z "$1" || "$1" != <-> ]] && _die "--index requires a numeric value"; INDEX_ARG="$1" ;;
    --checkpoint)
      shift; [[ -z "$1" ]] && _die "--checkpoint requires a folder name"; CHECKPOINT_ARG="$1" ;;
    --no-list)
      NO_LIST=1 ;;
    -s|--stop)
      STOP_FLAG=1 ;;
    --no-stop)
      NO_STOP_FLAG=1 ;;
    --pg-host)
      shift; [[ -z "$1" ]] && _die "--pg-host requires a value"; PG_HOST_OVERRIDE="$1" ;;
    --pg-port)
      shift; [[ -z "$1" ]] && _die "--pg-port requires a value"; PG_PORT_OVERRIDE="$1" ;;
    --my-host)
      shift; [[ -z "$1" ]] && _die "--my-host requires a value"; MY_HOST_OVERRIDE="$1" ;;
    --my-port)
      shift; [[ -z "$1" ]] && _die "--my-port requires a value"; MY_PORT_OVERRIDE="$1" ;;
    --delete-after)
      DELETE_AFTER_FLAG=1 ;;
    --keep-checkpoint)
      KEEP_CHECKPOINT_FLAG=1 ;;
    --format)
      shift; [[ -z "$1" ]] && _die "--format requires standard|liferay-cloud"; case "$1" in standard|liferay-cloud) FORMAT_OVERRIDE="$1" ;; *) _die "--format must be standard|liferay-cloud";; esac ;;
    --quiet)
      QUIET=1 ;;
    --verbose)
      VERBOSE=1 ;;
    -h|--help)
      echo "Usage: $0 [options]";
      echo "";
      echo "Core paths and container:";
      echo "  -r, --root <path>             Project root. Default: current directory (interactive prompt if not provided).";
      echo "  -b, --backups-dir <path>      Backups directory. Default: <root>/backups";
      echo "  -c, --container <name>        Override container name. Default: basename(<root>) with dots replaced by dashes";
      echo "";
      echo "Selection of backup to restore (newest-first order):";
      echo "  -i, --index <N>               Select backup by numeric index (1 = newest)";
      echo "      --checkpoint <folder>     Select backup by exact folder name";
      echo "      --no-list                 Suppress listing of backups (listing is auto-suppressed in non-interactive mode)";
      echo "";
      echo "Runtime behavior:";
      echo "  -s, --stop / --no-stop       Stop container during restore (and restart afterwards if it was running). Default: stop";
      echo "      --delete-after            Delete checkpoint after successful restore";
      echo "      --keep-checkpoint         Keep checkpoint after restore. Default: keep";
      echo "      --non-interactive         Do not prompt; use defaults. In this mode:";
      echo "                                • root defaults to current directory";
      echo "                                • backup selection defaults to newest backup unless --index/--checkpoint is provided";
      echo "                                • container is stopped by default (unless --no-stop is provided)";
      echo "                                • checkpoint is kept by default (unless --delete-after is provided)";
      echo "                                • backup list is not shown";
      echo "      --format <standard|liferay-cloud>  Override auto-detected backup layout. Default: auto-detect";
      echo "";
      echo "Database connection overrides (if restoring DB):";
      echo "      --pg-host/--pg-port       Override PostgreSQL host/port. Defaults: parsed from JDBC URL; host.docker.internal -> localhost; port 5432 if missing";
      echo "      --my-host/--my-port       Override MySQL host/port. Defaults: parsed from JDBC URL; host.docker.internal -> localhost; port 3306 if missing";
      echo "";
      echo "Logging:";
      echo "      --quiet | --verbose       Adjust logging verbosity. Default: normal";
      exit 0 ;;
    *) _die "Unknown option: $1" ;;
  esac
  shift
done

[[ $VERBOSE -eq 1 ]] && set -x

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
BACKUPS_DIR="${BACKUPS_DIR_OVERRIDE:-$LIFERAY_ROOT/backups}"

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

if [[ -n "$CHECKPOINT_ARG" ]]; then
  CHECKPOINT="$CHECKPOINT_ARG"
elif [[ -n "$INDEX_ARG" ]]; then
  sel=$((INDEX_ARG))
  if (( sel < 1 || sel > ${#CHECKPOINTS[@]} )); then
    _die "Invalid --index: $INDEX_ARG"
  fi
  CHECKPOINT="${CHECKPOINTS[$sel]}"
else
  if [[ $NO_LIST -eq 0 ]]; then
    info_custom "${Yellow}Available backups for${Color_Off} $BACKUPS_DIR"
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
      _die "Invalid selection: $CHECKPOINT_INPUT"
    fi
    CHECKPOINT="${CHECKPOINTS[$sel]}"
  else
    CHECKPOINT="$CHECKPOINT_INPUT"
  fi
fi

CHECKPOINT_DIR="$BACKUPS_DIR/$CHECKPOINT"
[[ ! -d "$CHECKPOINT_DIR" ]] && _die "Checkpoint not found: $CHECKPOINT_DIR"

if [[ -n "$CONTAINER_NAME_OVERRIDE" ]]; then
  CONTAINER_NAME="$CONTAINER_NAME_OVERRIDE"
else
  CONTAINER_NAME=$(echo "$LIFERAY_ROOT" | sed -e 's:.*/::' -e 's/[\.]/-/g')
fi
container_exists=$(docker ps -a --format '{{.Names}}' | grep -x "$CONTAINER_NAME" >/dev/null 2>&1 && echo "Y" || echo "N")
container_running=$(docker ps --format '{{.Names}}' | grep -x "$CONTAINER_NAME" >/dev/null 2>&1 && echo "Y" || echo "N")

STOP_CONTAINER_DEFAULT=Y
if [[ -n "$STOP_FLAG" ]]; then
  STOP_CONTAINER=Y
elif [[ -n "$NO_STOP_FLAG" ]]; then
  STOP_CONTAINER=N
else
  read_config "Stop container during restore" STOP_CONTAINER "$STOP_CONTAINER_DEFAULT"
fi

if [[ "${STOP_CONTAINER:u}" == "Y" && "$container_running" == "Y" ]]; then
  info_custom "${Yellow}Stopping ${Green}$CONTAINER_NAME"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
fi

get_first_file() { ls -1 "$1" 2>/dev/null | head -n 1; }

snapshot_type=""
if [[ -f "$CHECKPOINT_DIR/meta" ]]; then
  type_line=$(head -n1 "$CHECKPOINT_DIR/meta")
  snapshot_type=$(echo "$type_line" | sed -E 's/^type=//')
fi

postgres_dump=$(get_first_file "$CHECKPOINT_DIR/db-postgresql.sql.*")
mysql_dump=$(get_first_file "$CHECKPOINT_DIR/db-mysql.sql.*")
files_archive=$(get_first_file "$CHECKPOINT_DIR/files.tar.*")
hypers_archive=$(get_first_file "$CHECKPOINT_DIR/filesystem.tar.*")

if [[ -z "$snapshot_type" ]]; then
  if [[ -n "$postgres_dump" ]]; then snapshot_type="postgresql"; 
  elif [[ -n "$mysql_dump" ]]; then snapshot_type="mysql"; 
  else snapshot_type="hypersonic"; fi
fi

snapshot_format="standard"
if [[ -f "$CHECKPOINT_DIR/meta" ]]; then
  fmt_line=$(sed -n 's/^format=//p' "$CHECKPOINT_DIR/meta" | head -n1)
  [[ -n "$fmt_line" ]] && snapshot_format="$fmt_line"
fi
if [[ -d "$CHECKPOINT_DIR/database" || -d "$CHECKPOINT_DIR/doclib" ]]; then
  snapshot_format="liferay-cloud"
fi
if [[ "$snapshot_format" == "liferay-cloud" && "$snapshot_type" == "hypersonic" ]]; then
  _die "Liferay Cloud backups require PostgreSQL or MySQL; Hypersonic is not supported"
fi
if [[ -n "$FORMAT_OVERRIDE" ]]; then
  snapshot_format="$FORMAT_OVERRIDE"
elif [[ "$NON_INTERACTIVE" -ne 1 ]]; then
  read_config "Backup format (standard|liferay-cloud)" snapshot_format "$snapshot_format"
  case "$snapshot_format" in
    standard|liferay-cloud) : ;;
    *) _die "Invalid format: $snapshot_format (expected: standard or liferay-cloud)" ;;
  esac
fi

_decompress_cmd() {
  case "$1" in
    *.gz) echo "gunzip -c" ;;
    *.xz) echo "xz -dc" ;;
    *)    echo "cat" ;;
  esac
}

_tar_extract() {
  local archive="$1"
  case "$archive" in
    *.gz) tar -xzf "$archive" -C "$2" ;;
    *.xz) tar -xJf "$archive" -C "$2" ;;
    *)    tar -xf  "$archive" -C "$2" ;;
  esac
}

if [[ "$snapshot_type" == "hypersonic" ]]; then
  archive="$hypers_archive"
  [[ -z "$archive" ]] && _die "Missing filesystem archive in $CHECKPOINT_DIR"
  info "Restoring filesystem snapshot"
  find "$LIFERAY_ROOT" -mindepth 1 -maxdepth 1 ! -name "backups" -exec rm -rf {} +
  _tar_extract "$archive" "$LIFERAY_ROOT"
else
  jdbc_url=$(read_db_prop "jdbc.default.url")
  jdbc_user=$(read_db_prop "jdbc.default.username")
  jdbc_pass=$(read_db_prop "jdbc.default.password")

  if echo "$snapshot_type" | grep -qi "postgresql"; then
    if [[ "$snapshot_format" == "liferay-cloud" ]]; then
      dump_file="$CHECKPOINT_DIR/database/dump.sql.gz"
    else
      dump_file="$postgres_dump"
    fi
    [[ -z "$dump_file" || ! -f "$dump_file" ]] && _die "PostgreSQL dump not found in $CHECKPOINT_DIR"
    dbname=$(echo "$jdbc_url" | sed -E 's#^jdbc:postgresql://[^/]+/([^?]+).*#\1#')
    pghost="${PG_HOST_OVERRIDE:-$(echo "$jdbc_url" | sed -E 's#^jdbc:postgresql://([^/:?]+).*$#\1#')}"
    pgport="${PG_PORT_OVERRIDE:-$(echo "$jdbc_url" | sed -nE 's#^jdbc:postgresql://[^/:?]+:([0-9]+).*$#\1#p')}"
    [[ -z "$pghost" || "$pghost" == "$jdbc_url" ]] && pghost="localhost"
    [[ "$pghost" == "host.docker.internal" ]] && pghost="localhost"
    [[ -z "$pgport" ]] && pgport=5432

    info_custom "${Yellow}Resetting PostgreSQL database:${Color_Off} $dbname"
    PGPASSWORD="$jdbc_pass" psql -h "$pghost" -p "$pgport" -U "$jdbc_user" -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$dbname' AND pid <> pg_backend_pid();" >/dev/null 2>&1
    PGPASSWORD="$jdbc_pass" psql -h "$pghost" -p "$pgport" -U "$jdbc_user" -d postgres -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS \"$dbname\";" >/dev/null
    PGPASSWORD="$jdbc_pass" psql -h "$pghost" -p "$pgport" -U "$jdbc_user" -d postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$dbname\" WITH TEMPLATE template0 ENCODING 'UTF8';" >/dev/null

    info_custom "${Yellow}Importing PostgreSQL dump into:${Color_Off} $dbname"
    if [[ "$snapshot_format" == "liferay-cloud" ]]; then
      gunzip -c "$dump_file" | PGPASSWORD="$jdbc_pass" psql -h "$pghost" -p "$pgport" -U "$jdbc_user" -d "$dbname" >/dev/null
    else
      DECOMP=$(_decompress_cmd "$dump_file")
      eval "$DECOMP" "$dump_file" | PGPASSWORD="$jdbc_pass" psql -h "$pghost" -p "$pgport" -U "$jdbc_user" -d "$dbname" >/dev/null
    fi
  else
    if [[ "$snapshot_format" == "liferay-cloud" ]]; then
      dump_file="$CHECKPOINT_DIR/database/dump.sql.gz"
    else
      dump_file="$mysql_dump"
    fi
    [[ -z "$dump_file" || ! -f "$dump_file" ]] && _die "MySQL dump not found in $CHECKPOINT_DIR"
    dbname=$(echo "$jdbc_url" | sed -E 's#^jdbc:mysql://[^/]+/([^?]+).*#\1#')
    myhost="${MY_HOST_OVERRIDE:-$(echo "$jdbc_url" | sed -E 's#^jdbc:mysql://([^/:?]+).*$#\1#')}"
    myport="${MY_PORT_OVERRIDE:-$(echo "$jdbc_url" | sed -nE 's#^jdbc:mysql://[^/:?]+:([0-9]+).*$#\1#p')}"
    [[ -z "$myhost" || "$myhost" == "$jdbc_url" ]] && myhost="localhost"
    [[ "$myhost" == "host.docker.internal" ]] && myhost="localhost"
    [[ -z "$myport" ]] && myport=3306

    mysql -h "$myhost" -P "$myport" -u "$jdbc_user" -p"$jdbc_pass" -e "DROP DATABASE IF EXISTS \`$dbname\`; CREATE DATABASE \`$dbname\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null
    info_custom "${Yellow}Importing MySQL dump into:${Color_Off} $dbname"
    if [[ "$snapshot_format" == "liferay-cloud" ]]; then
      gunzip -c "$dump_file" | mysql -h "$myhost" -P "$myport" -u "$jdbc_user" -p"$jdbc_pass" >/dev/null
    else
      DECOMP=$(_decompress_cmd "$dump_file")
      eval "$DECOMP" "$dump_file" | mysql -h "$myhost" -P "$myport" -u "$jdbc_user" -p"$jdbc_pass" >/dev/null
    fi
  fi

  if [[ "$snapshot_format" == "liferay-cloud" ]]; then
    info_custom "${Yellow}Applying Liferay Cloud backup:${Color_Off} database and doclib only. Other files (configs, scripts, OSGi state) are not applied automatically."
    src_doclib="$CHECKPOINT_DIR/doclib"
    dest_doclib="$LIFERAY_ROOT/data/document_library"
    if [[ -d "$src_doclib" ]]; then
      mkdir -p "$dest_doclib"
      rm -rf "$dest_doclib"/* 2>/dev/null
      cp -R "$src_doclib"/. "$dest_doclib"/ 2>/dev/null
    fi
  else
    if files_archive=$(ls -1 "$CHECKPOINT_DIR"/files.tar.* 2>/dev/null | head -n1); then
      info "Restoring files archive"
      _tar_extract "$files_archive" "$LIFERAY_ROOT"
    fi
  fi
fi

DELETE_CHECKPOINT_DEFAULT=N
if [[ -n "$DELETE_AFTER_FLAG" ]]; then
  DELETE_CHECKPOINT=Y
elif [[ -n "$KEEP_CHECKPOINT_FLAG" ]]; then
  DELETE_CHECKPOINT=N
else
  read_config "Delete checkpoint after install" DELETE_CHECKPOINT "$DELETE_CHECKPOINT_DEFAULT"
fi

if [[ "${DELETE_CHECKPOINT:u}" == "Y" ]]; then
  rm -rf "$CHECKPOINT_DIR"
  info_custom "${Yellow}Deleted checkpoint:${Color_Off} $CHECKPOINT"
fi

if [[ "${STOP_CONTAINER:u}" == "Y" && "$container_exists" == "Y" ]]; then
  info_custom "${Yellow}Starting ${Green}$CONTAINER_NAME"
  docker start "$CONTAINER_NAME" >/dev/null 2>&1
fi

info_custom "${Green}Restore complete${Color_Off}"