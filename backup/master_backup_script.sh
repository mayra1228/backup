#!/bin/bash
logger "Master Backup Script - started..."
################################################
# Master script API for sub-scripts
#
# INPUT:
#  - $1 -- root destination backup folder
#  - $2 -- prefix
#  - $3 -- config file
#
# OUTPUT:
#  - 1 backup archive tar.gz -- Naming Format: PREFIX_XXXXX.tar.gz
#  - STDOUT -- to be appened to mail notice
#  - STDERR -- to be appened to error log for mail notice
################################################
#BINARIES
DATE="/bin/date"
SENDMAIL="/usr/sbin/sendmail"
SSH="/usr/bin/ssh"
SCP="/usr/bin/scp"
MD5="/usr/bin/md5sum"
GPG="/usr/bin/gpg"
S3CMD="/usr/bin/s3cmd"
GPGAGENT="/usr/bin/gpg-agent"
ALICMD="/usr/bin/alicmd"
QINIUCMD="/usr/bin/qiniucmd"
AZURECMD="/usr/bin/azure"
WGET="/usr/bin/wget"

HOME_MASTER="/opt/ops_script/backup"
CONF_FILE="$HOME_MASTER/conf/backup.conf"
DATE_FORMATED=`$DATE "+%y%m%d_%H%M%S"`
HOSTNAME=`hostname`

KEY_PERMS='-r--------' 
KEY_OWNER= 'root'
KEY_GROUP= 'root'
## Check BINARIES
check_binary(){
  binary="$1"
  if [ ! -x $binary ]; then
        echo "$binary - is not executable -- review the configuration" >&2
        exit 2
  fi
}

check_folder(){
  folder="$1"
  # Get the Value of Variable whose name is a Variable
  # e.g: AA=aaa; BB=AA; echo ${!BB} will display 'aaa'
  if [ -z "${!folder}" ]
  then
    echo "$folder: missing value - correct the script" >&2
    exit 2
  else
    # check if the folder exists
    if [ ! -d "${!folder}" ]; then
          # if not creates it
          mkdir -p "${!folder}"
          # if creation fails
      if [ $? -ne 0 ]; then
            echo "permission issue - have not write permission for $folder" >&2
            exit 2
          fi
        fi
  fi
}

## Check that the working environment is properly set
check_work_env (){
  check_binary $DATE
  check_binary $SENDMAIL
  check_binary $MD5

  check_folder HOME_MASTER
  check_folder SCRIPT_FOLDER
  check_folder PID_FOLDER
  check_folder BACKUP_FOLDER
}

set_work_env() {
  ###########################################
  # Define working environment
  SCRIPT_FOLDER="$HOME_MASTER/scripts-enabled"
  PID_FOLDER="$HOME_MASTER/pid"
  DATE_FORMATED=`$DATE "+%y%m%d_%H%M%S"`
  PREFIX_BACKUP="$DATE_FORMATED"_"$HOSTNAME"
  
  ###########################################
  # Define Log
  MASTER_OUTPUT_LOG="$BACKUP_FOLDER"/"$PREFIX_BACKUP"_MASTER_SCRIPT.log
  MASTER_ERROR_LOG="$BACKUP_FOLDER"/"$PREFIX_BACKUP"_MASTER_SCRIPT.error

  ###########################################
  # ENCRYPT configuration section
  # Define Encrypt Key File and owner+permission
  KEY_FILE="$HOME_MASTER/key_file"

  ###########################################
  # Define Check MD5 FILE
  MD5_CHECK_FILE=local_md5_"$DATE_FORMATED"

  ###########################################
  # Define Archive
  FULL_BACKUP_FILE="$BACKUP_FOLDER"/"$PREFIX_BACKUP"_full.tar
  FULL_BACKUP_FILE_GPG="$FULL_BACKUP_FILE".gpg

  ###########################################
  # Define Mail
  MAIL_REPORT_FILE="$BACKUP_FOLDER"/"$PREFIX_BACKUP"_mail_report.txt
}

