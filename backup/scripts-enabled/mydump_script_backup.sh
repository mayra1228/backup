#!/bin/bash

SCRIPT_PREFIX="mydump"

# Define default extra files to include in the archive
SOURCE_FOLDER=""

################################################
# BINARY Details
################################################
MYSQLDUMP="/usr/bin/mysqldump"
MYSQL="/usr/bin/mysql"

TAR="/bin/tar"
GZIP="/usr/bin/gzip"
SUDO="/usr/bin/sudo"

#
## Check binaries
# MYSQLDUMP
if [ ! -f "$MYSQLDUMP" ]; then
  echo "MYSQLDUMP: $MYSQLDUMP -- binary not found" >&2
  exit 2
fi
if [ ! -x "$MYSQLDUMP" ]; then
  echo "MYSQLDUMP: $MYSQLDUMP -- binary not executable" >&2
  exit 2
fi 

#
## Check binaries
#MYSQL
if [ ! -f "$MYSQL" ]; then
  echo "MYSQL: $MYSQL -- binary not found" >&2
  exit 2
fi
if [ ! -x "$MYSQL" ]; then
  echo "MYSQL: $MYSQL -- binary not executable" >&2
  exit 2
fi 

if [ ! -x "$TAR" ]; then
  echo "TAR: $TAR -- binary not found or not executable" >&2
  exit 2
fi

if [ ! -x "$GZIP" ]; then
  echo "GZIP: $GZIP -- binary not found or not executable" >&2
  exit 2
fi

if [ ! -x "$SUDO" ]; then
  echo "SUDO: $SUDO -- binary not found or not executable" >&2
  exit 2
fi

##################################################
# Manage parameters
##################################################
#
## Save parameters
DESTINATION_FOLDER="$1"
PREFIX="$2"
BACKUP_CONFIG_FILE="$3"

#
## Check for valid destination folder
if [ ! -d "$DESTINATION_FOLDER" ]; then
  echo "$DESTINATION_FOLDER is not a valid folder" >&2
  exit 2
fi

#
## Check parameters
if [ -z "$DESTINATION_FOLDER" ]; then
  echo "Missing destination folder" >&2
  exit 2
fi

if [ -z "$PREFIX" ]; then
  echo "Missing master backup prefix" >&2
  exit 2
fi

#
## Check for valid FULL PATH
if [ ${DESTINATION_FOLDER:0:1} != '/' ]; then
  echo "Need FULL PATH for destination backup folder" >&2
  exit 2
fi

#
## Check for valid configuration file
if [ -f "$BACKUP_CONFIG_FILE" -a -r "$BACKUP_CONFIG_FILE" ]; then 
  source "$BACKUP_CONFIG_FILE"
else
  echo "The master backup config file is not readable" >&2
  echo "$BACKUP_CONFIG_FILE" >&2
  exit 2
fi


#
## File name definition
BACKUP_FOLDER="$DESTINATION_FOLDER"/"$SCRIPT_PREFIX"
BACKUP_FILE="$BACKUP_FOLDER"/"$PREFIX"_"$SCRIPT_PREFIX".sql

#
## check for custom backup folder
if [ ! -d "$BACKUP_FOLDER" ]; then
  mkdir -p "$BACKUP_FOLDER"
  if [ $? -ne 0 ]; then echo "$DESTINATION_FOLDER folder is not writable, check permissions" ; exit 2 ; fi
fi

#
## Check for writable destination
if [ ! -w "$BACKUP_FOLDER" ]; then
  echo "$BACKUP_FOLDER folder is not writable, check permissions" >&2
   echo "current owner UID: $UID" >&2
   echo "current PWD: $PWD" >&2
   echo " user@host:~$ ls -la $BACKUP_FOLDER" >&2
   ls -la "$BACKUP_FOLDER" >&2
  exit 2
fi
  
#
## check if the finale archive exists already
if [ -f "$BACKUP_FILE" ]; then
  echo "$BACKUP_FILE already exists - Backup job Cancelled" >&2
  exit 2
fi


#
## Add backward-compatability with old configuration
if [ -z $MYSQL_INSTANCES ]; then
  MYSQL_INSTANCES[0]="default"
fi

echo "---- Using multi-instance mydump backup for ${#MYSQL_INSTANCES[*]} instances ----"

