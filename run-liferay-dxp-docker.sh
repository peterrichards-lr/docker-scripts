#!/bin/zsh

Color_Off='\033[0m'
Green='\033[0;32m'
Yellow='\033[0;33m'
White='\033[0;37m'
BYellow='\033[1;33m'
Red='\033[0;31m'
BRed='\033[1;31m'

info() { [[ -n $* ]] && echo -e "${Yellow}$1${Color_Off}"; }
info_custom() { [[ -n $* ]] && echo -e "$1${Color_Off}"; }
error() { echo -e "${BRed}Error:${Color_Off} $*" 1>&2; }
_die() { error "$*"; exit 1; }
read_config() { if [[ "$NON_INTERACTIVE" == 1 ]]; then typeset -g "$2"="$3"; return; fi; if [[ -n $* ]]; then local ANSWER; echo -n -e "${White}$1 [${Green}$3${White}]: ${Color_Off}"; read -r ANSWER; typeset -g "$2"="${ANSWER:-$3}"; fi }
read_input()  { if [[ "$NON_INTERACTIVE" == 1 ]]; then typeset -g "$2"="$3"; return; fi; if [[ -n $* ]]; then local ANSWER; echo -n -e "${White}$1: ${Color_Off}"; read -r ANSWER; typeset -g "$2"="${ANSWER}"; fi }
read_password(){ if [[ "$NON_INTERACTIVE" == 1 ]]; then typeset -g "$2"="$3"; return; fi; if [[ -n $* ]]; then local ANSWER; echo -n -e "${White}$1: ${Color_Off}"; read -rs ANSWER; echo -e ""; typeset -g "$2"="${ANSWER}"; fi }

IMAGE_NAME=liferay/dxp

NON_INTERACTIVE=0
QUIET=0
VERBOSE=0
ROOT_ARG=""
TAG_ARG=""
CONTAINER_ARG=""
RELEASE_TYPE_ARG=""
DB_KIND=""
JDBC_USERNAME_ARG=""
JDBC_PASSWORD_ARG=""
RECREATE_DB_FLAG=""
HOST_NETWORK_FLAG=""
NO_HOST_NETWORK_FLAG=""
DISABLE_ZIP64_FLAG_EXPL=""
ENABLE_ZIP64_FLAG_EXPL=""
PORT_ARG=""
REMOVE_AFTER_FLAG=""
KEEP_CONTAINER_FLAG=""
DELETE_STATE_FLAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--root) shift; [[ -z "$1" ]] && _die "--root requires a path"; ROOT_ARG="$1" ;;
    -t|--tag) shift; [[ -z "$1" ]] && _die "--tag requires a value"; TAG_ARG="$1" ;;
    -c|--container) shift; [[ -z "$1" ]] && _die "--container requires a name"; CONTAINER_ARG="$1" ;;
    --release-type) shift; [[ -z "$1" ]] && _die "--release-type requires any|u|lts"; case "${1:l}" in any|u|lts) RELEASE_TYPE_ARG="${1:l}" ;; *) _die "--release-type must be any|u|lts";; esac ;;
    --non-interactive) NON_INTERACTIVE=1 ;;
    --db) shift; [[ -z "$1" ]] && _die "--db requires postgresql|mysql|hypersonic"; case "${1:l}" in postgresql|mysql|hypersonic) DB_KIND="${1:l}" ;; *) _die "--db must be postgresql|mysql|hypersonic";; esac ;;
    --hypersonic) DB_KIND="hypersonic" ;;
    --jdbc-username) shift; [[ -z "$1" ]] && _die "--jdbc-username requires a value"; JDBC_USERNAME_ARG="$1" ;;
    --jdbc-password) shift; [[ -z "$1" ]] && _die "--jdbc-password requires a value"; JDBC_PASSWORD_ARG="$1" ;;
    --recreate-db) RECREATE_DB_FLAG=1 ;;
    --host-network) HOST_NETWORK_FLAG=1 ;;
    --no-host-network) NO_HOST_NETWORK_FLAG=1 ;;
    --disable-zip64) DISABLE_ZIP64_FLAG_EXPL=1 ;;
    --enable-zip64) ENABLE_ZIP64_FLAG_EXPL=1 ;;
    -p|--port) shift; [[ -z "$1" || "$1" != <-> ]] && _die "--port requires a number"; PORT_ARG="$1" ;;
    --remove-after) REMOVE_AFTER_FLAG=1 ;;
    --keep-container) KEEP_CONTAINER_FLAG=1 ;;
    --delete-state) DELETE_STATE_FLAG=1 ;;
    --quiet) QUIET=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help)
      echo "Usage: $0 [options]";
      echo "";
      echo "Core paths and image:";
      echo "  -t, --tag <tag>               Liferay Docker image tag. Default: latest tag for chosen release type";
      echo "  -r, --root <path>             Project root. Default: ./<tag>";
      echo "  -c, --container <name>        Container name. Default: basename(<root>) with dots replaced by dashes";
      echo "      --release-type any|u|lts  Tag discovery mode. Default: any";
      echo "";
      echo "Database selection:";
      echo "      --db postgresql|mysql|hypersonic  Database choice. Default: prompt; non-interactive defaults to hypersonic unless JDBC opts provided";
      echo "      --jdbc-username <name>    Username for external DB";
      echo "      --jdbc-password <pass>    Password for external DB";
      echo "      --recreate-db             Drop and recreate the target database if it exists";
      echo "";
      echo "Runtime behavior:";
      echo "  -p, --port <8080>             Local HTTP port mapping. Default: 8080";
      echo "      --host-network|--no-host-network  Use or avoid host networking. Default: disabled";
      echo "      --disable-zip64|--enable-zip64    Toggle Zip64 extra field validation. Default: disabled";
      echo "      --remove-after|--keep-container   Remove container after run or keep it. Default: keep when created, stop when kept";
      echo "      --delete-state             When container already exists, delete osgi/state before starting";
      echo "      --non-interactive         Do not prompt; apply defaults and provided flags";
      echo "      --quiet | --verbose       Adjust logging";
      exit 0 ;;
    *) _die "Unknown option: $1" ;;
  esac
  shift
