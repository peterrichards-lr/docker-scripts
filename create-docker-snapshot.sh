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
SNAPSHOT_NAME_ARG=""
NO_SNAPSHOT_NAME=""
STOP_FLAG=""
NO_STOP_FLAG=""
NON_INTERACTIVE=0
QUIET=0
VERBOSE=0
DB_ONLY=0
FILES_ONLY=0
COMPRESSION="gzip"
PREFIX=""
VERIFY=0
BACKUPS_DIR_OVERRIDE=""
CONTAINER_NAME_OVERRIDE=""
PG_HOST_OVERRIDE=""
PG_PORT_OVERRIDE=""
MY_HOST_OVERRIDE=""
MY_PORT_OVERRIDE=""
RETENTION_N=""
TAGS=()
BACKUP_FORMAT="standard"
FORMAT_SET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--root)
      shift; [[ -z "$1" ]] && _die "--root requires a path"
      LIFERAY_ROOT_ARG="$1" ;;
    -b|--backups-dir)
      shift; [[ -z "$1" ]] && _die "--backups-dir requires a path"
      BACKUPS_DIR_OVERRIDE="$1" ;;
    -c|--container)
      shift; [[ -z "$1" ]] && _die "--container requires a name"
      CONTAINER_NAME_OVERRIDE="$1" ;;
    --non-interactive)
      NON_INTERACTIVE=1 ;;
    --db-only)
      DB_ONLY=1 ;;
    --files-only)
      FILES_ONLY=1 ;;
    --compression)
      shift; [[ -z "$1" ]] && _die "--compression requires a value"
      case "$1" in gzip|xz|none) COMPRESSION="$1" ;; *) _die "--compression must be gzip|xz|none";; esac ;;
    --prefix)
      shift; [[ -z "$1" ]] && _die "--prefix requires a value"
      PREFIX="$1" ;;
    --verify)
      VERIFY=1 ;;
    --quiet)
      QUIET=1 ;;
    --verbose)
      VERBOSE=1 ;;
    --pg-host)
      shift; [[ -z "$1" ]] && _die "--pg-host requires a value"
      PG_HOST_OVERRIDE="$1" ;;
    --pg-port)
      shift; [[ -z "$1" ]] && _die "--pg-port requires a value"
      PG_PORT_OVERRIDE="$1" ;;
    --my-host)
      shift; [[ -z "$1" ]] && _die "--my-host requires a value"
      MY_HOST_OVERRIDE="$1" ;;
    --my-port)
      shift; [[ -z "$1" ]] && _die "--my-port requires a value"
      MY_PORT_OVERRIDE="$1" ;;
    --tag)
      shift; [[ -z "$1" || "$1" != *"="* ]] && _die "--tag requires key=value"
      TAGS+="$1" ;;
    --retention)
      shift; [[ -z "$1" || "$1" != <-> ]] && _die "--retention requires an integer"
      RETENTION_N="$1" ;;
    --format)
      shift; [[ -z "$1" ]] && _die "--format requires standard|liferay-cloud"
      case "$1" in
        standard|liferay-cloud) BACKUP_FORMAT="$1"; FORMAT_SET=1 ;;
        *) _die "--format must be standard|liferay-cloud" ;;
      esac ;;
    --cloud)
      BACKUP_FORMAT="liferay-cloud"; FORMAT_SET=1 ;;
    -n|--name)
      shift; [[ -z "$1" ]] && _die "--name requires a value"
      SNAPSHOT_NAME_ARG="$1" ;;
    --no-name)
      NO_SNAPSHOT_NAME=1 ;;
    -s|--stop)
      STOP_FLAG=1 ;;
    --no-stop)
      NO_STOP_FLAG=1 ;;
    -h|--help)
      echo "Usage: $0 [options]";
      echo "";
      echo "Core paths and container:";
      echo "  -r, --root <path>             Project root. Default: current directory (interactive prompt if not provided).";
      echo "  -b, --backups-dir <path>      Backups directory. Default: <root>/backups";
      echo "  -c, --container <name>        Override container name. Default: basename(<root>) with dots replaced by dashes";
      echo "";
      echo "Snapshot content and compression:";
      echo "      --db-only / --files-only  Dump only DB or only filesystem. Default: both";
      echo "      --compression gzip|xz|none  Compression for dumps and tar. Default: gzip";
      echo "      --prefix <text>           Prefix for backup folder name (results in <prefix>-<timestamp>)";
      echo "      --format standard|liferay-cloud  Backup layout. Default: standard";
      echo "                                • liferay-cloud: database.gz (plain SQL, no owner/privileges) and volume.tgz (tar.gz of data/document_library)";
      echo "";
      echo "Behavior and prompts:";
      echo "  -s, --stop / --no-stop       Stop container during backup (and restart afterwards if it was running). Default: stop";
      echo "      --non-interactive         Do not prompt; use defaults. In this mode:";
      echo "                                • root defaults to current directory";
      echo "                                • container is stopped by default (unless --no-stop is provided)";
      echo "                                • snapshot name is empty unless --name is provided";
      echo "                                • no prompts are shown (defaults are applied silently)";
      echo "  -n, --name <text>            Optional snapshot name (stored in meta).";
      echo "      --no-name                Skip the name prompt and store no name";
      echo "";
      echo "Database connection overrides (if dumping DB):";
      echo "      --pg-host/--pg-port       Override PostgreSQL host/port. Defaults: parsed from JDBC URL; host.docker.internal -> localhost; port 5432 if missing";
      echo "      --my-host/--my-port       Override MySQL host/port. Defaults: parsed from JDBC URL; host.docker.internal -> localhost; port 3306 if missing";
      echo "";
      echo "Metadata and retention:";
      echo "      --tag key=value           Repeatable; stored in meta as tag.<key>=<value>";
      echo "      --retention <N>           Keep only newest N backups (older ones pruned). If --prefix is set, pruning applies only to backups starting with that prefix";
      echo "";
      echo "Verification and logging:";
      echo "      --verify                  Validate created archives (gzip/xz integrity, tar list)";
      echo "      --quiet | --verbose       Adjust logging verbosity. Default: normal";
      exit 0 ;;
    *) _die "Unknown option: $1" ;;
  esac
  shift
