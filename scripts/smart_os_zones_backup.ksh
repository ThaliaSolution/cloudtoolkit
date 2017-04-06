#!/usr/bin/ksh

# Version 1.2
#    This file is part of Thalia CloudToolkit.
#
#    Thalia CloudToolkit is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    Thalia CloudToolkit is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.

#    You should have received a copy of the GNU General Public License
#    along with Thalia CloudToolkit.  If not, see <http://www.gnu.org/licenses/>.
    
CURDATE=`date '+%Y%m%d-%H%M%S'`
SCRIPTNAME=$0

HOTBACKUP=$1

#Config 
#	0: off		1: on	
NOREBOOT=0				# Keep VM shutdown after backup; not effective if HOTBACKUP set active (used for migration or other purpose...)
DELETESNAPSHOT=1		# Delete the ZFS snapshot after exporting the backup
HOTBACKUP_DEFAULT=0		# Do not shutdown the VM before backup (RISKY if enabled but no system interuption)
BACKUP_ONLY_RUNNING=0	# ONLY backup "running" VMs

BKPDIR=/opt/bkzn/backups
TMPDIR=/opt/bkzn/tmp
LOGDIR=/opt/bkzn/log
BKDATE=$(date '+%y%m%d_%H%M%S')


#removing trailing /
BKPDIR=${BKPDIR%/}
TMPDIR=${TMPDIR%/}
LOGDIR=${LOGDIR%/}

