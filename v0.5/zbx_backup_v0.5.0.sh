#!/usr/bin/env bash

#
# This script can help you to create backup of simple Zabbix instance.
# It makes tar archives of config and scripts directories. Also it makes MySQL backup with
# Percona Xtrabackup utility (innobackupex) whitch you should install yourself.
# After all it makes compressed archive contains all collected data using gzip, bzip2 or xz.
# After a few tests I reccomend to use lbzip2. It makes archive faster, but almost
# two times bigger than xz. Gzip it fine too, but as bzip2, rather slow (in my case).
#
VERSION="0.5.0"

### Static setttings ###
# Working directories and files
DEST=/mnt/nfs/shv-mon01			# Where we should  store final archive
TMP=/var/tmp/zbx_backup			# Where to store temp MySQL backup, before it will be compress
ROTATION=10				# How many copies we should store. Set to 0, if you needn't rotation.
LOGFILE=$DEST/backuplog.log		# Logfile location
TIMESTAMP=`date +%d.%m.%Y.%H%M%S`	# Current timestamp
ZBX_FILES_TAR=$TMP/zbx_files_$TIMESTAMP.tar
MYSQLDUMP=/usr/bin/mysqldump
INNOBACKUPEX=/usr/bin/innobackupex
ZBX_CATALOGS=("/usr/lib/zabbix" "/etc/zabbix")
### END Static settings ###

# Checking TEMP directory
if ! [[ -d $TMP ]]
then
	mkdir -p $TMP
fi

# The function just print help message
function PrintHelpMessage() {
echo "
zbx_backup, version: $VERSION
(c) Khatsayuk Alexander, 2017
Usage:
-c|--compress-with	- gzip|bzip2|lbzip2|pbzip2|xz
-i|--use-innobackupex	- will use 'innobackupex' utility to backup database
-m|--use-mysqldump	- will use 'mysqldump' utility to backup database
-d|--db-only		- backing up database only without Zabbix config files etc
-u|--db-user		- username for zabbix database
-p|--db-password	- password for database user
-n|--db-name		- database name ('zabbix' by default)
-h|--help		- print this help message
-v|--version		- print version number

Examples:
# Making backup of Zabbix database and config files with innobackupex. compress it with lbzip2.
zbx_backup --compress-with lbzip2 --use-innobackupex --db-user root --db-password P@ssw0rd
# Making backup of Zabbix database and config files with innobackupex. compress it with lbzip2.
zbx_backup --compress-with gzip --use-mysqldump --db-user zabbix --db-password zabbix --db-name zabbix_database
# Making backup of Zabbix database only and compress it with xz utility.
zbx_backup --compress-with xz --db-only -u root -p P@ssw0rd
"
exit 0
}

# Parsing given arguments
if [[ $# -eq 0 ]]
then
	echo "Syntax error! Please, provide some arguments. Use '--help' to view examples."
	exit 1
fi

# Ooh, it makes me mad. I've almost get it, but my pythoted brain refuses constructions like this. %)
while [[ $# -gt 0 ]]
do
	ARG="$1"
	case "$ARG" in
		"-c"|"--compress-with")
			USE_COMPRESSION="YES"
			case "$2" in
				"gzip"|"bzip2"|"xz"|"lbzip2"|"pbzip2")
					COMPRESS_WITH=$2
					;;
				*)
					echo "Syntax error: [-c|--compress-with] gzip|bzip2|xz|lbzip2|pbzip2"
					exit 1
					;;
			esac
			shift
			shift
			;;
		"-i"|"--use-innobackupex")
			USE_INNOBACKUPEX="YES"
			shift
			;;
		"-m"|"--use-mysqldump")
			USE_MYSQLDUMP="YES"
			shift
			;;
		"-d"|"--db-only")
			DB_ONLY="YES"
			shift
			;;
		"-u"|"--db-user")
			DB_USER=$2
			shift
			shift
			;;
		"-p"|"--db-password")
			DB_PASS=$2
			if [[ -f $DB_PASS ]]
			then
				DB_PASS=`cat $DB_PASS`
			fi
			shift
			shift
			;;
		"-n"|"--db-name")
			DB_NAME=$2
			shift
			shift
			;;
		"-h"|"--help")
			PrintHelpMessage
			;;
		"-v"|"--version")
			echo $VERSION
			exit 0
			;;
		"--debug")
			DEBUG="YES"
			shift
			;;
		*)
			echo "Syntax error! Please, use '--help' to view correct usage examples."
			exit 1
			;;
	esac
