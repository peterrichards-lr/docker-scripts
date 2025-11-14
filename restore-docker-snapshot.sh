#!/bin/zsh

set -o pipefail

SCRIPT_VERSION="2025-11-12"
MIN_META_VERSION=2
ALLOW_LEGACY=0

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
    typeset -g "$2"="$3"
    return
  fi
  if [[ -n $* ]]; then
    local ANSWER
    echo -n -e "${White}$1 [${Green}$3${White}]: ${Color_Off}"
    read -r ANSWER
    typeset -g "$2"="${ANSWER:-$3}"
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
DELETE_STATE_FLAG=""
DELETE_ES_FLAG=""
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
      shift; [[ -z "$1" || ! "$1" =~ '^[0-9]+$' ]] && _die "--index requires a numeric value"; INDEX_ARG="$1" ;;
    --checkpoint)
      shift; [[ -z "$1" ]] && _die "--checkpoint requires a folder name"; CHECKPOINT_ARG="$1" ;;
    --no-list)
      NO_LIST=1 ;;
    -s|--stop)
      STOP_FLAG=1 ;;
    --no-stop)
      NO_STOP_FLAG=1 ;;
    --delete-state)
      DELETE_STATE_FLAG=1 ;;
    --delete-elasticsearch)
      DELETE_ES_FLAG=1 ;;
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
    --min-meta-version)
      shift; [[ -z "$1" || "$1" != <-> ]] && _die "--min-meta-version requires an integer"; MIN_META_VERSION="$1" ;;
    --allow-legacy)
      ALLOW_LEGACY=1 ;;
    --quiet)
      QUIET=1 ;;
    --verbose)
      VERBOSE=1 ;;
    --version)
      echo "$0 $SCRIPT_VERSION"; exit 0 ;;
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
      echo "      --delete-state            Delete OSGi state folder before restore";
      echo "      --delete-elasticsearch    Delete Elasticsearch data folder (data/elasticsearch7) before restore";
      echo "      --non-interactive         Do not prompt; use defaults. In this mode:";
      echo "                                • root defaults to current directory";
      echo "                                • backup selection defaults to newest backup unless --index/--checkpoint is provided";
      echo "                                • container is stopped by default (unless --no-stop is provided)";
      echo "                                • checkpoint is kept by default (unless --delete-after is provided)";
      echo "                                • backup list is not shown";
      echo "      --format <standard|liferay-cloud>  Override auto-detected backup layout. Default: auto-detect";
      echo "";
      echo "      --min-meta-version <N>    Require meta_version >= N in backup meta (default: 2)";
      echo "      --allow-legacy            Allow restoring backups with meta_version < min supported";
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

if [[ "$NON_INTERACTIVE" -eq 1 && -n "$DELETE_STATE_FLAG$DELETE_ES_FLAG" && -z "$STOP_FLAG" ]]; then
  _die "--delete-state/--delete-elasticsearch require -s or --stop in non-interactive mode"
fi

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

if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
  if [[ -z "$DELETE_STATE_FLAG" ]]; then
    DELETE_STATE_FLAG=1
  fi
  if [[ -z "$DELETE_ES_FLAG" ]]; then
    DELETE_ES_FLAG=1
  fi
fi

if [[ "${STOP_CONTAINER:u}" == "Y" && "$container_running" == "Y" ]]; then
  info_custom "${Yellow}Stopping ${Green}$CONTAINER_NAME"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
fi

if [[ "$NON_INTERACTIVE" -eq 1 && "${STOP_CONTAINER:u}" == "Y" && -n "$DELETE_STATE_FLAG" ]]; then
  if [[ -d "$STATE_VOLUME" ]]; then
    info_custom "${Yellow}Deleting OSGi state folder:${Color_Off} $STATE_VOLUME"
    rm -rf "$STATE_VOLUME"
  fi
fi

if [[ "$NON_INTERACTIVE" -eq 1 && "${STOP_CONTAINER:u}" == "Y" && -n "$DELETE_ES_FLAG" ]]; then
  es_dir="$DATA_VOLUME/elasticsearch7"
  if [[ -d "$es_dir" ]]; then
    info_custom "${Yellow}Deleting Elasticsearch data folder:${Color_Off} $es_dir"
    rm -rf "$es_dir"
  fi
fi

