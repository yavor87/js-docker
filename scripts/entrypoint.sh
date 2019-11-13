#!/bin/bash

# Copyright (c) 2019. TIBCO Software Inc.
# This file is subject to the license terms contained
# in the license file that is distributed with this file.

# This script sets up and runs JasperReports Server on container start.
# Default "run" command, set in Dockerfile, executes run_jasperserver.
# If webapps/jasperserver does not exist, run_jasperserver 
# redeploys webapp. If "jasperserver" database does not exist,
# run_jasperserver redeploys minimal database.
# Additional "init" only calls init_database, which will try to recreate 
# database and fail if DB exists.

# Sets script to fail if any command fails.
set -e

BUILDOMATIC_HOME=${BUILDOMATIC_HOME:-/usr/src/jasperreports-server/buildomatic}
MOUNTS_HOME=${MOUNTS_HOME:-/usr/local/share/jasperserver}

initialize_deploy_properties() {
  # If environment is not set, uses default values for postgres
  DB_TYPE=${DB_TYPE:-postgresql}
  DB_USER=${DB_USER:-postgres}
  DB_PASSWORD=${DB_PASSWORD:-postgres}
  DB_HOST=${DB_HOST:-postgres}
  DB_NAME=${DB_NAME:-jasperserver}

  # Default_master.properties. Modify according to
  # JasperReports Server documentation.
  cat >${BUILDOMATIC_HOME}/default_master.properties\
<<-_EOL_
appServerType=tomcat
appServerDir=$CATALINA_HOME
dbType=$DB_TYPE
dbHost=$DB_HOST
dbUsername=$DB_USER
dbPassword=$DB_PASSWORD
js.dbName=$DB_NAME
foodmart.dbName=foodmart
sugarcrm.dbName=sugarcrm
webAppName=jasperserver
_EOL_

  # set the JDBC_DRIVER_VERSION if it is passed in.
  # Otherwise rely on the default maven.jdbc.version from the dbType
  if [ ! -z "$JDBC_DRIVER_VERSION" ]; then
    cat >> ${BUILDOMATIC_HOME}/default_master.properties\
<<-_EOL_
maven.jdbc.version=$JDBC_DRIVER_VERSION
_EOL_
  elif [ "$DB_TYPE" = "postgresql" ]; then
    POSTGRES_JDBC_DRIVER_VERSION=${POSTGRES_JDBC_DRIVER_VERSION:-42.2.5}
    cat >> ${BUILDOMATIC_HOME}/default_master.properties\
<<-_EOL_
maven.jdbc.version=$POSTGRES_JDBC_DRIVER_VERSION
_EOL_
  fi

  # set the DB_PORT if it is passed in.
  # Otherwise rely on the default port from the dbType
  if [ ! -z "$DB_PORT" ]; then
    cat >> ${BUILDOMATIC_HOME}/default_master.properties\
<<-_EOL_
dbPort=$DB_PORT
_EOL_
  fi
  
  JRS_DEPLOY_CUSTOMIZATION=${JRS_DEPLOY_CUSTOMIZATION:-${MOUNTS_HOME}/deploy-customization}

  if [[ -f "$JRS_DEPLOY_CUSTOMIZATION/default_master_additional.properties" ]]; then
    # note that because these properties are at the end of the properties file
	# they will have precedence over the ones created above
    cat $JRS_DEPLOY_CUSTOMIZATION/default_master_additional.properties >> ${BUILDOMATIC_HOME}/default_master.properties
  fi
}

setup_jasperserver() {

  # execute buildomatic js-ant targets for installing/configuring
  # JasperReports Server.
  
  cd ${BUILDOMATIC_HOME}/
  
  for i in $@; do
    # Default buildomatic deploy-webapp-pro target attempts to remove
    # $CATALINA_HOME/webapps/jasperserver path.
    # This behaviour does not work if mounted volumes are used.
    # Using unzip to populate webapp directory and non-destructive
    # targets for configuration
    if [ $i == "deploy-webapp-ce" ]; then
      ./js-ant \
        set-ce-webapp-name \
        deploy-webapp-datasource-configs \
        deploy-jdbc-jar \
        -DwarTargetDir=$CATALINA_HOME/webapps/jasperserver
    else
      # warTargetDir webaAppName are set as
      # workaround for database configuration regeneration
      ./js-ant $i \
        -DwarTargetDir=$CATALINA_HOME/webapps/jasperserver
    fi
  done
}