done

if [[ -z "$BACKUP_FORMAT" ]]; then
  BACKUP_FORMAT="standard"
fi
if [[ "$NON_INTERACTIVE" -ne 1 && "$FORMAT_SET" -ne 1 ]]; then
  read_config "Backup format (standard|liferay-cloud)" BACKUP_FORMAT "${BACKUP_FORMAT}"
  case "$BACKUP_FORMAT" in
    standard|liferay-cloud) : ;;
    *) _die "Invalid format: $BACKUP_FORMAT (expected: standard or liferay-cloud)" ;;
  esac
fi

[[ $VERBOSE -eq 1 ]] && set -x

if [[ $DB_ONLY -eq 1 && $FILES_ONLY -eq 1 ]]; then
  _die "--db-only and --files-only are mutually exclusive"
fi

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

mkdir -p "$BACKUPS_DIR"

if [[ -n "$CONTAINER_NAME_OVERRIDE" ]]; then
  CONTAINER_NAME="$CONTAINER_NAME_OVERRIDE"
else
  CONTAINER_NAME=$(echo "$LIFERAY_ROOT" | sed -e 's:.*/::' -e 's/[\.]/-/g')
fi
container_running=$(docker ps --format '{{.Names}}' | grep -x "$CONTAINER_NAME" >/dev/null 2>&1 && echo "Y" || echo "N")

STOP_CONTAINER_DEFAULT=Y
if [[ -n "$STOP_FLAG" ]]; then
  STOP_CONTAINER=Y
elif [[ -n "$NO_STOP_FLAG" ]]; then
  STOP_CONTAINER=N