#
## For each instance (could be just one), perform the backup
for MY_INSTANCE_NAME in ${MYSQL_INSTANCES[*]}; do

  echo "---- Processing instance: $MY_INSTANCE_NAME ----"

  if [ $MY_INSTANCE_NAME == "3306" -o $MY_INSTANCE_NAME == "default" ]; then
    #
    ## Use the default values for single-instance on standard port
    ## This ensures backward-compatability
    ## Example: key/mysql_backup.creds
    MYDUMP_INSTANCE_CREDS_FILE="$MYDUMP_MYSQL_CREDS"

  else
    #
    ## If non-standard port, we must have a special creds file for this instance
    ## Filename configured in conf file, append Instance Port to end
    ## Example: key/mysql_backup.creds.3307
    MYDUMP_INSTANCE_CREDS_FILE="$MYDUMP_MYSQL_CREDS.$MY_INSTANCE_NAME"

  fi

  #
  ## check if the mysql Credentials file exists
  if [ ! -s "$MYDUMP_INSTANCE_CREDS_FILE" ]; then
    echo "Invalid MySQL credential files: $MYDUMP_INSTANCE_CREDS_FILE" >&2
    exit 1
  fi

  #
  ## Setup the executables for this instance
  MYSQLDUMP_AND_CREDS="$MYSQLDUMP --defaults-extra-file=$MYDUMP_INSTANCE_CREDS_FILE"
  MYSQL_AND_CREDS="$MYSQL --defaults-extra-file=$MYDUMP_INSTANCE_CREDS_FILE"

  #
  ## Find the data dir, from the horses mouth
  ## This will be different per-instance - so this is the only reliable way
  MYSQL_DATA_DIR=`$MYSQL_AND_CREDS --skip-column-names --raw --silent -e "SHOW GLOBAL VARIABLES WHERE Variable_name='datadir'" | awk '{print $2}'`

  echo "---- MySQL Instance Data Dir: $MYSQL_DATA_DIR ----";

  ########################################
  # Log Rotate 
  #######################################
  #Define SQL
  SQL="
  \! echo '------------ Flushing logs ----------'
  flush logs;
  \! echo
  \! echo '---- Show master status ----' 
  SHOW MASTER STATUS;
  \! echo
  \! echo '---- Show slave status ----'
  SHOW SLAVE STATUS \G
  \! echo
  "
       $MYSQL_AND_CREDS -e "$SQL" >/dev/null


  #########################################
  # DB backup
  #########################################
  #
  ## backup Database
  for DB_NAME in $($MYSQL_AND_CREDS -e "show databases" | sed '/Database/d' | grep -v "information_schema" | grep -v "performance_schema" | grep -v "sys");
  do
    echo "---- Backing up Instance: $MY_INSTANCE_NAME Database : $DB_NAME ---- "
    if [[ $(echo "USE information_schema; SELECT TABLE_NAME FROM TABLES WHERE TABLE_SCHEMA='$DB_NAME' AND TABLE_TYPE = 'BASE TABLE' AND ENGINE NOT like 'innodb';" | $MYSQL_AND_CREDS --skip-column-names | wc -l) -ne 0 ]]; then
      echo "---- $DB_NAME has MYISAM TABLES , using DUMP backup method ---- "
      $MYSQLDUMP_AND_CREDS --opt --routines --triggers --events --flush-privileges --skip-add-drop-table --dump-date --databases $DB_NAME | $GZIP > "$BACKUP_FOLDER"/"$PREFIX"_"$SCRIPT_PREFIX"_"$MY_INSTANCE_NAME"_"$DB_NAME".sql.gz
    else
      echo "---- $DB_NAME has all InnoDB tables , using InnoDB backup method ---- "
      $MYSQLDUMP_AND_CREDS --opt --routines --triggers --events --flush-privileges --skip-add-drop-table --master-data=2 --single-transaction  --skip-add-locks --skip-lock-tables --dump-date --databases $DB_NAME | $GZIP > "$BACKUP_FOLDER"/"$PREFIX"_"$SCRIPT_PREFIX"_"$MY_INSTANCE_NAME"_"$DB_NAME".sql.gz
    fi
    echo "---- Backup Done ---- ";
  done

  #########################################
  # LOG backup
  #########################################
  #
  ## backup logs

  cd $MYSQL_DATA_DIR

  j=""
          # You might want to checge -newermt $(date +%Y-%m-%d -d '2 day ago') 
          # on old systems to '-ctime -2' for some old systems as -newermt might not be available.
          for i in $(find $MYSQL_DATA_DIR -newermt $(date +%Y-%m-%d -d '2 day ago') -name 'mysql-bin.*' 2>/dev/null)

                  do j="$j $i"
                  done

  $SUDO $TAR czCf / "$BACKUP_FOLDER"/"$PREFIX"_"$SCRIPT_PREFIX"_"$MY_INSTANCE_NAME".bin-log.tar.gz $j


done



## check for FULL PATH only in SOURCE_FOLDER
for folder in ${SOURCE_FOLDER} ${MYDUMP_EXTRA_DATA}
do
  if [ ${folder:0:1} != '/' ]; then
    echo "Need FULL PATH for source backup folders / files" >&2
    exit 2
  fi
done


#
## compress Database and return required format tar.gz
cd "$BACKUP_FOLDER"
echo "Compress file"
#FILE=`basename "$BACKUP_FILE"`
FILE=*.sql.gz
$TAR czf "$BACKUP_FILE".tar.gz $FILE $SOURCE_FOLDER $MYDUMP_EXTRA_DATA --remove-files
echo "Compress Done."; echo

#
## compress Mysql bin-log  and return required format tar.gz
cd "$BACKUP_FOLDER"
echo "Compress file"
#FILE=`basename "$BACKUP_FILE"`
FILE="$PREFIX"_"$SCRIPT_PREFIX"_"$MY_INSTANCE_NAME".bin-log.tar.gz
$TAR czf "$BACKUP_FILE".bin-log.tar.gz $FILE $SOURCE_FOLDER $MYDUMP_EXTRA_DATA --remove-files
echo "Compress Done."; echo


#
## display final archive details
echo "List archive"
ls -la $BACKUP_FOLDER/$PREFIX\_$SCRIPT_PREFIX*
ls -la $SOURCE_FOLDER $MYDUMP_EXTRA_DATA
echo "List Done."; echo

#
## display final archive details
echo "List archive"
ls -la "$BACKUP_FOLDER"
echo "List Details Done."
