#!/bin/bash

SCRIPT_PREFIX="mylvm"
USE_SUDO=0
DESTINATION_FOLDER="$1"
PREFIX="$2"
BACKUP_CONFIG_FILE="$3"

DATE=`date "+%Y%m%d_%H%M%S"`

# Check if root is running the script
# if not, we will attempt using sudo commands
if [ $((UID)) -ne 0 ]; then
       echo "Not running as root, we will attempt to use sudo commands"
       USE_SUDO=1
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

if [ -z "$BACKUP_CONFIG_FILE" ]; then
  echo "Missing master backup configuration file" >&2
  exit 2
fi

#
## Check for valid destination folder
if [ ! -d "$DESTINATION_FOLDER" ]; then
  echo "$DESTINATION_FOLDER is not a valid folder" >&2
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
BACKUP_FILE="$BACKUP_FOLDER"/"$PREFIX"_"$SCRIPT_PREFIX".tar.gz

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
## check if the final archive exists already
if [ -f "$BACKUP_FILE" ]; then
  echo "$BACKUP_FILE already exists - Backup job Cancelled" >&2
  exit 2
fi

#######################
# Binaries
#######################

	if [ -x /usr/sbin/lvs ]; then
		LVCREATE="/usr/sbin/lvcreate"		# to create the snapshot
		LVREMOVE="/usr/sbin/lvremove"		# to remove the snapshot
		VGDISPLAY="/usr/sbin/vgdisplay" 	# to check on the available disk space for the snapshot
		LVDISPLAY="/usr/sbin/lvdisplay" 	# to check on the available disk space for the snapshot
		LVS="/usr/sbin/lvs" 			# to provide a list of detailed info for the VG and LV
	elif [ -x /sbin/lvs ]; then
		LVCREATE="/sbin/lvcreate"		# to create the snapshot
		LVREMOVE="/sbin/lvremove"		# to remove the snapshot
		VGDISPLAY="/sbin/vgdisplay"		# to check on the available disk space for the snapshot
		LVDISPLAY="/sbin/lvdisplay"		# to check on the available disk space for the snapshot
		LVS="/sbin/lvs"				# to provide a list of detailed info for the VG and LV
	else
		echo "LVM Not found, please ensure it is installed" >&2
		exit 2
	fi

	MOUNT="/bin/mount"			# to mount the lv
	UMOUNT="/bin/umount"			# to unmount the lv
	MKDIR="/bin/mkdir"			# to make a directory requiring root (sudo) permissions
	TAR="/bin/tar"				# to buid the backup file
	MYSQL="/usr/bin/mysql"			# to perform required locks on the DBs
	CHOWN="/bin/chown"			# to change ownership of backup files

	SUDO="/usr/bin/sudo"			# when running as ncbackup user, to manipulate LVM

####################### 
# MySQL Details
#######################

	if [ ! -s "$MYLVM_MYSQL_CREDS" ]; then
		echo "Invalid MySQL credential files: $MYLVM_MYSQL_CREDS" >&2
		exit 1
	fi
	
	EXEC_MYSQL="$MYSQL --defaults-extra-file=$MYLVM_MYSQL_CREDS"


################################################
# Checks
################################################

# Check for binaries
binary_check() {
	if [ -z "$1" ]; then
		echo "missing argument" >&2
		exit 1
	fi
	if [ ! -e "$1" -o ! -x "$1" ]; then
		echo "'$1' is not a valid binary, please correct the binary definition" >&2
		exit 1
	fi
}

binary_check $LVCREATE
binary_check $LVREMOVE
binary_check $VGDISPLAY
binary_check $LVDISPLAY
binary_check $LVS
binary_check $MYSQL
binary_check $MOUNT
binary_check $UMOUNT
binary_check $MKDIR
binary_check $TAR


#######################################
# Make binaries use sudo, when true
#######################################

if [ $USE_SUDO ]; then
        LVCREATE="$SUDO $LVCREATE"
	LVREMOVE="$SUDO $LVREMOVE"
	VGDISPLAY="$SUDO $VGDISPLAY"
	LVDISPLAY="$SUDO $LVDISPLAY"
	LVS="$SUDO $LVS"
        MOUNT="$SUDO $MOUNT"
        UMOUNT="$SUDO $UMOUNT"
	MKDIR="$SUDO $MKDIR"
	TAR="$SUDO $TAR"
fi


######################
# LVM Details
######################

	# Define the snapshot details
	SNAP_NAME=mysql_snap_$DATE
	if [ ! -d "$SNAP_MOUNT" ]; then
		$MKDIR -p $SNAP_MOUNT
		if [ $? -ne 0 ]; then
			echo "Impossible to create snapshot mount point: $SNAP_MOUNT" >&2
			exit 1
		fi
	fi


#
## check the variables are properly set

if [ -z "$MY_VG" ]; then
	echo "Missing volume groupe (VG) - please configure MY_VG" >&2
	exit 1
fi
if [ -z "$MY_LV" ]; then
	echo "Missing logical volume (LV) - please configure MY_LV" >&2
	exit 1
fi
if [ -z "$MY_LV_DATADIR" ]; then
	echo "Missing mysql datadir - please configure MY_LV_DATADIR" >&2
	exit 1