else
  read_config "Stop container during backup" STOP_CONTAINER "$STOP_CONTAINER_DEFAULT"
fi

if [[ "${STOP_CONTAINER:u}" == "Y" && "$container_running" == "Y" ]]; then
  info_custom "${Yellow}Stopping ${Green}$CONTAINER_NAME"
  docker stop "$CONTAINER_NAME" >/dev/null 2>&1
fi

timestamp=$(date +"%Y%m%d-%H%M%S")
dir_name="$timestamp"
[[ -n "$PREFIX" ]] && dir_name="$PREFIX-$dir_name"
checkpoint_dir="$BACKUPS_DIR/$dir_name"
mkdir -p "$checkpoint_dir"

if [[ -n "$SNAPSHOT_NAME_ARG" ]]; then
  SNAPSHOT_NAME="$SNAPSHOT_NAME_ARG"
elif [[ "$NO_SNAPSHOT_NAME" == 1 || "$NON_INTERACTIVE" == 1 ]]; then
  SNAPSHOT_NAME=""
else
  read_config "Snapshot Name (optional)" SNAPSHOT_NAME ""
fi

case "$COMPRESSION" in
  gzip) TAR_FLAG=z; COMPRESS_EXT=".gz"; COMPRESS_CMD="gzip -c" ;;
  xz)   TAR_FLAG=J; COMPRESS_EXT=".xz"; COMPRESS_CMD="xz -c" ;;
  none) TAR_FLAG=""; COMPRESS_EXT="";  COMPRESS_CMD="cat" ;;
esac

jdbc_url=""; jdbc_user=""; jdbc_pass=""
if [[ -f "$FILES_VOLUME/portal-ext.properties" ]]; then
  jdbc_url=$(read_db_prop "jdbc.default.url")
  jdbc_user=$(read_db_prop "jdbc.default.username")
  jdbc_pass=$(read_db_prop "jdbc.default.password")
fi

if [[ -z "$jdbc_url" ]]; then
  snap_type="hypersonic"
else
  echo "$jdbc_url" | grep -qi "postgresql" && snap_type="postgresql"
  echo "$jdbc_url" | grep -qi "mysql" && snap_type="${snap_type:-mysql}"
fi

if [[ "$BACKUP_FORMAT" == "liferay-cloud" && "$snap_type" == "hypersonic" ]]; then
  _die "Liferay Cloud format requires PostgreSQL or MySQL; Hypersonic is not supported"
fi

{
  printf "type=%s\n" "$snap_type"
  printf "format=%s\n" "$BACKUP_FORMAT"
  [[ -n "$SNAPSHOT_NAME" ]] && printf "name=%s\n" "$SNAPSHOT_NAME"
  for tag in "${TAGS[@]}"; do
    key="${tag%%=*}"; val="${tag#*=}"
    printf "tag.%s=%s\n" "$key" "$val"
  done
} > "$checkpoint_dir/meta"

