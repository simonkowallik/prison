#!/bin/sh
#
# Author: Simon Kowallik <sk simonkowallik.com>
#
# License: GPLv2
#
# Description: prison helps to create a chroot environment.
#	       It is primarly intended to build chroot environments
#	       for SSH/SCP/SFTP "jails" with OpenSSH on Linux.
#	       I use it with OpenSSH 4.9+ together with ChrootDirectory.
#	       It can be used together with rssh or scponly to further
#	       tighten the chroot environment.
#	       It is nothing new, but fullfills the job in the way I wanted.
#
# Download: https://github.com/simonkowallik
#           http://simonkowallik.com
#

#
# Variables which can/should be modified according your needs
#
# This is a list of binaries which will be available in the chroot environment.
# You do not need to specify the full path, but you should if the binary is not
# in the PATH. 
#PROGRAMS="sh groups cp ls mkdir mv rm rmdir id scp"
#PROGRAMS="sh bash groups cp ls mkdir mv rm rmdir id scp"
#PROGRAMS="rssh sh bash groups cp ls mkdir mv rm rmdir id scp"
PROGRAMS="scponly sh bash groups cp ls mkdir mv rm rmdir id scp"
#
#
#
# If you need other files to be copied to the chroot environment,
# specify them in this variable. Use the full path.
OTHER_FILES=""
#OTHER_FILES="/etc/rssh.conf"




# perform basic checks
# if checks fail, this script cannot run

# required tools to run this script
DEPS="find expr diff id ldd mkdir chmod chown mknod dirname cp"

# check path
if [ -z "$PATH" ] ; then 
  PATH=/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/usr/local/sbin
fi

# check if which binary exists
which --version > /dev/null 2>&1
if [ $? -ne 0 ]; then
  echo "ERROR: 'which' binary is required but not installed or not in PATH."
  exit 1
fi
# check if all required tools are available
for dep in $DEPS; do
  which $dep > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    echo "ERROR: '$dep' binary is required but not installed or not in PATH."
    exit 1
  fi
done
# root privileges required
if [ `id -u` -ne 0 ]; then
  echo "ERROR: you need to be root/have uid 0 to use $0."
  exit 1
fi

# print usage
function print_usage() {
echo "Usage: $0 ACTION PARAMETER

Actions:
    -c, --create PRISON 	    	   create a new prison.
    					   creates a new chroot environment.
					   devices, binaries, their libraries
					   and base system files are copied.

    -u, --update PRISON 		   update an existing prison.
    					   update will check for changes on the
					   base system and copy new libraries
					   and binary versions to the prison.
					   you can keep the chroot environment
					   up-to-date with this command.

    -a, --adduser USERNAME SHELL PRISON	   add a new user to prison.
					   adduser will add an existing user
					   from the base system to the chroot
					   environment. it will NOT add the
					   user to the base system itself.
					   it will only update passwd, shadow
					   and group file in PRISON/etc

    -d, --deluser USERNAME PRISON	   delete a user from prison.
    					   deluser will delete a user from
					   the chroot environment. it will
					   NOT delete the user from the base
					   system.

Parameters:
    PRISON		prison directory. specify full path like: /var/prison
    USERNAME		username. user must exist on the system (/etc/passwd)
    SHELL		user login shell in prison. for example: /bin/bash
"
  exit 0
}