CURPWD=`pwd`
CURSCRIPT=${0##*/}

LOGFILE="${LOGDIR}/${CURSCRIPT%.*}-${CURDATE}.log"

function logIt {
	echo $*
	echo $* >> "$LOGFILE" 
}

function ZFSSNAP {
	ZSNPUUID=${1}
	ZSNPNAME=${2}
	
	logIt 'I' "\tZFSSNAP taking the ZFS snapshot..."	
	zfs snapshot zones/${ZSNPUUID}@${ZSNPNAME} 1>>"$LOGFILE" 2>&1
	err_code=$?
	if [[ $err_code -eq 0 ]]; then
		logIt 'I' "\tZFSSNAP returned ok status"
	else
		logIt 'E' "\tZFSSNAP returned bad status [err_code: ${err_code}]"
	fi
}

function ZFSEXPORT {
	ZEXPUUID=${1}
	ZEXPNAME=${2}
	ZEXPBDIR=${3}
	
	logIt 'I' "\tZFSEXPORT export ZFS snapshot... ('zfs send' function)"
	zfs send -p zones/${ZEXPUUID}@${ZEXPNAME} > ${ZEXPBDIR}/${ZEXPUUID}.zfs 2>>"$LOGFILE"
	err_code=$?
	if [[ $err_code -eq 0 ]]; then
		logIt 'I' "\tZFSEXPORT returned ok status, ${ZEXPBDIR}/${ZEXPUUID}.zfs created succesfuly"
	else
		logIt 'E' "\tZFSEXPORT returned bad status [err_code: ${err_code}]"
	fi
}

function ZFSDELSNAP {
	if [[ DELETESNAPSHOT -eq 1 ]]; then
		ZDELSNPUUID=${1}
		ZDELSNPNAME=${2}
		
		logIt 'I' "\tZFSDELSNAP deleting ZFS snapshot... ('zfs destroy' function)"	
		zfs destroy zones/${ZSNPUUID}@${ZSNPNAME} 1>>"$LOGFILE" 2>&1
		err_code=$?
		if [[ $err_code -eq 0 ]]; then
			logIt 'I' "\tZFSDELSNAP returned ok status"
		else
			logIt 'E' "\tZFSDELSNAP returned bad status [err_code: ${err_code}]"
		fi
	else
		logIt 'I' "\tThe snapshot is kept (as config set)"
	fi
}

logIt 'I' "Backup process start timestamp: "`date '+%y%m%d_%H%M%S'`
logIt 'I' "    Backup ID: ${}"

#Create required directories if not already exist
[[ ! -d $BKPDIR ]] && mkdir -p $BKPDIR
[[ ! -d $TMPDIR ]] && mkdir -p $TMPDIR
[[ ! -d $LOGDIR ]] && mkdir -p $LOGDIR

#enable autofs service
svcadm enable autofs

[[ -z $HOTBACKUP ]] && HOTBACKUP=$HOTBACKUP_DEFAULT

SNAPNAME="snap-${BKDATE}"

cd "$BKPDIR"

vmadm list >>"$LOGFILE" 

vmadm list -p -o uuid,alias,state |
while IFS=':' read UUID VMNAME VSTATE; do
	logIt 'I' "Backuping ${VMNAME}... (${VSTATE})"	
	
	VMBKDIR="${BKPDIR}/${VMNAME}_${CURDATE}"

	[[ -d $VMBKDIR ]] || mkdir $VMBKDIR
	
	case $VSTATE in
		'running')
			logIt 'I' "\t${VMNAME} is running"
			if [[ $HOTBACKUP -eq 0 ]]; then
				logIt 'I' "HOTBACKUP disabled, shutdowning the VM before backup"
				
				vmadm stop ${UUID}
				err_code=$?
				if [[ $err_code -eq 0 ]]; then
					logIt 'I' "\t${VMNAME} shutdown... Ok\n"
				else
					logIt 'E' "\t${VMNAME} shutdown... FAIL\n"
					logIt 'I' "\t${VMNAME} Performing an hot ZFS backup (anyway...)\n"
				fi
				
				logIt 'I' "ZFS backup start"
				ZFSSNAP ${UUID} ${SNAPNAME}
				ZFSEXPORT ${UUID} ${SNAPNAME} ${VMBKDIR}
				ZFSDELSNAP ${UUID} ${SNAPNAME}
				
				if [[ $NOREBOOT -eq 0 ]]; then
					vmadm start ${UUID}
				else
					logIt 'I' "NOREBOOT enabled, VM not restarted..."
				fi
			else
				logIt 'I' "HOTBACKUP enabled, performing an hot ZFS backup"
				
				ZFSSNAP ${UUID} ${SNAPNAME}
				ZFSEXPORT ${UUID} ${SNAPNAME} ${VMBKDIR}
				ZFSDELSNAP ${UUID} ${SNAPNAME}
				
			fi
			
		'stopped')
			if [[ $BACKUP_ONLY_RUNNING -eq 1 ]]; then
				logIt 'I' "\t${VMNAME} wasn't running BACKUP_ONLY_RUNNING is enabled : no action"
			else
				logIt 'I' "\t${VMNAME} wasn't running, backup ZFS start"
				
				ZFSSNAP ${UUID} ${SNAPNAME}
				ZFSEXPORT ${UUID} ${SNAPNAME} ${VMBKDIR}
				ZFSDELSNAP ${UUID} ${SNAPNAME}
			fi
			;;
		*)
			if [[ $BACKUP_ONLY_RUNNING -eq 1 ]]; then
				logIt 'W' "\t${VMNAME} is at an unknown state (${VSTATE}), please validate"
				logIt 'I' "\t${VMNAME} wasn't running BACKUP_ONLY_RUNNING is enabled : no action"
			else
				logIt 'W' "\t${VMNAME} is at an unknown state (${VSTATE}), please validate"
				logIt 'I' "\t${VMNAME} wasn't running, backup ZFS start anyway..."
				
				ZFSSNAP ${UUID} ${SNAPNAME}
				ZFSEXPORT ${UUID} ${SNAPNAME} ${VMBKDIR}
				ZFSDELSNAP ${UUID} ${SNAPNAME}
			fi
			;;
	esac
	
	### JSON ###
	logIt 'I' "\t${VMNAME} copy JSON file..."
	vmadm get ${UUID} > ${VMBKDIR}/${UUID}.json  2>>"$LOGFILE"
	err_code=$?
	if [[ $err_code -eq 0 ]]; then
		logIt 'I' "\t${VMNAME} copy JSON file... Ok\n"
	else
		logIt 'E' "\t${VMNAME} copy JSON file... FAIL\n"
	fi
	
	### XML ###
	logIt 'I' "\t${VMNAME} copy XML file..."
	VMXML="/etc/zones/${UUID}.xml"
	
	if [[ -r /etc/zones/${UUID}.xml ]]; then
		cp $VMXML "${VMBKDIR}" 2>>"$LOGFILE"
	else
		logIt 'E' "\tcan't find xml : $VMXML"
	fi
	
	logIt 'I' "\t${VMNAME} compress and package backup..."
	tar cvfz "${VMNAME}_${CURDATE}".tgz "${VMNAME}_${CURDATE}" 1>>"$LOGFILE" 2>&1
	err_code=$?
	if [[ $err_code -eq 0 ]]; then
		logIt 'I' "\t${VMNAME} tar creation success, removing work-files..."
		rm -rf "${VMNAME}_${CURDATE}"
	else
		logIt 'E' "Problem while trying to compress directory: ${VMNAME}_${CURDATE}"
	fi
	
done


vmadm list >>"$LOGFILE" 

logIt 'I' "Backup process end timestamp: "`date '+%y%m%d_%H%M%S'`
logIt 'I' "Error count during backup: "`grep " E " "$LOGFILE" | wc -l`
logIt 'I' "Warning count during backup: "`grep " W " "$LOGFILE" | wc -l`