fi
if [ -z "$SNAP_SIZE" ]; then
	echo "Snapshot size is NOT properly defined - please reconfigure SNAP_SIZE" >&2
	exit 1
fi
if [ -z "$SNAP_MOUNT" ]; then
	echo "Snapshot mount point is NOT properly defined - please reconfigure SNAP_MOUNT" >&2
	exit 1
fi

################
## Check LVM
################

	# check if the variables exist in the system
	# only 1 line output if not existing
	VG_EXIST=`$VGDISPLAY $MY_VG | wc -l`
	if [ ! $((VG_EXIST)) -gt 2 ]; then
		echo "$MY_VG is not a valid Volume Group" >&2
		echo "Select one of the following :" >&2
		echo >&2
		$VGDISPLAY -s >&2
		echo >&2
		exit 1
	fi

	# only 1 line output if not existing
	LV_EXIST=`$LVDISPLAY /dev/$MY_VG/$MY_LV | wc -l`	
	if [ ! $((LV_EXIST)) -gt 2 ]; then
		echo "$MY_LV is not a valid Logical Volume in $MY_VG Volume Group" >&2
		echo "Select one of the following :" >&2
		echo >&2
		$LVS >&2
		echo >&2
		exit 1
	fi
	

# We create the snapshot from within the mysql prompt in order to keep the table lock enabled
# by default the table lock either get released when the connection closed or when the unlock tables
# is provided
SQL_SNAP="
\! echo '---- Flushing tables ----'
FLUSH TABLES;
\! echo 
\! echo '---- Flushing tables with read lock ----'
FLUSH TABLES WITH READ LOCK; 
\! echo
\! echo '---- Flushing logs ----'
FLUSH LOGS;
\! echo
\! echo '---- Show master status ----' 
SHOW MASTER STATUS;
\! echo
\! echo '---- Show slave status ----'
SHOW SLAVE STATUS \G
\! echo
\! echo '---- Creating LVM snapshot ----'
\! echo '  -> $LVCREATE --snapshot --size=$SNAP_SIZE --name $SNAP_NAME /dev/$MY_VG/$MY_LV'
\! $LVCREATE --snapshot --size=$SNAP_SIZE --name $SNAP_NAME /dev/$MY_VG/$MY_LV
\! echo
\! echo '---- Unlocking tables ----'
UNLOCK TABLES;
\! echo
"

SQL_SNAP_LOG=/tmp/sql_snap_$DATE.log

logger "$DATE - `basename $0` | MySQL LVM Backup startup" 

#
## perform lock and snapshot creation
echo "Starting MySQL flush with read lock and LVM snapshot..."
	# Export environment variable to suppress warning during lvm snapshot 
	export LVM_SUPPRESS_FD_WARNINGS
	date_lock_start=`date "+%s"`
	# we use "tee" to save the output in a file and still display the messages in stdout
	echo "$SQL_SNAP" | $EXEC_MYSQL | tee $SQL_SNAP_LOG
	date_lock_end=`date "+%s"`

	date_lock_length=$((date_lock_end-date_lock_start))
	# Unset environment variable 
	unset LVM_SUPPRESS_FD_WARNINGS
echo "Ending MySQL flush with read lock and LVM snapshot."
echo "  -- lock length: $date_lock_length seconds --" | tee -a $SQL_SNAP_LOG
echo 

#
## mount snapshot
echo "Mounting LVM snapshot..."
	$MOUNT /dev/$MY_VG/$SNAP_NAME $SNAP_MOUNT
	if [ $? -ne 0 ]; then
		echo "Mount error !" >&2
		exit 1
	else
		echo "Mounted."
		echo
	fi

cd /

SOURCE_FOLDER="$SNAP_MOUNT/$MY_LV_DATADIR $SQL_SNAP_LOG $MYLVM_EXTRA_DATA"

#
## prepare a list of folders stripped from their leading / char
for folder in ${SOURCE_FOLDER}
do
  STRIPPED_SOURCE_FOLDER="${folder:1} $STRIPPED_SOURCE_FOLDER"
done

#
## backup in tar.gz file
echo "Starting Tar archive of MySQL data + config file + log files"
	date_tar_start=`date "+%s"`

	$TAR czCf / $BACKUP_FILE $STRIPPED_SOURCE_FOLDER
	if [ $USE_SUDO ]; then
		$SUDO $CHOWN ncbackup:ncbackup $BACKUP_FILE
	fi

	date_tar_end=`date "+%s"`

	date_tar_length=$((date_tar_end-date_tar_start))
echo "Ending Tar archive."
echo "  -- tar length: $date_tar_length seconds" 
echo

#
## umount snapshot
cd ..
echo "Unmounting LVM snapshot..."
	$UMOUNT $SNAP_MOUNT
	if [ $? -ne 0 ]; then
        echo "Unmount error !" >&2
		exit 1
	else
		echo "Unmounted."
		echo
	fi

#
## delete snapshot -- don't ask for confirmation
echo "Removing LVM snapshot..."
	$LVREMOVE -f /dev/$MY_VG/$SNAP_NAME
	if [ $? -ne 0 ]; then
		echo "LVM remove error !" >&2
		exit 1
	else
		echo "LVM snapshot removed."
		echo
	fi

# if we reach that point we have completed the backup with success !
logger "$DATE - `basename $0` | LVM MySQL Backup complete"