# create the base prison layout
function f_create_prison_base() {
 echo -n "Create Prison Base Layout: "
 # create base directory 
 if [ -e $OPT_PRISON ]; then
   if [ ! -d $OPT_PRISON ]; then
     echo "ERROR: '$OPT_PRISON' exists and is not a directory."
     exit 1
   fi
   echo "WARNING: Prison Directory '$OPT_PRISON' already exists."
   read -p "Do you want to continue creating the Prison? (yes/no): " DECISION
   if [ "$DECISION" != "yes" ]; then
     echo "Exiting.."
     exit 0
   fi
 else
   mkdir -p $OPT_PRISON
   if [ $? -ne 0 ]; then
     echo "ERROR: Could not create Prison Directory '$OPT_PRISON'."
     exit 1
   fi
 fi
 chmod 0755 $OPT_PRISON
 chown root.root $OPT_PRISON
 # create lib directory & symlink (lib & lib64)
 if [ -h /lib ] && [ ! -h /lib64 ] && [ -d /lib64 ]; then
   mkdir -p $OPT_PRISON/lib64
   cd $OPT_PRISON; ln -s lib64 lib
 fi
 # create directories
 DIRS="dev etc"
 for dir in $DIRS; do
   if [ ! -d $OPT_PRISON/$dir ]; then
     mkdir -p $OPT_PRISON/$dir
     chmod 0755 $OPT_PRISON/$dir
     chown root.root $OPT_PRISON/$dir
   fi
 done
 # create passwd/shadow/group
 if [ ! -r $OPT_PRISON/etc/passwd ]; then
   grep "^root" /etc/passwd > $OPT_PRISON/etc/passwd
   chmod 0644 $OPT_PRISON/etc/passwd
 fi
 if [ ! -r $OPT_PRISON/etc/shadow ]; then
   echo "root::::::::" > $OPT_PRISON/etc/shadow
   chmod 0640 $OPT_PRISON/etc/shadow
 fi
 if [ ! -r $OPT_PRISON/etc/group ]; then
   grep "^root" /etc/group > $OPT_PRISON/etc/group
   grp_users="`grep '^users' /etc/group | cut -d: -f1,2,3`"
   echo "$grp_users:" >> $OPT_PRISON/etc/group
   chmod 0644 $OPT_PRISON/etc/group
 fi
 echo "done"
} #end:f_create_prison_base

# create /dev/* in prision
function f_create_devices() {
 echo -n "Create Devices: "
 # create devices
 if [ ! -r $OPT_PRISON/dev/tty ]; then
   mknod -m 666 $OPT_PRISON/dev/tty c 5 0
 fi
 if [ ! -r $OPT_PRISON/dev/null ]; then
   mknod -m 666 $OPT_PRISON/dev/null c 1 3
 fi
 if [ ! -r $OPT_PRISON/dev/zero ]; then
   mknod -m 666 $OPT_PRISON/dev/zero c 1 5
 fi
 if [ ! -r $OPT_PRISON/dev/urandom ]; then 
   mknod $OPT_PRISON/dev/urandom c 1 9
 fi
 echo "done"
} #end:f_create_devices

# copy all binaries and libraries into prison
function f_copy_binlib() {
 echo -n "Copy all Programs and Libraries to Prison: "
 for bin in $PROGRAMS;  do
   # if binary is/does not executable/exist, try to find it with which
   # if not successful, continue with next binary.
   if [ ! -x $bin ]; then
     bin_tmp=`which $bin 2>/dev/null`
     if [ $? -eq 0 ] && [ "`dirname $bin`" == "." ]; then
       echo "INFO: Binary '$bin' was found at: '$bin_tmp'"
       bin=$bin_tmp
     elif [ $? -eq 0 ]; then
       echo -n "WARNING: Binary '$bin' not executable or"
       echo " does not exist. Using Binary with same name: '$bin_tmp'"
       bin=$bin_tmp
     else
       echo -n "WARNING: Binary '$bin' not executable,"
       echo " does not exist or could not be found in PATH. Not copying..."
       continue
     fi
   fi
   bin_path=`dirname $bin`

   # if dir does not exist in PRISON, create it
   if [ ! -d $OPT_PRISON/$bin_path ]; then
     mkdir -p $OPT_PRISON/$bin_path
   fi

   # copy the binary into PRISON
   # if in update mode, check if it differs before updating
   if [ "$OPT_ACTION" == "update" ]; then
     diff -q $bin $OPT_PRISON/$bin >/dev/null 2>&1
     if [ $? -gt 0 ]; then
       cp -f -p $bin $OPT_PRISON/$bin
     fi
   else
     cp -f -p $bin $OPT_PRISON/$bin
   fi

   # process libs from binary
   for lib in `ldd $bin`; do
     # if lib starts with /, we found a library
     if [ "${lib:0:1}" == "/" ]; then
       # extract the path
       lib_path=`dirname $lib`

       # if dir does not exist in PRISON, create it
       if [ ! -d $OPT_PRISON/$lib_path ]; then
         mkdir -p $OPT_PRISON/$lib_path
       fi

       # copy the library into PRISON
       # if in update mode, check if it differs before updating
       if [ "$OPT_ACTION" == "update" ]; then
         diff -q $lib $OPT_PRISON/$lib >/dev/null 2>&1
         if [ $? -gt 0 ]; then
           cp -f $lib $OPT_PRISON/$lib
         fi
       else
         cp -f $lib $OPT_PRISON/$lib
       fi
     fi
   #for lib  
   done
 done
 echo "done"
} #end:f_copy_binlib()