run_jasperserver() {
  init_databases
  
  # Because default_master.properties could change on any launch,
  # always do deploy-webapp-pro.

  setup_jasperserver deploy-webapp-ce

  # setup phantomjs
  config_phantomjs

  # Apply customization zips if present
  apply_customizations

  # If JRS_HTTPS_ONLY is set, sets JasperReports Server to
  # run only in HTTPS. Update keystore and password if given
  config_ports_and_ssl

  # Set Java options for Tomcat.
  # using G1GC - default Java GC in later versions of Java 8
  
  # setting heap based on info:
  # https://medium.com/adorsys/jvm-memory-settings-in-a-container-environment-64b0840e1d9e 
  # https://stackoverflow.com/questions/49854237/is-xxmaxramfraction-1-safe-for-production-in-a-containered-environment
  # https://www.oracle.com/technetwork/java/javase/8u191-relnotes-5032181.html
  
  # Assuming we are using a Java 8 version beyond 8u191, we can use the Java 10+ JAVA_OPTS
  # for containers
  # Assuming a minimum of 3GB for the container => a max of 2.4GB for heap
  # defaults to 33/3% Min, 80% Max
  
  JAVA_MIN_RAM_PCT=${JAVA_MIN_RAM_PERCENTAGE:-33.3}
  JAVA_MAX_RAM_PCT=${JAVA_MAX_RAM_PERCENTAGE:-80.0}
  JAVA_OPTS="$JAVA_OPTS -XX:-UseContainerSupport -XX:MinRAMPercentage=$JAVA_MIN_RAM_PCT -XX:MaxRAMPercentage=$JAVA_MAX_RAM_PCT"
  
  echo "JAVA_OPTS = $JAVA_OPTS"
  # start tomcat
  exec env JAVA_OPTS="$JAVA_OPTS" catalina.sh run
}

# tests connection to the configured repo database.
# could fail altogether, be missing the database or succeed
# do-install-upgrade-test does 2 connections
# - database specific admin database
# - js.dbName
# at least one attempt has to work to indicate the host is accessible
try_database_connection() {
  sawJRSDBName=false
  sawConnectionOK=0
      
  cd ${BUILDOMATIC_HOME}/

  while read -r line
  do
	if [ -z "$line" ]; then
	  #echo "blank line"
	  continue
	fi
	# on subsequent tries, show the output
    if [ $1 -gt 1 ]; then
      echo $line
	fi
	if [[ $line == *"$DB_NAME"* ]]; then
	  sawJRSDBName=true
	elif [[ $line == *"Connection OK"* ]]; then
	  sawConnectionOK=$((sawConnectionOK + 1))
	fi
  done < <(./js-ant do-install-upgrade-test)

  if [ "$sawConnectionOK" -lt 1 ]; then
	echo "##### Failing! ##### Saw $sawConnectionOK OK connections, not at least 1"
    retval="fail"
  elif [ "$sawJRSDBName" = "false" ]; then
    retval="missing"
  else
    retval="OK"
  fi
}

test_database_connection() {
	# Retry 5 times to check PostgreSQL is accessible.
	for retry in {1..5}; do
	  try_database_connection $retry
	  #echo "test_connection returned $retval"
	  if [ "$retval" = "OK" -o "$retval" = "missing" ]; then
		echo "$DB_TYPE at host ${DB_HOST} accepting connections and logging in"
		break
	  elif [[ $retry = 5 ]]; then
		echo "$DB_TYPE at host ${DB_HOST} not accessible or cannot log in!"
		echo "##### Exiting #####"
		exit 1
	  else
		echo "Sleeping to try $DB_TYPE at host ${DB_HOST} connection again..." && sleep 15
	  fi
	done
}