if [[ "$NON_INTERACTIVE" -ne 1 && "${STOP_CONTAINER:u}" == "Y" ]]; then
  read_config "Delete OSGi state" DELETE_STATE_CHOICE "Y"
  if [[ "${DELETE_STATE_CHOICE:u}" == "Y" ]]; then
    if [[ -d "$STATE_VOLUME" ]]; then
      info_custom "${Yellow}Deleting OSGi state folder:${Color_Off} $STATE_VOLUME"
      rm -rf "$STATE_VOLUME"
    fi
  fi
  read_config "Delete Elasticsearch" DELETE_ES_CHOICE "Y"
  if [[ "${DELETE_ES_CHOICE:u}" == "Y" ]]; then
    es_dir="$DATA_VOLUME/elasticsearch7"
    if [[ -d "$es_dir" ]]; then
      info_custom "${Yellow}Deleting Elasticsearch data folder:${Color_Off} $es_dir"
      rm -rf "$es_dir"
    fi
  fi
fi

find_dump() {
  emulate -L zsh
  setopt localoptions null_glob extended_glob
  local dir="$1"; shift
  local pat
  for pat in "$@"; do
    local -a matches
    matches=($dir/$pat(N))
    if (( ${#matches} )); then
      print -r -- ${matches[1]}
      return 0
    fi
  done
  print -r -- ""
}

snapshot_type=""
if [[ -f "$CHECKPOINT_DIR/meta" ]]; then
  snapshot_type=$(sed -n 's/^type=//p' "$CHECKPOINT_DIR/meta" | head -n1)
fi

meta_version=1
if [[ -f "$CHECKPOINT_DIR/meta" ]]; then
  mv_line=$(sed -n 's/^meta_version=//p' "$CHECKPOINT_DIR/meta" | head -n1)
  [[ -n "$mv_line" ]] && meta_version="$mv_line"
fi

if [[ -f "$CHECKPOINT_DIR/meta" ]]; then
  meta_db_dump=$(sed -n 's/^db_dump=//p' "$CHECKPOINT_DIR/meta" | head -n1)
  meta_files_arc=$(sed -n 's/^files_archive=//p' "$CHECKPOINT_DIR/meta" | head -n1)
  if [[ -n "$meta_db_dump" ]]; then
    [[ "$meta_db_dump" = /* ]] || meta_db_dump="$CHECKPOINT_DIR/$meta_db_dump"
    case "$snapshot_type" in
      postgresql|postgres|pg)
        postgres_dump="$meta_db_dump"
        ;;
      mysql|mariadb)
        mysql_dump="$meta_db_dump"
        ;;
    esac
  fi
  if [[ -n "$meta_files_arc" ]]; then
    [[ "$meta_files_arc" = /* ]] || meta_files_arc="$CHECKPOINT_DIR/$meta_files_arc"
    files_archive="$meta_files_arc"
  fi
fi

postgres_dump=$(find_dump "$CHECKPOINT_DIR" \
  "db-postgresql.sql.*" \
  "db-postgres.sql.*" \
  "postgresql.sql.*" \
  "postgres.sql.*" \
  "pg.sql.*" \
  "database-postgresql.sql.*" \
  "database-postgres.sql.*" 2>/dev/null)

mysql_dump=$(find_dump "$CHECKPOINT_DIR" \
  "db-mysql.sql.*" \
  "mysql.sql.*" \
  "mariadb.sql.*" \
  "database-mysql.sql.*" 2>/dev/null)

files_archive=$(find_dump "$CHECKPOINT_DIR" "files.tar.*" 2>/dev/null)
hypers_archive=$(find_dump "$CHECKPOINT_DIR" "filesystem.tar.*" 2>/dev/null)

if [[ -z "$postgres_dump$mysql_dump" ]]; then
  emulate -L zsh
  setopt localoptions null_glob extended_glob
  local -a sqls
  sqls=($CHECKPOINT_DIR/*.sql.*(N))
  if (( ${#sqls} == 1 )); then
    case "$snapshot_type" in
      postgresql|postgres|pg)
        postgres_dump="${sqls[1]}"
        ;;
      mysql|mariadb)
        mysql_dump="${sqls[1]}"
        ;;
    esac
  fi
fi

FORMAT_INFERRED=0
snapshot_format="standard"
if [[ -f "$CHECKPOINT_DIR/meta" ]]; then
  fmt_line=$(sed -n 's/^format=//p' "$CHECKPOINT_DIR/meta" | head -n1)
  if [[ -n "$fmt_line" ]]; then
    snapshot_format="$fmt_line"
    FORMAT_INFERRED=1
  fi
fi
if [[ -f "$CHECKPOINT_DIR/database.gz" || -f "$CHECKPOINT_DIR/volume.tgz" ]]; then
  snapshot_format="liferay-cloud"
  FORMAT_INFERRED=1
fi
if [[ "$snapshot_format" == "liferay-cloud" && "$snapshot_type" == "hypersonic" ]]; then
  _die "Liferay Cloud backups require PostgreSQL or MySQL; Hypersonic is not supported"
fi
if [[ -n "$FORMAT_OVERRIDE" ]]; then
  snapshot_format="$FORMAT_OVERRIDE"
elif [[ "$NON_INTERACTIVE" -ne 1 && "$FORMAT_INFERRED" -eq 0 ]]; then
  read_config "Backup format (standard|liferay-cloud)" snapshot_format "$snapshot_format"
  case "$snapshot_format" in
    standard|liferay-cloud) : ;;
    *) _die "Invalid format: $snapshot_format (expected: standard or liferay-cloud)" ;;
  esac
fi

if [[ $VERBOSE -eq 1 ]]; then
  echo "meta_version: $meta_version (min_supported=$MIN_META_VERSION, allow_legacy=$ALLOW_LEGACY)"
  echo "snapshot: type=$snapshot_type format=$snapshot_format"
  [[ -n "$meta_db_dump" ]] && echo "meta hint: db_dump=$meta_db_dump"
  [[ -n "$meta_files_arc" ]] && echo "meta hint: files_archive=$meta_files_arc"
  [[ -n "$postgres_dump" ]] && echo "candidate postgres dump: $postgres_dump"
  [[ -n "$mysql_dump" ]] && echo "candidate mysql dump: $mysql_dump"
  [[ -n "$files_archive" ]] && echo "candidate files archive: $files_archive"
  [[ -n "$hypers_archive" ]] && echo "candidate hypers archive: $hypers_archive"
fi

if (( meta_version < MIN_META_VERSION )) && [[ "$ALLOW_LEGACY" -ne 1 ]]; then
  _die "Backup meta_version=$meta_version is older than the minimum supported ($MIN_META_VERSION). Re-create the snapshot with the updated create script, or re-run with --allow-legacy to bypass this check."
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
      dump_file="$CHECKPOINT_DIR/database.gz"
    else
      dump_file="$postgres_dump"
    fi
    [[ $VERBOSE -eq 1 ]] && echo "using database dump: $dump_file"
    [[ -z "$dump_file" || ! -f "$dump_file" ]] && _die "PostgreSQL dump not found in $CHECKPOINT_DIR (looked for db-postgresql.sql.*, db-postgres.sql.*, postgresql.sql.*, postgres.sql.*, pg.sql.*, database-postgresql.sql.*, database-postgres.sql.* or a single *.sql.*)"
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
      dump_file="$CHECKPOINT_DIR/database.gz"
    else
      dump_file="$mysql_dump"
    fi
    [[ $VERBOSE -eq 1 ]] && echo "using database dump: $dump_file"
    [[ -z "$dump_file" || ! -f "$dump_file" ]] && _die "MySQL dump not found in $CHECKPOINT_DIR (looked for db-mysql.sql.*, mysql.sql.*, mariadb.sql.*, database-mysql.sql.* or a single *.sql.*)"
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
    vol="$CHECKPOINT_DIR/volume.tgz"
    [[ $VERBOSE -eq 1 ]] && echo "using files archive: $vol"
    if [[ -f "$vol" ]]; then
      mkdir -p "$LIFERAY_ROOT/data"
      tar -xzf "$vol" -C "$LIFERAY_ROOT/data"
    fi
  else
    [[ -z "$files_archive" ]] && files_archive=$(find_dump "$CHECKPOINT_DIR" "files.tar.*")
    if [[ -n "$files_archive" ]]; then
      info "Restoring files archive"
      [[ $VERBOSE -eq 1 ]] && echo "using files archive: $files_archive"
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