done

[[ $VERBOSE -eq 1 ]] && set -x

if [[ -n "$TAG_ARG" ]]; then
  LIFERAY_TAG="$TAG_ARG"
else
  API_BASE='https://hub.docker.com/v2/repositories/liferay/dxp/tags?page_size=2048&ordering=name'
  if [[ -n "$RELEASE_TYPE_ARG" ]]; then RELEASE_TYPE="$RELEASE_TYPE_ARG"; else if [[ $NON_INTERACTIVE -eq 1 ]]; then RELEASE_TYPE=any; else read_config "Release type (any|u|lts)" RELEASE_TYPE any; fi; fi
  case "${RELEASE_TYPE:l}" in
    lts) QUERY_URL="$API_BASE&name=-lts"; PATTERN='^[0-9]{4}\.q[0-9]+\.[0-9]+-lts$' ;;
    u)   QUERY_URL="$API_BASE&name=-u";   PATTERN='^[0-9]{4}\.q[0-9]+\.[0-9]+-u[0-9]+$' ;;
    *)   QUERY_URL="$API_BASE";           PATTERN='^[0-9]{4}\.q[0-9]+\.[0-9]+(?:-(?:u[0-9]+|lts))?$' ;;
  esac
  LIFERAY_TAG_DEFAULT=$(curl -s "$QUERY_URL" | jq -r --arg year "$(date +%Y)" --arg pat "$PATTERN" '.results[].name | select(startswith($year)) | select(test($pat))' | sort -V | tail -n1)
  if [[ -z "$LIFERAY_TAG_DEFAULT" ]]; then LIFERAY_TAG_DEFAULT=$(curl -s "$QUERY_URL" | jq -r --arg pat "$PATTERN" '.results[].name | select(test($pat))' | sort -V | tail -n1); fi
  if [[ -z "$LIFERAY_TAG_DEFAULT" ]]; then info_custom "${Yellow}Could not auto-detect a Docker tag for release type '${BYellow}${RELEASE_TYPE}${Yellow}'. Please enter one manually."; fi
  if [[ $NON_INTERACTIVE -eq 1 ]]; then LIFERAY_TAG="$LIFERAY_TAG_DEFAULT"; else read_config "Enter Liferay Docker Tag" LIFERAY_TAG "$LIFERAY_TAG_DEFAULT"; fi
