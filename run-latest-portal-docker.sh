#!/bin/zsh

# Colors
Color_Off='\033[0m' # Text Reset
Green='\033[0;32m'  # Green (Regular)
Yellow='\033[0;33m' # Yellow (Regular)
White='\033[0;37m'  # White (Regular)
BYellow='\033[1;33m' # Yellow (Bold)

info() {
  if [[ -n $* ]]; then
    echo -e "${Yellow}$1${Color_Off}"
  fi
}

info_custom() {
  if [[ -n $* ]]; then
    echo -e "$1${Color_Off}"
  fi
}

read_config() {
  if [[ -n $* ]]; then
    local ANSWER
    echo -n -e "${White}$1 [${Green}$3${White}]: ${Color_Off}"
    read -r ANSWER
    eval "$2=${ANSWER:-$3}"
  fi
}

read_input() {
  if [[ -n $* ]]; then
    local ANSWER
    echo -n -e "${White}$1: ${Color_Off}"
    read -r ANSWER
    eval "$2=${ANSWER}"
  fi
}

read_password() {
  if [[ -n $* ]]; then
    local ANSWER
    echo -n -e "${White}$1: ${Color_Off}"
    read -rs ANSWER
    echo -e ""
    eval "$2=${ANSWER}"
  fi
}

IMAGE_NAME=liferay/dxp

# Liferay CE uses the same images as DXP but only LTS releases
LIFERAY_TAG_DEFAULT=$(
  curl -s 'https://hub.docker.com/v2/repositories/liferay/dxp/tags?page_size=2048&name=-lts&ordering=name' |
  jq -r --arg year "$(date +%Y)" '
    .results[].name
    | select(startswith($year))
    | select(test("^[0-9]{4}\\.q[0-9]+\\.[0-9]+-lts$"))
  ' | sort -V | tail -n1
)

if [[ -z "$LIFERAY_TAG_DEFAULT" ]]; then
  LIFERAY_TAG_DEFAULT=$(
    curl -s 'https://hub.docker.com/v2/repositories/liferay/dxp/tags?page_size=2048&name=-lts&ordering=name' |
    jq -r '
      .results[].name
      | select(test("^[0-9]{4}\\.q[0-9]+\\.[0-9]+-lts$"))
    ' | sort -V | tail -n1
  )
fi

if [[ -z "$LIFERAY_TAG_DEFAULT" ]]; then
  info_custom "${Yellow}Could not auto-detect an -lts Docker tag. Please enter one manually."
fi

read_config "Enter Liferay Docker Tag" LIFERAY_TAG "$LIFERAY_TAG_DEFAULT"

LIFERAY_ROOT_DEFAULT=./${LIFERAY_TAG}
read_config "Liferay Root" LIFERAY_ROOT "$LIFERAY_ROOT_DEFAULT"

CONTAINER_NAME=$(echo "$LIFERAY_ROOT" | sed -e 's:.*/::' -e 's/[\.]/-/g')

LIFRAY_IMAGE_TAG=$IMAGE_NAME:$LIFERAY_TAG

if ! [[ "$LIFERAY_ROOT" =~ ^(\.\/|\/).+$ ]]; then
  LIFERAY_ROOT=./$LIFERAY_ROOT
fi

DEPLOY_VOLUME=$LIFERAY_ROOT/deploy
DATA_VOLUME=$LIFERAY_ROOT/data
SCRIPT_VOLUME=$LIFERAY_ROOT/scripts
FILES_VOLUME=$LIFERAY_ROOT/files
CX_VOLUME=$LIFERAY_ROOT/osgi/client-extensions
OSGI_STATE_VOLUME=$LIFERAY_ROOT/osgi/state
OSGI_CONFIGS_VOLUME=$LIFERAY_ROOT/osgi/configs

info_custom "${Yellow}Deploy folder: ${BYellow}$DEPLOY_VOLUME"
info_custom "${Yellow}Data folder: ${BYellow}$DATA_VOLUME"
info_custom "${Yellow}Scripts folder: ${BYellow}$SCRIPT_VOLUME"
info_custom "${Yellow}Files folder: ${BYellow}$FILES_VOLUME"
info_custom "${Yellow}Client Extension folder: ${BYellow}$CX_VOLUME"
info_custom "${Yellow}OSGi state folder: ${BYellow}$OSGI_STATE_VOLUME"
info_custom "${Yellow}OSGi configs folder: ${BYellow}$OSGI_CONFIGS_VOLUME"

docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1

if [ $? -eq 1 ]; then
  info_custom "${Green}$CONTAINER_NAME ${White}does not exist"
  REMOVE_CONTAINER_DEFAULT=Y
  read_config "Remove container afterwards" REMOVE_CONTAINER $REMOVE_CONTAINER_DEFAULT

  USE_HYPERSONIC_DEFAULT=N
  read_config "Use Hypersonic database" USE_HYPERSONIC $USE_HYPERSONIC_DEFAULT

  if [[ "${USE_HYPERSONIC:u}" == "N" ]]; then
    LIFERAY_DATABASE_DEFAULT=postgresql
    read_config "Liferay Root - postgresql or mysql" LIFERAY_DATABASE $LIFERAY_DATABASE_DEFAULT

    if [[ "${LIFERAY_DATABASE:l}" == "postgresql" || "${LIFERAY_DATABASE:l}" == "mysql" ]]; then
      DATABASE_NAME=${CONTAINER_NAME/-//}
      if [[ "${LIFERAY_DATABASE:l}" == "postgresql" ]]; then
        JDBC_CLASS=org.postgresql.Driver
        JDBC_CONNECTTION=$LIFERAY_DATABASE://host.docker.internal:5432/${DATABASE_NAME}

        read_input "Username" JDBC_USERNAME

        if psql -lqt | cut -d \| -f 1 | grep -qw "${DATABASE_NAME}" >/dev/null 2>&1; then
          RECREATE_DATABASE_DEFAULT=N
          read_config "Recreate database" RECREATE_DATABASE $RECREATE_DATABASE_DEFAULT

          if [[ "${RECREATE_DATABASE:u}" == "Y" ]]; then
            info_custom "${Yellow}Deleting PostgreSQL database: ${BYellow}${DATABASE_NAME}"
            eval "dropdb -f ${DATABASE_NAME} >/dev/null 2>&1"

            info_custom "${Yellow}Creating PostgreSQL database: ${BYellow}${DATABASE_NAME}"
            eval "createdb -h localhost -p 5432 -U ${JDBC_USERNAME} -O ${JDBC_USERNAME} ${DATABASE_NAME} >/dev/null 2>&1"
          fi
        else
          info_custom "${Yellow}Creating PostgreSQL database: ${BYellow}${DATABASE_NAME}"
          eval "createdb -h localhost -p 5432 -U ${JDBC_USERNAME} -O ${JDBC_USERNAME} ${DATABASE_NAME} >/dev/null 2>&1"
        fi
      else
        JDBC_CLASS=com.mysql.cj.jdbc.Driver
        JDBC_CONNECTTION=$LIFERAY_DATABASE://host.docker.internal:3306/${DATABASE_NAME}

        read_input "Username" JDBC_USERNAME
        read_password "Password" JDBC_PASSWORD

        if mysql -u "$JDBC_USERNAME" -p"$JDBC_PASSWORD" -e "use ${DATABASE_NAME}" >/dev/null 2>&1; then
          RECREATE_DATABASE_DEFAULT=N
          read_config "Recreate database" RECREATE_DATABASE $RECREATE_DATABASE_DEFAULT

          if [[ "${RECREATE_DATABASE:u}" == "Y" ]]; then
            info_custom "${Yellow}Deleting MySQL database: ${BYellow}${DATABASE_NAME}"
            eval "mysql -u $JDBC_USERNAME -p$JDBC_PASSWORD -e \"drop database ${DATABASE_NAME};\" >/dev/null 2>&1"

            info_custom "${Yellow}Creating MySQL database: ${BYellow}${DATABASE_NAME}"
            eval "mysql -u $JDBC_USERNAME -p$JDBC_PASSWORD -e \"create database ${DATABASE_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\" >/dev/null 2>&1"
          fi
        else
          info_custom "${Yellow}Creating MySQL database: ${BYellow}${DATABASE_NAME}"
          eval "mysql -u $JDBC_USERNAME -p$JDBC_PASSWORD -e \"create database ${DATABASE_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\" >/dev/null 2>&1"
        fi
      fi

      JDBC_CLASS=jdbc.default.driverClassName=$JDBC_CLASS
      JDBC_CONNECTTION=jdbc.default.url=jdbc:$JDBC_CONNECTTION
      JDBC_USERNAME=jdbc.default.username=$JDBC_USERNAME
      if ! [ -z ${JDBC_PASSWORD+x} ]; then
        JDBC_PASSWORD=jdbc.default.password=$JDBC_PASSWORD
      fi
    else
      USE_HYPERSONIC="Y"
    fi
  fi

  USE_HOST_NETWORK_DEFAULT=N
  read_config "Use host network" USE_HOST_NETWORK $USE_HOST_NETWORK_DEFAULT

  DISABLE_ZIP64_EXTRA_FIELD_VALIDATION_DEFAULT=N
  read_config "Disable ZIP64 Extra Field Validation" DISABLE_ZIP64_EXTRA_FIELD_VALIDATION $DISABLE_ZIP64_EXTRA_FIELD_VALIDATION_DEFAULT

  LOCAL_PORT_DEFAULT=8080
  read_config "Local Port" LOCAL_PORT $LOCAL_PORT_DEFAULT

  if [[ ! -d $LIFERAY_ROOT ]]; then
    info "${Yellow}Creating ${BYellow}volume ${Yellow}folders"
    mkdir -p "$DEPLOY_VOLUME"
    mkdir "$DATA_VOLUME"
    mkdir -p "$CX_VOLUME"
    mkdir -p "$OSGI_STATE_VOLUME"
    mkdir -p "$OSGI_CONFIGS_VOLUME" && cp ./7.4-common/*.config "$OSGI_CONFIGS_VOLUME"/
    mkdir -p "$FILES_VOLUME" && cp ./7.4-common/*.properties "$FILES_VOLUME"
    mkdir -p "$SCRIPT_VOLUME"
  fi

  if [[ "${USE_HYPERSONIC:u}" == "N" ]]; then
    if ! grep -q "jdbc.default.driverClassName" "${FILES_VOLUME}/portal-ext.properties"; then
      info_custom "${Yellow}Updating ${BYellow}portal-ext.properties"
      {
         echo -e "\n" 
         echo -e "$JDBC_CLASS"
         echo -e "$JDBC_CONNECTTION"
         echo -e "$JDBC_USERNAME"
      } >> "${FILES_VOLUME}"/portal-ext.properties
      if ! [[ -z ${JDBC_PASSWORD+x} ]]; then
        echo -e "$JDBC_PASSWORD" >> "${FILES_VOLUME}"/portal-ext.properties
      fi
    fi
  fi

  if [[ "${DISABLE_ZIP64_EXTRA_FIELD_VALIDATION:u}" == "Y" ]]; then
    DISABLE_ZIP64_FLAG="-e LIFERAY_JVM_OPTS=-Djdk.util.zip.disableZip64ExtraFieldValidation=true"
  fi

  if [[ "${USE_HOST_NETWORK:u}" == "Y" ]]; then
    NETWORK_HOST=--network=host
  fi

  info_custom "${Yellow}Creating ${BYellow}$CONTAINER_NAME ${Yellow}with ${BYellow}$LIFRAY_IMAGE_TAG"
  docker pull "$LIFRAY_IMAGE_TAG" | grep "Status: " | awk 'NF>1{print $NF}' | xargs -I{} docker create -it ${NETWORK_HOST} --name ${CONTAINER_NAME} -p ${LOCAL_PORT}:8080 ${DISABLE_ZIP64_FLAG} -v ${FILES_VOLUME}:/mnt/liferay/files -v ${SCRIPT_VOLUME}:/mnt/liferay/scripts -v ${OSGI_STATE_VOLUME}:/opt/liferay/osgi/state -v ${OSGI_CONFIGS_VOLUME}:/opt/liferay/osgi/configs -v ${DATA_VOLUME}:/opt/liferay/data -v ${DEPLOY_VOLUME}:/mnt/liferay/deploy -v ${CX_VOLUME}:/opt/liferay/osgi/client-extensions {}
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

  REMOVE_CONTAINER_DEFAULT=N
  read_config "Remove container afterwards" REMOVE_CONTAINER $REMOVE_CONTAINER_DEFAULT

  REMOVE_STATE_FOLDER_DEFAULT=Y
  read_config "Delete OSGi state folder" REMOVE_STATE_FOLDER $REMOVE_STATE_FOLDER_DEFAULT

  if [[ "${REMOVE_STATE_FOLDER:u}" == "Y" ]]; then
    info "Recreating OSGi state volume"
    rm -R "$OSGI_STATE_VOLUME"
    mkdir -p "$OSGI_STATE_VOLUME"
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