if [[ $FILES_ONLY -eq 0 ]]; then
  if [[ "$snap_type" == "postgresql" ]]; then
    dbname=$(echo "$jdbc_url" | sed -E 's#^jdbc:postgresql://[^/]+/([^?]+).*#\1#')
    pghost="${PG_HOST_OVERRIDE:-localhost}"
    pgport="${PG_PORT_OVERRIDE:-5432}"
    [[ "$pghost" == "host.docker.internal" ]] && pghost="localhost"
    if [[ "$BACKUP_FORMAT" == "liferay-cloud" ]]; then
      dump_file="$checkpoint_dir/database.gz"
      info "Dumping PostgreSQL database: $dbname"
      if [[ $QUIET -eq 1 ]]; then
        PGPASSWORD="$jdbc_pass" pg_dump -h "$pghost" -p "$pgport" -U "$jdbc_user" -d "$dbname" -F p --no-owner --no-privileges | gzip -c > "$dump_file" 2>/dev/null
      else
        PGPASSWORD="$jdbc_pass" pg_dump -h "$pghost" -p "$pgport" -U "$jdbc_user" -d "$dbname" -F p --no-owner --no-privileges | gzip -c > "$dump_file"
      fi
    else
      dump_file="$checkpoint_dir/db-postgresql.sql$COMPRESS_EXT"
      info "Dumping PostgreSQL database: $dbname"
      if [[ $QUIET -eq 1 ]]; then
        PGPASSWORD="$jdbc_pass" pg_dump -h "$pghost" -p "$pgport" -U "$jdbc_user" -d "$dbname" | eval "$COMPRESS_CMD" > "$dump_file" 2>/dev/null
      else
        PGPASSWORD="$jdbc_pass" pg_dump -h "$pghost" -p "$pgport" -U "$jdbc_user" -d "$dbname" | eval "$COMPRESS_CMD" > "$dump_file"
      fi
    fi
  elif [[ "$snap_type" == "mysql" ]]; then
    dbname=$(echo "$jdbc_url" | sed -E 's#^jdbc:mysql://[^/]+/([^?]+).*#\1#')
    myhost="${MY_HOST_OVERRIDE:-localhost}"
    myport="${MY_PORT_OVERRIDE:-3306}"
    [[ "$myhost" == "host.docker.internal" ]] && myhost="localhost"
    if [[ "$BACKUP_FORMAT" == "liferay-cloud" ]]; then
      dump_file="$checkpoint_dir/database.gz"
      info "Dumping MySQL database: $dbname"
      if [[ $QUIET -eq 1 ]]; then
        mysqldump -h "$myhost" -P "$myport" -u "$jdbc_user" -p"$jdbc_pass" --databases "$dbname" | gzip -c > "$dump_file" 2>/dev/null
      else
        mysqldump -h "$myhost" -P "$myport" -u "$jdbc_user" -p"$jdbc_pass" --databases "$dbname" | gzip -c > "$dump_file"
      fi
    else
      dump_file="$checkpoint_dir/db-mysql.sql$COMPRESS_EXT"
      info "Dumping MySQL database: $dbname"
      if [[ $QUIET -eq 1 ]]; then
        mysqldump -h "$myhost" -P "$myport" -u "$jdbc_user" -p"$jdbc_pass" --databases "$dbname" | eval "$COMPRESS_CMD" > "$dump_file" 2>/dev/null
      else
        mysqldump -h "$myhost" -P "$myport" -u "$jdbc_user" -p"$jdbc_pass" --databases "$dbname" | eval "$COMPRESS_CMD" > "$dump_file"
      fi
    fi
  else
    if [[ $DB_ONLY -eq 1 ]]; then
      info_custom "${Yellow}No JDBC config detected; skipping DB dump (db-only requested).${Color_Off}"
    fi
  fi
fi

if [[ $DB_ONLY -eq 0 ]]; then
  if [[ "$BACKUP_FORMAT" == "liferay-cloud" ]]; then
    src_dir="$LIFERAY_ROOT/data/document_library"
    archive_file="$checkpoint_dir/volume.tgz"
    if [[ -d "$src_dir" ]]; then
      if [[ $QUIET -eq 1 ]]; then
        tar -czf "$archive_file" -C "$LIFERAY_ROOT/data" document_library 2>/dev/null
      else
        tar -czf "$archive_file" -C "$LIFERAY_ROOT/data" document_library 2>/dev/null
      fi
    fi
  else
    info "Archiving Liferay volumes"
    files_archive="$checkpoint_dir/files.tar${COMPRESS_EXT}"
    if [[ -n "$TAR_FLAG" ]]; then
      if [[ $QUIET -eq 1 ]]; then
        tar -c${TAR_FLAG}f "$files_archive" -C "$LIFERAY_ROOT" files scripts osgi data deploy 2>/dev/null
      else
        tar -c${TAR_FLAG}f "$files_archive" -C "$LIFERAY_ROOT" files scripts osgi data deploy 2>/dev/null
      fi
    else
      if [[ $QUIET -eq 1 ]]; then
        tar -cf "$files_archive" -C "$LIFERAY_ROOT" files scripts osgi data deploy 2>/dev/null
      else
        tar -cf "$files_archive" -C "$LIFERAY_ROOT" files scripts osgi data deploy 2>/dev/null
      fi
    fi
  fi