# tests for jasperserver, foodmart and sugarcrm databases
# and creates them
init_databases() {

  test_database_connection
  
  badConnection=false
  
  sawJRSDBName="notyet"
  sawFoodmartDBName="notyet"
  sawSugarCRMDBName="notyet"
  
  sawConnectionOK=0
  
  currentDatabase=""
  
  cd ${BUILDOMATIC_HOME}/
  
  while read -r line
  do
	if [ -z "$line" ]; then
	  #echo "blank line"
	  continue
	fi
	if [[ $line == *"$DB_NAME"* ]]; then
	  currentDatabase=$DB_NAME
	elif [[ $line == *"foodmart"* ]]; then
	  currentDatabase=foodmart
	elif [[ $line == *"sugarcrm"* ]]; then
	  currentDatabase=sugarcrm
	elif [[ $line == *"Database doesn"* ]]; then
		case "$currentDatabase" in
		  $DB_NAME )
			sawJRSDBName="no"
			;;
		  foodmart )
			sawFoodmartDBName="no"
			;;
		  sugarcrm )
			sawSugarCRMDBName="no"
			;;
		  *)
		esac
	elif [[ $line == *"Connection OK"* ]]; then
		case "$currentDatabase" in
		  $DB_NAME )
			sawJRSDBName="yes"
			;;
		  foodmart )
			sawFoodmartDBName="yes"
			;;
		  sugarcrm )
			sawSugarCRMDBName="yes"
			;;
		  *)
		esac
	    sawConnectionOK=$((sawConnectionOK + 1))
	fi
  done < <(./js-ant do-pre-install-test)
  
  if [ "$sawConnectionOK" -lt 1 ]; then
	echo "##### Exiting! ##### saw $sawConnectionOK OK connections, not at least 1"
    exit 1
  fi
  
  echo "Database init status: $DB_NAME : $sawJRSDBName foodmart: $sawFoodmartDBName  sugarcrm $sawSugarCRMDBName"
  if [ "$sawJRSDBName" = "no" ]; then
    echo "Initializing $DB_NAME repository database"
 	setup_jasperserver set-ce-webapp-name create-js-db init-js-db-ce import-minimal-ce
  
	JRS_LOAD_SAMPLES=${JRS_LOAD_SAMPLES:-false}
	  
	# Only install the samples if explicitly requested
	if [ "$1" = "samples" -o "$JRS_LOAD_SAMPLES" = "true" ]; then
		echo "Samples load requested"
		# if foodmart database not present - setup database
		if [ "$sawFoodmartDBName" = "no" ]; then
			setup_jasperserver create-foodmart-db \
							load-foodmart-db \
							update-foodmart-db
		fi

		# if sugarcrm database not present - setup database
		if [ "$sawSugarCRMDBName" = "no" ]; then
			setup_jasperserver create-sugarcrm-db \
							load-sugarcrm-db 
		fi

		setup_jasperserver import-sample-data-ce
	fi
  else
    echo "$DB_NAME repository database already exists: not creating and loading"
  fi
}

config_phantomjs() {
  # if phantomjs binary is present, update JasperReports Server config.
  if [[ -x "/usr/local/bin/phantomjs" ]]; then
    PATH_PHANTOM='\/usr\/local\/bin\/phantomjs'
    PATTERN1='com.jaspersoft.jasperreports'
    PATTERN2='phantomjs.executable.path'
    cd $CATALINA_HOME/webapps/jasperserver/WEB-INF
    sed -i -r "s/(.*)($PATTERN1.highcharts.$PATTERN2=)(.*)/\2$PATH_PHANTOM/" \
      classes/jasperreports.properties
    sed -i -r "s/(.*)($PATTERN1.fusion.$PATTERN2=)(.*)/\2$PATH_PHANTOM/" \
      classes/jasperreports.properties
    sed -i -r "s/(.*)(phantomjs.binary=)(.*)/\2$PATH_PHANTOM/" \
      js.config.properties
  elif [[ "$(ls -A /usr/local/share/phantomjs)" ]]; then
    echo "Warning: /usr/local/bin/phantomjs is not executable, \
but /usr/local/share/phantomjs exists. PhantomJS \
is not correctly configured."
  fi
}