prepare_work_env() {
  source "$CONF_FILE"
  set_work_env
  check_work_env
  rm -f $PID_FOLDER/*.pid
  # Define whether encryption need to be turned on (Default - enable)
  if [ "$ENABLE_ENCRYPT" == "NO" -o "$ENABLE_ENCRYPT" == "No" -o "$ENABLE_ENCRYPT" == "no"  ]; then
    echo "Encryption of the archive is DISABLED !"
    ENABLE_ENCRYPT="NO"
    FULL_BACKUP_ARCHIVE="$FULL_BACKUP_FILE"
  else
    ENABLE_ENCRYPT="YES"
    FULL_BACKUP_ARCHIVE="$FULL_BACKUP_FILE_GPG"
    check_binary $GPG
  fi
  # Define storage Method (Default - LOCAL)
  if [ "$STORAGE_METHOD" == "SSH" ]; then
    echo "Selected storage method : SSH"
    STORAGE_METHOD="SSH"
    check_binary $SSH
    check_binary $SCP
  fi
}
get_list_jobs() {
  list_scripts=""
  for script in `ls "$SCRIPT_FOLDER"`
  do
    if [ -z "$list_scripts" ]; then
      list_scripts="$SCRIPT_FOLDER/$script"
    else
      list_scripts="$list_scripts $SCRIPT_FOLDER/$script"
    fi
  done

  #
  ## check if there is actually scripts to be ran
  if [ -z "$list_scripts" ]; then
    echo "No scripts available" >&2
    exit 2
  fi

  #
  ## return the script list
  echo "$list_scripts"
}
validate_script() {
  job="$1"
  
  #
  ## Check if the script file exist
  if [ ! -f "$job" ]; then
    echo "$job does not exist - correct the script" >&2
    exit 2
  elif [ ! -x "$job" ]; then
    echo "$job is not executable - check permission" >&2
    exit 2
  fi
}

run_script_bg() {
  job="$1"
  SCRIPT_OUTPUT_LOG="$BACKUP_FOLDER"/"$PREFIX_BACKUP"_"`basename $job`".log
  SCRIPT_ERROR_LOG="$BACKUP_FOLDER"/"$PREFIX_BACKUP"_"`basename $job`".error
  "$job" "$BACKUP_FOLDER" "$PREFIX_BACKUP" "$CONF_FILE" > "$SCRIPT_OUTPUT_LOG" 2> "$SCRIPT_ERROR_LOG" &
  #
  ## store background script PID in the PID folder
  echo $! > "$PID_FOLDER"/`basename $job`.pid
  echo "`basename $job` backup script launched in background"
  logger "Master Backup Script - `basename $job` backup script launched in background"
}
wait_job_bg() {
  for pids in `ls "$PID_FOLDER"/*.pid`
  do
    pids=`basename $pids`
    ## retrieve PID value of the current file
    pid=`cat "$PID_FOLDER"/"$pids"`
    #
    ## while the PID is still present in /proc we wait
    ## the /proc/pid folder will be removed once the background script is complete
    while [ -d /proc/$pid ]
    do
      echo "Jobs not completed yet: `$DATE "+%y%m%d_%H%M%S"`"
      sleep 10
    done
    # remove PID file when backup process stuck , to help investigate in the future
    rm -rf "$PID_FOLDER"/"$pids"
  done
}
create_archive() {
  FILE="$1"
  if [ -z "$FILE" ]; then
    echo "Missing destination backup file" >&2
    exit 2
  fi
  cd "$BACKUP_FOLDER"
  #
  ## retrieve files created with the specified prefix
  file_list=$(find . -name "$PREFIX_BACKUP*tar.gz")
  #
  ## create archive
  if [ "$ENABLE_ENCRYPT" == "YES" ]; then
    echo "Taring sub-scripts archives into FIFO main archive..."
    tar c -O $file_list > "$FILE" & #DL#
    echo "Taring Ready in FIFO file."; echo
  elif [ "$ENABLE_ENCRYPT" == "NO" ]; then
    echo "Taring sub-scripts archives into main archive..."
    tar c -O $file_list | tee "$FILE" | md5sum > "$BACKUP_FOLDER"/"$MD5_CHECK_FILE" & #DL#
	echo "Taring Complete."; echo
  fi
  }
encrypt() {
  FILE="$1"
  FILE_GPG="$2"
  #
  ## check if the parameters exist
  if [ -z "$FILE" ]; then
    echo "encrypt> missing source file" >&2
    exit 2
  fi
  if [ -z "$FILE_GPG" ]; then
    echo "encrypt> missing destination file" >&2
    exit 2
  fi
  #
  ## check for existing and secure key_file
  ## exit if not correct
  check_key_file
  if [ $? -ne 0 ]; then exit 2 ; fi
  mkfifo "$FILE_GPG"
  echo "Encrypting $FILE file..."
  if grep '6.' /etc/redhat-release &>/dev/null; then
    cat "$KEY_FILE" "$FILE" | $GPGAGENT --daemon gpg2 --batch --yes --no-tty --quiet -c --passphrase-fd 0  | tee "$FILE_GPG" | md5sum >"$BACKUP_FOLDER"/"$MD5_CHECK_FILE" & #DL#
  elif grep 'AMI' /etc/issue &>/dev/null; then
    cat "$KEY_FILE" "$FILE" | $GPGAGENT --daemon gpg2 --batch --yes --no-tty --quiet -c --passphrase-fd 0  | tee "$FILE_GPG" | md5sum >"$BACKUP_FOLDER"/"$MD5_CHECK_FILE" & #DX#
  else
    cat "$KEY_FILE" "$FILE" | gpg --no-tty --quiet  -c --passphrase-fd 0 | tee "$FILE_GPG" | md5sum >"$BACKUP_FOLDER"/"$MD5_CHECK_FILE" & #DL#
  fi
  echo "GPG file ready."; echo
}
send_archive_ssh() {
  # set SSH command
  EXEC_REMOTE_SSH="$SSH -i $BACKUP_ID_RSA -p $SSH_PORT $SSH_USER@$BACKUP_SERVER"
  # create remote storage location via SSH
  $EXEC_REMOTE_SSH "mkdir -p $BACKUP_DIR/$HOSTNAME"
  cat "$FULL_BACKUP_ARCHIVE" | $EXEC_REMOTE_SSH "cat > $BACKUP_DIR/$HOSTNAME/$(basename $FULL_BACKUP_ARCHIVE)" #DL#
  # get archive MD5
  MD5_ENC="$(cat $BACKUP_FOLDER/$MD5_CHECK_FILE | awk '{ print $1 }' | sed 's/\ //g')" #DL#
  if [ $? == 0 ]; then
    # get remote MD5 of the transfered file
    REM_MD5=`$EXEC_REMOTE_SSH "md5sum $BACKUP_DIR/$HOSTNAME/$(basename $FULL_BACKUP_ARCHIVE)" | awk '{ print $1 }' | sed 's/\ //g'`
    if [ x"$MD5_ENC" != x"$REM_MD5" ]; then
      echo "TRANSFER FAILED -- remote MD5 differs from local MD5" >&2
      logger "Master Backup Script - WARNING - Remote transfer failed BAD MD5"
    else
      echo "TRANSFER OK -- remote and local MD5 are equal"
    fi
    # list files on the remote server
    echo "File detail on the remote server"
    $EXEC_REMOTE_SSH "ls -la $BACKUP_DIR/$HOSTNAME/$(basename $FULL_BACKUP_ARCHIVE)"

  else
    echo "TRANSFER FAILED -- the archive has not been sent out" >&2
    logger "Master Backup Script - ERROR - Remote transfer failed"
  fi
}
clean_log() {
  for error_file in `ls "$BACKUP_FOLDER"/"$PREFIX_BACKUP"*.error`;
  do
    sed -i '/file changed as we read it/d' $error_file;
    sed -i '/leaked on lvcreate invocation/d' $error_file;
    sed -i '/Removing leading/d' $error_file;
    sed -i '/No medium found/d' $error_file;
    sed -i '/WARNING/d' $error_file
    sed -i '/GTIDs/d' $error_file
    sed -i '/File removed before we read/d' $error_file
  done
}
check_key_file() {
  if [ ! -f "$KEY_FILE" ]; then
    initial_pgp_key_creation
  fi
  #key_file_perms=$(ls -la "$KEY_FILE" | awk {'print $1" "$3" "$4'})
  #if [ x"$key_file_perms" != x"$KEY_PERMS $KEY_OWNER $KEY_GROUP" ]; then
  #  echo "Security breach ! ensure proper passphrase security !" >&2
  #  exit 2
  #fi
  LENGTH=`cat $KEY_FILE`
  if [ ${#LENGTH} -ne 32 ]; then
    echo "Key File is not correct size!" >&2
    exit 2
  fi
}
initial_pgp_key_creation() {
  echo "Creating passphrase..."
  if [ -f "$KEY_FILE" ]; then
    mv "$KEY_FILE" "$KEY_FILE".old
    echo "existing passphrase file renamed to:"
    echo "  $KEY_FILE.old"; echo
    logger "Master Backup Script - WARNING - Old PGP passphrase backup-ed"
  fi
  cat /var/log/* 2> /dev/null | md5sum | awk {'print $1'} > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  echo "Passphrase created."
  logger "Master Backup Script - WARNING - New PGP passphrase generated"
}
send_email () {
  prepare_email_header
  prepare_email_subcontent "$list_jobs"
  cat "$MAIL_REPORT_FILE" | $SENDMAIL $MAIL_REPORT_ADDRESS
}
#########################################
# Email management
#########################################
prepare_email_header () {
  STATUS=0
  # check if the size of all error file in $BACKUP_FOLDER is empty
  for error_file in `ls "$BACKUP_FOLDER"/"$PREFIX_BACKUP"*.error`
  do
    [ -s "$error_file" ] && STATUS=1
  done

  # define the Subject according to the error file size
  [ "$STATUS" -ne 0 ] && BK_STATUS="FAILED" || BK_STATUS="-- OK"

  cat > "$MAIL_REPORT_FILE" << EOF
To: $MAIL_REPORT_ADDRESS
Subject: $BK_STATUS [$HOSTNAME] backup report - $date

EOF
}
prepare_email_subcontent () {
  list_jobs="$1"
  echo "######################################################"    >> "$MAIL_REPORT_FILE"
  echo "Backup Summary:"                                           >> "$MAIL_REPORT_FILE"
  echo "######################################################"    >> "$MAIL_REPORT_FILE"
  echo "-- Logs:"                                                  >> "$MAIL_REPORT_FILE"
  cat "$MASTER_OUTPUT_LOG"                                         >> "$MAIL_REPORT_FILE"
  echo
  if [ -s "$MASTER_ERROR_LOG" ]; then
    echo "-- Errors:"                                              >> "$MAIL_REPORT_FILE"
    cat "$MASTER_ERROR_LOG"                                        >> "$MAIL_REPORT_FILE"
    echo                                                           >> "$MAIL_REPORT_FILE"
  fi
  echo "######################################################"    >> "$MAIL_REPORT_FILE"
  echo                                                             >> "$MAIL_REPORT_FILE"
  echo "Below is the list of each individual backup job:"          >> "$MAIL_REPORT_FILE"
  for job in $list_jobs
  do
    SCRIPT_OUTPUT_LOG="$BACKUP_FOLDER"/"$PREFIX_BACKUP"_"`basename $job`".log
    SCRIPT_ERROR_LOG="$BACKUP_FOLDER"/"$PREFIX_BACKUP"_"`basename $job`".error

    echo "******************************************************"    >> "$MAIL_REPORT_FILE"
    echo "Job: $job"                                                 >> "$MAIL_REPORT_FILE"
    echo "******************************************************"    >> "$MAIL_REPORT_FILE"
    echo "-- Logs:"                                                  >> "$MAIL_REPORT_FILE"
    cat "$SCRIPT_OUTPUT_LOG"                                                                 >> "$MAIL_REPORT_FILE"
    echo                                                             >> "$MAIL_REPORT_FILE"
    #
    ## only display errors if there is error in the file
    ## do not pollute e-mail with it
    if [ -s "$SCRIPT_ERROR_LOG" ]; then
      echo "-- Errors:"                                              >> "$MAIL_REPORT_FILE"
      cat "$SCRIPT_ERROR_LOG"                                                                        >> "$MAIL_REPORT_FILE"
      echo                                                           >> "$MAIL_REPORT_FILE"
    fi
    echo "******************************************************"    >> "$MAIL_REPORT_FILE"
    echo                                                             >> "$MAIL_REPORT_FILE"
  done
}

main() {
  # Judge if lock file exists
  if [ -e $LOCK_FILE ] ; then
        logger "Master Backup Script is running , probably stuck. Please check ! "
        echo "Master Backup Script is running , probably stuck. Please check ! " >&2
        exit 1
  fi
  # create lock file
  touch $LOCK_FILE
  ## retrieve jobs
  list_jobs=`get_list_jobs`
  #
  ##start backup
  echo "`/bin/date | awk '{print $4}'` Starting backup jobs"
  for job in $list_jobs
  do
    validate_script "$job"
    run_script_bg "$job"
  done
  echo "`/bin/date | awk '{print $4}'` Backup jobs running in background"; echo
  #
  ## wait for the jobs to complete
  echo "`/bin/date | awk '{print $4}'` Waiting for backup jobs to complete..."
  wait_job_bg
  echo "`/bin/date | awk '{print $4}'` Backup jobs completed."; echo
  if [ "$STORAGE_METHOD" != "LOCAL" ]; then

    ## create main archive
    echo "`/bin/date | awk '{print $4}'` Preparing main archive..."
    create_archive "$FULL_BACKUP_FILE"
    if [ $? -ne 0 ]; then
      echo "Errors occured during the master archive creation, check logs" >&2
    else
      echo "`/bin/date | awk '{print $4}'` Main archive prepared."; echo
    fi
    #
    ## encrypt archive
    if [ "$ENABLE_ENCRYPT" == "YES" ]; then
      echo "`/bin/date | awk '{print $4}'` Encrypting archive for remote storage..."
      encrypt "$FULL_BACKUP_FILE" "$FULL_BACKUP_FILE_GPG"
      if [ $? -ne 0 ]; then
        echo "Errors occured during the encryption of the master archive, check logs" >&2
      else
        echo "`/bin/date | awk '{print $4}'` Archive encrypted."; echo
      fi
    fi
    # remote storage
    echo "`/bin/date | awk '{print $4}'` Sending archive remotely..."
    send_archive_ssh
    
    if [ $? -ne 0 ]; then
      echo "Errors occured during the remote transfer, check logs" >&2
    else
      echo "`/bin/date | awk '{print $4}'` Archive sent."; echo
    fi
    # cleaning extra files
    echo "`/bin/date | awk '{print $4}'` Cleaning extra files that take space on the server..."
      # remove full archive - keep individual sub-scripts archives
      rm -f "$FULL_BACKUP_ARCHIVE"*
    echo "`/bin/date | awk '{print $4}'` Cleaning completed."
  fi
  logger "Master Backup Script - INFO - operation completed - validate from log "
  # remove Non-standard error logs from error log file
  clean_log
  # remove lock file
  rm -f $LOCK_FILE
}

####################################
# Interactive funtions
####################################

# display version
help() {
  printf "Usage: %s: [-h] [-v] [-i] [-t | -r] [-c config_file] args" $(basename $0)

  echo
  echo "-v | --version                     -- version"
  echo "-i | --init                        -- init script ### NOT READY YET"
  echo "-t | --test                        -- test backup jobs :"
  echo "                                      display output and errors - remote storage - no mail report"
  echo "-r | --run                         -- run backup :"
  echo "                                      full backup + sub-scripts + remote storage + encrypt + email report"
  echo "-c CONFIG_FILE | --config file     -- specify config file"
  echo
}

# get options to play with and define the script behavior
get_options() {
  # init flags
  test_flag=0
  init_script_flag=0
  run_flag=0

  # Note that we use `"$@"' to let each command-line parameter expand to a
  # separate word. The quotes around `$@' are essential!
  # We need TEMP as the `eval set --' would nuke the return value of getopt.

  OPTIONS=`getopt --options hvitrc: \
	   --long help,version,init,test,run,config: \
	   -- "$@"`

  # exit if the options have not properly been gathered
  if [ $? != 0 ] ; then echo "Terminating..." >&2 ; exit 1 ; fi

  # Note the quotes around `$OPTIONS': they are essential!
  eval set -- "$OPTIONS"

  while true ; do
    case "$1" in
      -h|--help) help ; exit ;;
      -v|--version) print_version ; exit ;;
      -i|--init) init_script_flag=1 ; shift ;; # NOT IN USE YET
      -t|--test) test_flag=1 ; shift ;;
      -r|--run) run_flag=1 ; shift ;;
      -c|--config) CONF_FILE=$2 ; shift 2 ;;
      --) shift ; break ;;
      *) echo "Internal error!" ; exit 1 ;;
    esac
  done
}

# get the options entered on the command line
get_options "$@"

# Prepare backup env - source config file - check binaries / paths - clean temp files - etc.
prepare_work_env

# we run the script
if [ $test_flag -eq 1 ]; then
  main
elif [ $run_flag -eq 1 ]; then
  main > "$MASTER_OUTPUT_LOG" 2> "$MASTER_ERROR_LOG"
  echo "Finished." >> "$MASTER_OUTPUT_LOG"
  send_email
else
  help
fi