fi

if [[ $VERIFY -eq 1 ]]; then
  info "Verifying snapshot integrity"
  if [[ "$BACKUP_FORMAT" == "liferay-cloud" ]]; then
    if [[ -f "$checkpoint_dir/database.gz" ]]; then
      gzip -t "$checkpoint_dir/database.gz" || _die "Verification failed: database.gz"
    fi
    if [[ -f "$checkpoint_dir/volume.tgz" ]]; then
      tar -tf "$checkpoint_dir/volume.tgz" >/dev/null || _die "Verification failed: volume.tgz"
    else
      _die "Verification failed: volume.tgz missing"
    fi
  else
    if ls "$checkpoint_dir"/db-*.sql* >/dev/null 2>&1; then
      for f in "$checkpoint_dir"/db-*.sql*; do
        case "$f" in
          *.gz)  gzip -t "$f" || _die "Verification failed: $f" ;;
          *.xz)  xz -t "$f" || _die "Verification failed: $f" ;;
          *.sql) [[ -s "$f" ]] || _die "Verification failed (empty): $f" ;;
        esac
      done
    fi
    if ls "$checkpoint_dir"/files.tar* >/dev/null 2>&1; then
      if [[ "$COMPRESSION" == "none" ]]; then
        tar -tf "$checkpoint_dir/files.tar" >/dev/null || _die "Verification failed: files.tar"
      else
        tar -tf "$checkpoint_dir/files.tar${COMPRESS_EXT}" >/dev/null || _die "Verification failed: files.tar${COMPRESS_EXT}"
      fi
    fi
  fi
fi

if [[ "${STOP_CONTAINER:u}" == "Y" && "$container_running" == "Y" ]]; then
  info_custom "${Yellow}Starting ${Green}$CONTAINER_NAME"
  docker start "$CONTAINER_NAME" >/dev/null 2>&1
fi

if [[ -n "$RETENTION_N" ]]; then
  info "Pruning backups to keep newest $RETENTION_N"
  if [[ -d "$BACKUPS_DIR" ]]; then
    IFS=$'\n' all_bks=($(ls -1 "$BACKUPS_DIR" 2>/dev/null | sort -r))
    unset IFS
    kept=0
    for d in "${all_bks[@]}"; do
      if [[ -n "$PREFIX" && "$d" != "$PREFIX"-* ]]; then
        continue
      fi
      kept=$((kept+1))
      if (( kept > RETENTION_N )); then
        rm -rf "$BACKUPS_DIR/$d"
      fi
    done
  fi
fi

if [[ -n "$SNAPSHOT_NAME" ]]; then
  info_custom "${Green}Backup created:${Color_Off} $checkpoint_dir  ${BYellow}($SNAPSHOT_NAME)"
else
  info_custom "${Green}Backup created:${Color_Off} $checkpoint_dir"
fi

if [[ "$BACKUP_FORMAT" == "liferay-cloud" ]]; then
  up_db="$checkpoint_dir/database.gz"
  up_vol="$checkpoint_dir/volume.tgz"
  info_custom "${Yellow}Example Liferay Cloud upload (edit URL and TOKEN):${Color_Off}"
  echo "curl -X POST \\\""
  echo "  https://your-project.your-env.lfr.cloud/backup/upload \\\""
  echo "  -H 'Content-Type: multipart/form-data' \\\""
  echo "  -H 'dxpcloud-authorization: Bearer TOKEN' \\\""
  echo "  -F 'database=@$up_db' \\\""
  echo "  -F 'volume=@$up_vol'"
fi