config_ports_and_ssl() {
  #
  # pushing Tomcat to run on HTTP_PORT and HTTPS_PORT
  echo "Tomcat to run on HTTP on ${HTTP_PORT} and HTTPS on ${HTTPS_PORT}"
  sed -i "s/port=\"[0-9]\+\" protocol=\"HTTP\/1.1\"/port=\"${HTTP_PORT}\" protocol=\"HTTP\/1.1\"/" $CATALINA_HOME/conf/server.xml
  sed -i "s/redirectPort=\"[0-9]\+\"/redirectPort=\"${HTTPS_PORT}\"/" $CATALINA_HOME/conf/server.xml

  # if $JRS_HTTPS_ONLY is set in environment to true, disable HTTP support
  # in JasperReports Server.
  JRS_HTTPS_ONLY=${JRS_HTTPS_ONLY:-false}

  if "$JRS_HTTPS_ONLY" = "true" ; then
    echo "Setting HTTPS only within JasperReports Server"
    cd $CATALINA_HOME/webapps/jasperserver/WEB-INF
    xmlstarlet ed --inplace \
      -N x="http://java.sun.com/xml/ns/j2ee" -u \
      "//x:security-constraint/x:user-data-constraint/x:transport-guarantee"\
      -v "CONFIDENTIAL" web.xml
    sed -i "s/=http:\/\//=https:\/\//g" js.quartz.properties
    sed -i "s/8080/${HTTPS_PORT:-8443}/g" js.quartz.properties
  else
    echo "NOT! Setting HTTPS only within JasperReports Server. Should actually turn it off, but cannot."
  fi

  KEYSTORE_PATH=${KEYSTORE_PATH:-${MOUNTS_HOME}/keystore}
  if [ -d "$KEYSTORE_PATH" ]; then
	  echo "Keystore update path $KEYSTORE_PATH"

	  KEYSTORE_PATH_FILES=`find $KEYSTORE_PATH -iname ".keystore*" \
		-exec readlink -f {} \;`
	  
	  # update the keystore and password if there
	  if [[ $KEYSTORE_PATH_FILES -ne 0 ]]; then
		  # will only be one, if at all
		  for keystore in $KEYSTORE_PATH_FILES; do
			if [[ -f "$keystore" ]]; then
			  echo "Deploying Keystore $keystore"
			  cp "${keystore}" /root
			  xmlstarlet ed --inplace --subnode "/Server/Service/Connector[@port='${HTTPS_PORT:-8443}']" --type elem \ 
					--var connector-ssl '$prev' \
				--update '$connector-ssl' --type attr -n port -v "${HTTPS_PORT:-8443}" \
				--update '$connector-ssl' --type attr -n keystoreFile  -v "/root/${keystore}" \
				--update '$connector-ssl' --type attr -n keystorePass  -v "${KS_PASSWORD:-changeit}" \
				${CATALINA_HOME}/conf/server.xml
			  echo "Deployed ${keystore} keystore"
			fi
		  done
	  else
		  # update existing server.xml. could have been overwritten by customization
		  # xmlstarlet ed --inplace --subnode "/Server/Service/Connector[@port='${HTTPS_PORT:-8443}']" --type elem \ 
		  #		--var connector-ssl '$prev' \
		  #	--update '$connector-ssl' --type attr -n port -v "${HTTPS_PORT:-8443}" \
		  #		--update '$connector-ssl' --type attr -n keystorePass  -v "${KS_PASSWORD}" \
		  #		--update '$connector-ssl' --type attr -n keystoreFile  -v "/root/.keystore.p12" \
		  #		${CATALINA_HOME}/conf/server.xml
		  echo "No .keystore files. Did not update SSL"
	  fi

  # end if $KEYSTORE_PATH exists.
  fi

}


apply_customizations() {
  # unpack zips (if exist) from path
  # ${MOUNTS_HOME}/customization
  # to JasperReports Server web application path
  # $CATALINA_HOME/webapps/jasperserver/
  # file sorted with natural sort
  JRS_CUSTOMIZATION=${JRS_CUSTOMIZATION:-${MOUNTS_HOME}/customization}
  if [ -d "$JRS_CUSTOMIZATION" ]; then
	  echo "Deploying Customizations from $JRS_CUSTOMIZATION"

	  JRS_CUSTOMIZATION_FILES=`find $JRS_CUSTOMIZATION -iname "*zip" \
		-exec readlink -f {} \; | sort -V`
	  # find . -path ./lower -prune -o -name "*txt"
	  for customization in $JRS_CUSTOMIZATION_FILES; do
		if [[ -f "$customization" ]]; then
		  echo "Unzipping $customization into JasperReports Server webapp"
		  unzip -o -q "$customization" \
			-d $CATALINA_HOME/webapps/jasperserver/
		fi
	  done
  fi
  
  TOMCAT_CUSTOMIZATION=${TOMCAT_CUSTOMIZATION:-${MOUNTS_HOME}/tomcat-customization}
  if [ -d "$TOMCAT_CUSTOMIZATION" ]; then
	  echo "Deploying Tomcat Customizations from $TOMCAT_CUSTOMIZATION"
	  TOMCAT_CUSTOMIZATION_FILES=`find $TOMCAT_CUSTOMIZATION -iname "*zip" \
		-exec readlink -f {} \; | sort -V`
	  for customization in $TOMCAT_CUSTOMIZATION_FILES; do
		if [[ -f "$customization" ]]; then
			echo "Unzipping $customization into Tomcat"
			unzip -o -q "$customization" \
				-d $CATALINA_HOME
		fi
	  done
	fi
}