done

# If user didn't set db name, using default name (zabbix)
if ! [[ $DB_NAME ]]
then
	DB_NAME='zabbix'
fi


# We cannot use both '-m' and '-i' options, so breaks here
if [[ $USE_INNOBACKUPEX == "YES" ]] && [[ $USE_MYSQLDUMP == "YES" ]]
then
	echo "ERROR: You cannot use '-m' and '-i' options together!"
	exit 1
# Also we should use at least one of them
elif [[ $USE_INNOBACKUPEX != "YES" ]] && [[ $USE_MYSQLDUMP != "YES" ]] && [[ $DB_ONLY != "YES" ]]
then
	echo "ERROR: You must specify at least one database backup utility. Use '--help' to learn how."
	exit 1
fi

# Check if username and password provided by user
if [[ ${#DB_USER} == 0 ]] || [[ ${#DB_PASS} == 0 ]]
then
	echo "ERROR: You must provide both username and password and database '$DB_NAME'. Use '--help' to learn how."
	exit 1
fi

# The function makes all backup operations
function BackingUp() {
	# If '--db-only' option not set
	if [[ $DB_ONLY != "YES" ]]
	then
		ZBX_FILES_TAR=$TMP/zbx_files_$TIMESTAMP.tar
		# Making initial files tar archive
		tar cf $ZBX_FILES_TAR ${ZBX_CATALOGS[0]}
	
		# Add all other catalogs in $ZBX_CATALOGS array to initial tar archive
		if [[ -f $ZBX_FILES_TAR ]]
		then
			for (( i=1; i < ${#ZBX_CATALOGS[@]}; i++ ))
			do
				tar -rf $ZBX_FILES_TAR ${ZBX_CATALOGS[$i]}
			done
		else
			echo "ERROR: Cannot create TAR archive with zabbix data files."
			exit 1
		fi
	fi

	# Check last exit code
	if [[ $? -ne 0 ]]
	then
		echo "ERROR: Cannot create $ZBX_FILES_TAR" >> $LOGFILE
		return 1
	fi
	
	# Backing up database
	# If we want to use mysqldump to backup database
	if [[ $USE_MYSQLDUMP == "YES" ]]
	then
		DB_BACKUP_DST=$TMP/zbx_db_dump_$TIMESTAMP.sql
		if [[ -f $MYSQLDUMP ]]
		then
			$MYSQLDUMP -u$DB_USER -p$DB_PASS --databases $DB_NAME > $DB_BACKUP_DST
		else
			echo "ERROR: 'mysqldump' utility not found ($MYSQLDUMP)."
			exit 1
		fi
	# If we want to use innobackupex to backup database
	elif [[ $USE_INNOBACKUPEX = "YES" ]]
	then
		DB_BACKUP_DST=$TMP/zbx_mysql_files_$TIMESTAMP
		if [[ -f $INNOBACKUPEX ]]
		then
			$INNOBACKUPEX --user=$DB_USER --password=$DB_PASS --no-timestamp --parallel=4 $DB_BACKUP_DST
			$INNOBACKUPEX --apply-log --no-timestamp $DB_BACKUP_DST
		else
			echo "ERROR: Cannot find 'innobackupex' utility ($INNOBACKUPEX)."
			exit 1
		fi
	fi

	# Chech last exit code
	if [[ $? -ne 0 ]]
	then
		echo "ERROR: Cannot create database backup" >> $LOGFILE
		return 1
	fi
}

# The function cleans $TMP directory
function TmpClean() {
	if [[ -d $TMP  ]]
	then
		rm -rf $TMP/zbx_*
	else
		echo "WARNING: Cannot clean TMP directory ($TMP)." >> $LOGFILE
	fi
}

# The function making rotation of old backup files
function RotateOldCopies() {
	# Getting old copies list and it's count
	OLD_COPIES=(`ls -1t $DEST/zbx_backup_*`)
	COUNT=${#old_copies[@]}

	if [[ $COUNT -gt $ROTATION ]] && [[ $ROTATION -ne 0 ]]
	then
		for OLD_COPY in ${OLD_COPIES[@]:$ROTATION}
		do
			if [[ -f $OLD_COPY ]]
			then
				rm -f $OLD_COPY
			else
				echo "WARNING: Something was wrong while deleting $OLD_COPY" >> $LOGFILE
			fi
		done
	else
		echo "INFO: We have less or equal $ROTATION old copies: $COUNT. Do nothing..." >> $LOGFILE
	fi
}

if [[ $DEBUG == "YES" ]]
then
	function join { local IFS="$1"; shift; echo "$*"; }

	printf "%-20s : %-25s\n" "Database name" $DB_NAME
	printf "%-20s : %-25s\n" "Database user" $DB_USER
	printf "%-20s : %-25s\n" "Database password" $DB_PASS
	printf "%-20s : %-25s\n" "Use compression" $USE_COMPRESSION
	printf "%-20s : %-25s\n" "Compression utility" $COMPRESS_WITH
	printf "%-20s : %-25s\n" "Old copies count" $ROTATION
	printf "%-20s : %-25s\n" "Logfile location" $LOGFILE
	printf "%-20s : %-25s\n" "Temp directory" $TMP
	printf "%-20s : %-25s\n" "Dinal fistination" $DEST
	printf "%-20s : %-30s\n" "Zabbix catalogs" `join ', ' ${ZBX_CATALOGS[@]}`
		
	if [[ $USE_MYSQLDUMP == "YES" ]]
	then			
		printf "%-20s : %-25s\n" "Use mysqldump" $USE_MYSQLDUMP
	else
		printf "%-20s : %-25s\n" "Use mysqldump" "NO"
	fi
	if [[ $USE_INNOBACKUPEX == "YES" ]]
	then		
		printf "%-20s : %-25s\n" "Use innobackupex" $USE_INNOBACKUPEX
	else
		printf "%-20s : %-25s\n" "Use innobackupex" "NO"
	fi
	exit 0
fi

# Cleaning TMP and Running backup operations
TmpClean && BackingUp

# Checking last exit code for backup function
if [[ $? -ne 0 ]]
then
	echo "ERROR: Backup operation hasn't finished correctly. Look into log file to find posible reason ($LOGFILE)." 
	exit 1
fi

# Compressing if resulted files exists
if [[ $USE_COMPRESSION == "YES" ]]
then
	case $COMPRESS_WITH in
		"gzip")
			EXT="gz"
			;;
		"bzip2"|"lbzip2"|"pbzip2")
			EXT="bz2"
			;;
		"xz")
			EXT="xz"
			;;
	esac
	FULL_ARC="zbx_backup_$TIMESTAMP.tar.$EXT"
	if [[ $DB_ONLY == "YES" ]]
	then
		tar cf $FULL_ARC -I $COMPRESS_WITH $DB_BACKUP_DST
	elif [[ -f $ZBX_FILES_TAR ]]
	then
		tar cf $FULL_ARC -I $COMPRESS_WITH $ZBX_FILES_TAR $DB_BACKUP_DST
	fi
else
	FULL_ARC="zbx_backup_$TIMESTAMP.tar"
	if [[ $DB_ONLY == "YES" ]]
	then
		tar cf $FULL_ARC $DB_BACKUP_DST
	elif [[ -f $ZBX_FILES_TAR ]]
	then
		tar cf $FULL_ARC $ZBX_FILES_TAR $DB_BACKUP_DST
	fi
fi

# Cleaning temp files and run rotation
TmpClean && RotateOldCopies

# Cheking and logging results
if [[ -f $FULL_ARC ]]
then
	echo "SUCCESS: Backup date: $TIMESTAMP" >> $LOGFILE
	exit 0
else
	echo "ERROR: Backup wasn't created on $TIMESTAMP" >> $LOGFILE
	exit 1
fi

exit $?