# copy other files to prison
function f_copy_other_files() {
 echo -n "Copy other files to Prison: "
 for other_file in $OTHER_FILES; do
   # if source file exists and differs or does not exist in PRISON, copy it
   # if in create mode, copy it without checking if it differs
   if [ -f $other_file ] && [ "$OPT_ACTION" == "update" ]; then
     diff -q $other_file $OPT_PRISON/$other_file >/dev/null 2>&1
     if [ $? -gt 0 ]; then
       file_path=`dirname $other_file`
       if [ ! -d $OPT_PRISON/$file_path ]; then
         mkdir -p $OPT_PRISON/$file_path
       fi
       cp -f $other_file $OPT_PRISON/$other_file
     fi
   else
     cp -f $other_file $OPT_PRISON/$other_file
   fi
 done
 echo "done"
} #end:f_copy_other_files

# copy libraries which may be needed but where not found by ldd
function f_copy_invisiblelibs() {
 echo -n "Copy base Libraries to Prison: "

 # list of libs - all versions of these libs will be copied
 LIBS="libnss_compat.so* libnss_files.so* libnsl.so* libcap.so*"

 # process each lib, find its location(s) and copy it to PRISON
 for lib in $LIBS; do
   for lib_file in `find /lib* -name $lib`; do
     # extract the path
     lib_path=`dirname $lib_file`

     # if mode ist update, check if files differ
     if [ "$OPT_ACTION" == "update" ]; then
       diff -q $lib_file $OPT_PRISON/$lib_file >/dev/null 2>&1
       if [ $? -gt 0 ]; then
         # if dir does not exist in PRISON, create it
         if [ ! -d $OPT_PRISON/$lib_path ]; then
           mkdir -p $OPT_PRISON/$lib_path
         fi
         # copy lib to prison
         cp -f $lib_file $OPT_PRISON/$lib_file
       fi
     else
       if [ ! -d $OPT_PRISON/$lib_path ]; then
         mkdir -p $OPT_PRISON/$lib_path
       fi
       # copy lib to prison
       cp -f $lib_file $OPT_PRISON/$lib_file
     fi
   done
 done
 echo "done"
} #end:f_copy_invisiblelibs

# add user to prison
function f_add_user() {
 # check if user exists
 id $OPT_USER >/dev/null 2>&1
 if [ $? -gt 0 ]; then
   echo "ERROR: User '$OPT_USER' does not exist on base system."
   exit 1
 fi
 # check if passwd/shadow/group prison exists
 if [ ! -f $OPT_PRISON/etc/passwd ] || [ ! -f $OPT_PRISON/etc/shadow ] || [ ! -f $OPT_PRISON/etc/group ]; then
   echo "ERROR: No passwd, shadow or group file in prison '$OPT_PRISON'! Prison not setup?"
   exit 1
 fi
 # check if user exists in prison 
 grep "^$OPT_USER:" $OPT_PRISON/etc/passwd >/dev/null 2>&1
 if [ $? -ne 1 ]; then
   echo "ERROR: User '$OPT_USER' already defined in prison '$OPT_PRISON'."
   exit 1
 fi
 
 # add user to passwd
 usr_passwd=`grep "^$OPT_USER:" /etc/passwd | cut -d: -f1,2,3,4,5,6`
 echo "${usr_passwd//$OPT_PRISON/}:$OPT_SHELL" >> $OPT_PRISON/etc/passwd
 # add user to shadow
 usr_shadow=`grep "^$OPT_USER:" /etc/shadow | cut -d: -f3,4,5,6,7,8,9`
 echo "$OPT_USER::$usr_shadow" >> $OPT_PRISON/etc/shadow 
 # add usergroup to group
 usr_group=`grep "^$OPT_USER:" /etc/group | cut -d: -f1,2,3`
 echo "$usr_group:" >> $OPT_PRISON/etc/group

 echo "User '$OPT_USER' added to prison '$OPT_PRISON' with shell '$OPT_SHELL'."
}