fi

if [[ -n "$ROOT_ARG" ]]; then LIFERAY_ROOT="$ROOT_ARG"; else LIFERAY_ROOT_DEFAULT=./${LIFERAY_TAG}; if [[ $NON_INTERACTIVE -eq 1 ]]; then LIFERAY_ROOT="$LIFERAY_ROOT_DEFAULT"; else read_config "Liferay Root" LIFERAY_ROOT "$LIFERAY_ROOT_DEFAULT"; fi; fi
CONTAINER_NAME=${CONTAINER_ARG:-$(echo "$LIFERAY_ROOT" | sed -e 's:.*/::' -e 's/[\.]/-/g')}
LIFRAY_IMAGE_TAG=$IMAGE_NAME:$LIFERAY_TAG
if ! [[ "$LIFERAY_ROOT" =~ ^(\.\/|\/).+$ ]]; then LIFERAY_ROOT=./$LIFERAY_ROOT; fi

DEPLOY_VOLUME=$LIFERAY_ROOT/deploy
DATA_VOLUME=$LIFERAY_ROOT/data
SCRIPT_VOLUME=$LIFERAY_ROOT/scripts
FILES_VOLUME=$LIFERAY_ROOT/files
CX_VOLUME=$LIFERAY_ROOT/osgi/client-extensions
STATE_VOLUME=$LIFERAY_ROOT/osgi/state
BACKUPS_DIR=$LIFERAY_ROOT/backups

info_custom "${Yellow}Deploy folder: ${BYellow}$DEPLOY_VOLUME"
info_custom "${Yellow}Data folder: ${BYellow}$DATA_VOLUME"
info_custom "${Yellow}Scripts folder: ${BYellow}$SCRIPT_VOLUME"
info_custom "${Yellow}Files folder: ${BYellow}$FILES_VOLUME"
info_custom "${Yellow}Client Extension folder: ${BYellow}$CX_VOLUME"
info_custom "${Yellow}OSGi state folder: ${BYellow}$STATE_VOLUME"
info_custom "${Yellow}Backups folder: ${BYellow}$BACKUPS_DIR"

docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1