import() {

  # not doing app server management during an import
  cat >> ${BUILDOMATIC_HOME}/default_master.properties\
<<-_EOL_
appServerType=skipAppServerCheck
_EOL_

  # Import from the passed in list of volumes
  
  cd ${BUILDOMATIC_HOME}
  
  for volume in $@; do
      # look for import.properties file in the volume
      if [[ -f "$volume/import.properties" ]]; then
        echo "Importing into JasperReports Server from $volume"
      
        # parse import.properties. each uncommented line with contents will have
        # js-import command line parameters
        # see "Importing from the Command Line" in JasperReports Server Admin guide
          
        while read -r line
        do
          line="$(echo -e "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

          if [ -z "$line" -o "${line:0:1}" == "#" ]; then
          #echo "comment line or blank line"
            continue
          fi

          # split up the args
          IFS=' ' read -r -a args <<< "$line"
          command=""
          foundInput=false
          element=""
          for index in "${!args[@]}"
            do
                element="${args[index]}"
                if [ "$element" = "--input-dir" -o "$element" = "--input-zip" ]; then
                  # find the --input-dir or --input-zip values
                  #echo "found $element"
                  foundInput=true
                elif [ "$foundInput" = true ]; then
                  #echo "setting $volume/$element"
                  # update input to include the volume
                  element="$volume/$element"
                  foundInput=false
                fi
                command="$command $element"
            done
            
            echo "Import $command executing"
            echo "========================="

            ./js-import.sh "$command" || echo "Import $command failed"
        done < "$volume/import.properties"
        # rename import.properties to stop accidental re-import
        mv "$volume/import.properties" "$volume/import-done.properties"
      else
        echo "No import.properties file in $volume. Skipping import."
      fi
  done
}


export() {

    # not doing app server management during an export
    cat >> ${BUILDOMATIC_HOME}/default_master.properties\
<<-_EOL_
appServerType=skipAppServerCheck
_EOL_

    # Export from the passed in list of volumes
    
    cd ${BUILDOMATIC_HOME}
    
    for volume in $@; do
        # look for export.properties file in the volume
        if [[ -f "$volume/export.properties" ]]; then
            echo "Exporting into JasperReports Server into $volume"
        
            # parse export.properties. each uncommented line with contents will have
            # js-export command line parameters
            # see "Exporting from the Command Line" in JasperReports Server Admin guide
            
            while read -r line
            do
                line="$(echo -e "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

                if [ -z "$line" -o "${line:0:1}" == "#" ]; then
                    #echo "comment line or blank line"
                    continue
                fi

                # split up the args
                IFS=' ' read -r -a args <<< "$line"
                command=""
                foundInput=false
                element=""

                for index in "${!args[@]}"
                do
                    element="${args[index]}"
                    # find the --output-dir or --output-zip values
                    if [ "$element" = "--output-dir" -o "$element" = "--output-zip" ]; then
                        #echo "found $element"
                        foundInput=true
                    elif [ "$foundInput" = true ]; then
                        # update output name to include the volume
                        element="$volume/$element"
                        foundInput=false
                    fi
                    command="$command $element"
                done
            
                echo "Export $command executing"
                echo "========================="

                ./js-export.sh "$command" || echo "Export $command failed"

            done < "$volume/export.properties"
            # rename export.properties to stop accidental re-export
            mv "$volume/export.properties" "$volume/export-done.properties"
        else
            echo "No export.properties file in $volume. Skipping export."
        fi
    done
}


initialize_deploy_properties

case "$1" in
  run)
    shift 1
    run_jasperserver "$@"
    ;;
  init)
    shift 1
    init_databases "$@"
    ;;
  import)
    shift 1
    import "$@"
    ;;
  export)
    shift 1
    export "$@"
    ;;
  *)
    exec "$@"
esac