# delete user from prison
function f_del_user() {
 # check if passwd/shadow/group prison exists
 if [ ! -f $OPT_PRISON/etc/passwd ] || [ ! -f $OPT_PRISON/etc/shadow ] || [ ! -f $OPT_PRISON/etc/group ]; then
   echo "ERROR: No passwd, shadow or group file in prison '$OPT_PRISON'! Prison not setup?"
   exit 1
 fi
 # check if user exists in prison 
 grep "^$OPT_USER:" $OPT_PRISON/etc/passwd >/dev/null 2>&1
 if [ $? -ne 0 ]; then
   echo "ERROR: User '$OPT_USER' not found in prison."
   exit 1
 fi
 # we need spliting at newline, not space
 IFS=$'\n'
 # remove user from passwd
 usr_passwd=`grep -v "^$OPT_USER:" $OPT_PRISON/etc/passwd`
 echo -n > $OPT_PRISON/etc/passwd
 for usr in $usr_passwd; do
   echo $usr >> $OPT_PRISON/etc/passwd
 done
 # remove user from shadow 
 usr_shadow=`grep -v "^$OPT_USER:" $OPT_PRISON/etc/shadow`
 echo -n > $OPT_PRISON/etc/shadow
 for usr in $usr_shadow; do
   echo $usr >> $OPT_PRISON/etc/shadow
 done
 # remove user from group
 usr_group=`grep -v "^$OPT_USER:" $OPT_PRISON/etc/group`
 echo -n > $OPT_PRISON/etc/group
 for usr in $usr_group; do
   echo $usr >> $OPT_PRISON/etc/group
 done

 echo "User '$OPT_USER' removed from prison '$OPT_PRISON'."

 # unset IFS, turn it to defaults again 
 unset IFS
}

# cleanup OPT_PRISON (remove all trailing slashes)
function f_sanitize_OPT_PRISON() {
 # get length of OPT_PRISON
 len=`expr length $OPT_PRISON`

 # while last character of OPT_PRISON is a slash..
 while ( [ "${OPT_PRISON:(-1)}" == "/" ] ); do
   #..reduce the length by 1..
   len=$(($len-1))
   #..and "shorter" OPT_PRISON by 1 (offset:length).
   OPT_PRISON=${OPT_PRISON:0:$len}
 done
}

# get command line options
case $1 in
  -c|--create|create)
  	OPT_ACTION=create
	OPT_PRISON=$2
	if [ -z "$2" ] || [ ! -z "$3" ]; then
	  echo "ERROR: wrong arguments for action: $OPT_ACTION"; exit 1
	fi
	f_sanitize_OPT_PRISON;
	f_create_prison_base;
	f_create_devices;
	f_copy_binlib;
	f_copy_other_files;
	f_copy_invisiblelibs;
	;;
  -u|--update|update)
  	OPT_ACTION=update
	OPT_PRISON=$2
	if [ -z "$2" ] || [ ! -z "$3" ]; then
	  echo "ERROR: wrong arguments for action: $OPT_ACTION"; exit 1
	fi
	f_sanitize_OPT_PRISON;
	f_copy_binlib;
	f_copy_other_files;
	f_copy_invisiblelibs;
	;;
  -a|--adduser|adduser)
  	OPT_ACTION=adduser
	OPT_USER=$2
	OPT_SHELL=$3
	OPT_PRISON=$4
	if [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || [ ! -z "$5" ]; then
	  echo "ERROR: wrong arguments for action: $OPT_ACTION"; exit 1
	fi
	f_sanitize_OPT_PRISON;
	f_add_user;
	;;
  -d|--deluser|deluser)
  	OPT_ACTION=deluser
	OPT_USER=$2
	OPT_PRISON=$3
	if [ -z "$2" ] || [ -z "$3" ] || [ ! -z "$4" ]; then
	  echo "ERROR: wrong arguments for action: $OPT_ACTION"; exit 1
	fi
	f_sanitize_OPT_PRISON;
	f_del_user;
	;;
     *)
        print_usage;
	;;
esac

exit