if [ $? -eq 1 ]; then
  info_custom "${Green}$CONTAINER_NAME ${White}does not exist"
  if [[ -n "$REMOVE_AFTER_FLAG" ]]; then REMOVE_CONTAINER=Y; elif [[ -n "$KEEP_CONTAINER_FLAG" ]]; then REMOVE_CONTAINER=N; else read_config "Remove container afterwards" REMOVE_CONTAINER Y; fi
  if [[ -n "$DB_KIND" ]]; then if [[ "$DB_KIND" == "hypersonic" ]]; then USE_HYPERSONIC=Y; else USE_HYPERSONIC=N; LIFERAY_DATABASE="$DB_KIND"; fi; else if [[ $NON_INTERACTIVE -eq 1 ]]; then USE_HYPERSONIC=Y; else read_config "Use Hypersonic database" USE_HYPERSONIC N; fi; fi
  if [[ "${USE_HYPERSONIC:u}" == "N" ]]; then
    if [[ -z "$LIFERAY_DATABASE" ]]; then if [[ $NON_INTERACTIVE -eq 1 ]]; then LIFERAY_DATABASE=postgresql; else read_config "Liferay Root - postgresql or mysql" LIFERAY_DATABASE postgresql; fi; fi
    DATABASE_NAME=${CONTAINER_NAME/-/}
    if [[ "${LIFERAY_DATABASE:l}" == "postgresql" ]]; then
      JDBC_CLASS=org.postgresql.Driver
      JDBC_CONNECTTION=postgresql://host.docker.internal:5432/${DATABASE_NAME}
      if [[ -n "$JDBC_USERNAME_ARG" ]]; then JDBC_USERNAME="$JDBC_USERNAME_ARG"; else read_input "Username" JDBC_USERNAME; fi
      if psql -lqt | cut -d \| -f 1 | grep -qw "${DATABASE_NAME}" >/dev/null 2>&1; then
        if [[ -n "$RECREATE_DB_FLAG" ]]; then RECREATE_DATABASE=Y; else read_config "Recreate database" RECREATE_DATABASE N; fi
        if [[ "${RECREATE_DATABASE:u}" == "Y" ]]; then
          info_custom "${Yellow}Deleting PostgreSQL database: ${BYellow}${DATABASE_NAME}"
          dropdb -f ${DATABASE_NAME} >/dev/null 2>&1
          info_custom "${Yellow}Creating PostgreSQL database: ${BYellow}${DATABASE_NAME}"
          createdb -h localhost -p 5432 -U ${JDBC_USERNAME} -O ${JDBC_USERNAME} ${DATABASE_NAME} >/dev/null 2>&1
        fi
      else
        info_custom "${Yellow}Creating PostgreSQL database: ${BYellow}${DATABASE_NAME}"
        createdb -h localhost -p 5432 -U ${JDBC_USERNAME} -O ${JDBC_USERNAME} ${DATABASE_NAME} >/dev/null 2>&1
      fi
    else
      JDBC_CLASS=com.mysql.cj.jdbc.Driver
      JDBC_CONNECTTION=mysql://host.docker.internal:3306/${DATABASE_NAME}
      if [[ -n "$JDBC_USERNAME_ARG" ]]; then JDBC_USERNAME="$JDBC_USERNAME_ARG"; else read_input "Username" JDBC_USERNAME; fi
      if [[ -n "$JDBC_PASSWORD_ARG" ]]; then JDBC_PASSWORD="$JDBC_PASSWORD_ARG"; else read_password "Password" JDBC_PASSWORD; fi
      if mysql -u "$JDBC_USERNAME" -p"$JDBC_PASSWORD" -e "use ${DATABASE_NAME}" >/dev/null 2>&1; then
        if [[ -n "$RECREATE_DB_FLAG" ]]; then RECREATE_DATABASE=Y; else read_config "Recreate database" RECREATE_DATABASE N; fi
        if [[ "${RECREATE_DATABASE:u}" == "Y" ]]; then
          info_custom "${Yellow}Deleting MySQL database: ${BYellow}${DATABASE_NAME}"
          mysql -u $JDBC_USERNAME -p$JDBC_PASSWORD -e "drop database ${DATABASE_NAME};" >/dev/null 2>&1
          info_custom "${Yellow}Creating MySQL database: ${BYellow}${DATABASE_NAME}"
          mysql -u $JDBC_USERNAME -p$JDBC_PASSWORD -e "create database ${DATABASE_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null 2>&1
        fi
      else
        info_custom "${Yellow}Creating MySQL database: ${BYellow}${DATABASE_NAME}"
        mysql -u $JDBC_USERNAME -p$JDBC_PASSWORD -e "create database ${DATABASE_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >/dev/null 2>&1
      fi
    fi
    JDBC_CLASS=jdbc.default.driverClassName=$JDBC_CLASS
    JDBC_CONNECTTION=jdbc.default.url=jdbc:$JDBC_CONNECTTION
    JDBC_USERNAME=jdbc.default.username=$JDBC_USERNAME
    if ! [ -z ${JDBC_PASSWORD+x} ]; then JDBC_PASSWORD=jdbc.default.password=$JDBC_PASSWORD; fi
  fi
  if [[ -n "$HOST_NETWORK_FLAG" ]]; then USE_HOST_NETWORK=Y; elif [[ -n "$NO_HOST_NETWORK_FLAG" ]]; then USE_HOST_NETWORK=N; else read_config "Use host network" USE_HOST_NETWORK N; fi
  if [[ -n "$DISABLE_ZIP64_FLAG_EXPL" ]]; then DISABLE_ZIP64_EXTRA_FIELD_VALIDATION=Y; elif [[ -n "$ENABLE_ZIP64_FLAG_EXPL" ]]; then DISABLE_ZIP64_EXTRA_FIELD_VALIDATION=N; else read_config "Disable ZIP64 Extra Field Validation" DISABLE_ZIP64_EXTRA_FIELD_VALIDATION N; fi
  if [[ -n "$PORT_ARG" ]]; then LOCAL_PORT="$PORT_ARG"; else read_config "Local Port" LOCAL_PORT 8080; fi
  if [[ ! -d $LIFERAY_ROOT ]]; then
    info "${Yellow}Creating ${BYellow}volume ${Yellow}folders"
    mkdir -p "$DEPLOY_VOLUME" && cp ./7.4-common/*activationkeys.xml "$DEPLOY_VOLUME"/
    mkdir "$DATA_VOLUME"
    mkdir -p "$CX_VOLUME"
    mkdir -p "$STATE_VOLUME"
    mkdir -p "$FILES_VOLUME"
    mkdir -p "$SCRIPT_VOLUME"
    mkdir -p "$BACKUPS_DIR"
    cp ./7.4-common/*.properties "$FILES_VOLUME"
  fi
  if [[ "${USE_HYPERSONIC:u}" == "N" ]]; then
    if ! grep -q "jdbc.default.driverClassName" "${FILES_VOLUME}/portal-ext.properties"; then
      info_custom "${Yellow}Updating ${BYellow}portal-ext.properties"
      { echo -e "\n"; echo -e "$JDBC_CLASS"; echo -e "$JDBC_CONNECTTION"; echo -e "$JDBC_USERNAME"; } >> "${FILES_VOLUME}"/portal-ext.properties
      if ! [[ -z ${JDBC_PASSWORD+x} ]]; then echo -e "$JDBC_PASSWORD" >> "${FILES_VOLUME}"/portal-ext.properties; fi
    fi
  fi
  if [[ "${DISABLE_ZIP64_EXTRA_FIELD_VALIDATION:u}" == "Y" ]]; then DISABLE_ZIP64_FLAG="-e LIFERAY_JVM_OPTS=-Djdk.util.zip.disableZip64ExtraFieldValidation=true"; fi
  if [[ "${USE_HOST_NETWORK:u}" == "Y" ]]; then NETWORK_HOST=--network=host; fi
  info_custom "${Yellow}Creating ${BYellow}$CONTAINER_NAME ${Yellow}with ${BYellow}$LIFRAY_IMAGE_TAG"
  docker pull "$LIFRAY_IMAGE_TAG" | grep "Status: " | awk 'NF>1{print $NF}' | xargs -I{} docker create -it ${NETWORK_HOST} --name "${CONTAINER_NAME}" -p ${LOCAL_PORT}:8080 ${DISABLE_ZIP64_FLAG} -v "${FILES_VOLUME}:/mnt/liferay/files" -v "${SCRIPT_VOLUME}:/mnt/liferay/scripts" -v "${STATE_VOLUME}:/opt/liferay/osgi/state" -v "${DATA_VOLUME}:/opt/liferay/data" -v "${DEPLOY_VOLUME}:/mnt/liferay/deploy" -v "${CX_VOLUME}:/opt/liferay/osgi/client-extensions" {}
  docker start -i -a "${CONTAINER_NAME}"
  if [[ "${REMOVE_CONTAINER:u}" == "Y" ]]; then
    info_custom "\n${Yellow}Deleting ${Green}$CONTAINER_NAME"
    docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1
  else
    info_custom "\n${Yellow}Stopping ${Green}$CONTAINER_NAME"
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1
  fi
else
  info_custom "${Green}$CONTAINER_NAME ${White}already exists"
  if [[ -n "$REMOVE_AFTER_FLAG" ]]; then REMOVE_CONTAINER=N; else read_config "Remove container afterwards" REMOVE_CONTAINER N; fi
  if [[ -n "$DELETE_STATE_FLAG" ]]; then REMOVE_STATE_FOLDER=Y; else read_config "Delete OSGi state folder" REMOVE_STATE_FOLDER Y; fi
  if [[ "${REMOVE_STATE_FOLDER:u}" == "Y" ]]; then
    info "Recreating state volume"
    rm -R "$STATE_VOLUME" 2>/dev/null
    mkdir -p "$STATE_VOLUME"
  fi
  info_custom "${Yellow}Starting ${Green}$CONTAINER_NAME"
  docker start -i -a "${CONTAINER_NAME}"
  if [[ "${REMOVE_CONTAINER:u}" == "Y" ]]; then
    info_custom "\n${Yellow}Deleting ${Green}$CONTAINER_NAME"
    docker rm --force "$CONTAINER_NAME" >/dev/null 2>&1
  else
    info_custom "\n${Yellow}Stopping ${Green}$CONTAINER_NAME"
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1
  fi
fi
