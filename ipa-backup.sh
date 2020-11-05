#!/bin/bash
##
# FreeIPA Backup: basic backup script for FreeIPA
# Copyright 2020 Tim Kennell Jr.
# Licensed under the MIT License (http://opensource.org/licenses/MIT)
##

# ---------------- #
# Global Constants #
# ---------------- #
INSTALL_LOCATION=/opt/ipa-backup
CONFIGURATION_FILE="ipa-backup.conf"
LOG_DIR="log"
SSH_DIR="ssh_keys"
IPA_BACKUP_DIR="/var/lib/ipa/backup"

# ------------ #
# System Check #
# ------------ #

# Set up log file
LOG_FILE="$INSTALL_LOCATION/$LOG_DIR/$HOSTNAME.$(date +"%F_%T").log"
touch "$LOG_FILE"

# Create log directory if not exists
if ! [[ -d "$INSTALL_LOCATION/$LOG_DIR" ]] ; then
        mkdir "$INSTALL_LOCATION/log"
fi


# Check for a configuration file
if ! [[ -f "$INSTALL_LOCATION/$CONFIGURATION_FILE" ]] ; then
	echo "# System Check" >> "$LOG_FILE"
	echo "E: could not find 'ipa-backup.conf'.  Please establish the file" >> "$LOG_FILE"
	exit 1
fi

# Load in configurations
. "$INSTALL_LOCATION/$CONFIGURATION_FILE"



# ----------------------- #
# Variable Default Values #
# ----------------------- #

# Sets a variable to a given value by passing the variable name as a string to 
#     this function followed by the value to be set if not already set
# param Var (as string) $1 -- variable name passed as string
# param String $2 -- default value to be set if variable not already set
## Ex:  set_default_rollover "new_var" "new_value" --> new_var="new_value"
set_numerical_variable_default() {
        local numerical_var="$1"
        local default_value="$2"

        # User has set variable to number
        if [[ -n ${!numerical_var} ]] && [[ ${!numerical_var} =~ ^[0-9]+$ ]]
        then
                return 0

        # User has not set variable to number
        elif [[ -n ${!numerical_var} ]] && ! [[ ${!numerical_var} =~ ^[0-9]+$ ]]
        then
                echo -n "DB Backup Notice: " >> "$log_file"
                echo -n "$numerical_var value not recognized as an integer; "\
                        >> "$log_file"
                echo "setting to default of $default_value" >> "$log_file"
        fi

        # if variable not set or filled with non integer, set to default value
        eval "$numerical_var"\="$default_value"
        return 1
}

set_numerical_variable_default "log_file_rollover" "20"
set_numerical_variable_default "ipa_backup_rollover" "14"


# ---------------- #
# Helper Functions #
# ---------------- #

# Removes the oldest file in a directory until only a pre-determined number
#       remain the log location to user specifications in terminator.conf
# param String $1 Absolute patht to directory to curate or remove files from
# param Number $2 The number of files to leave in the directory
curate_files() {
        local dir_to_curate="$1"
        local final_file_count="$2"

        local file_count="$(ls -1 "$dir_to_curate" | wc -l)"
        local oldest_file

        echo "file count: $file_count"
        echo "final_file_count: $final_file_count"
        echo

        while (("$file_count" > "$final_file_count")) ; do
                oldest_file="$(ls -lFtr "$dir_to_curate" \
                        | awk 'FNR == 2 {print $9}')"

                echo "oldest file: $oldest_file"
                echo

                rm -rf "$dir_to_curate/$oldest_file"

                file_count="$(ls -1 "$dir_to_curate" | wc -l)"
        done
}

# ------------------------------- #
# Generic Remote Backup Functions #
# ------------------------------- #

# SSH params combined for easier use
on_site_host_login_params=(
        "$on_site_host_domain"
        "$on_site_host_port"
        "$on_site_host_user"
        "$on_site_host_ssh_key"
)


# Creates the remote backup directories from an array listing the desired 
#     directories
# param String $1 -- domain name of host
# param String $2 -- SSH port of host
# param String $3 -- backup user of host
# param String $4 -- host ssh key (no passphrase allowed)
# param Dir $5 -- parent directory to contain backups
# param Array $6 -- array of backups directories
## Ex: create_remote_backup_dirs ("dir1" "dir2") --> ./dir1/ ./dir2/
create_remote_backup_dirs() {
        local domain="$1"
        local port="$2"
        local user="$3"
        local ssh_key="$4"
        local parent_dir="$5"

        shift; shift; shift; shift; shift
        local db_backup_dirs=("$@")

        echo "remote backup dirs in func: ${db_backup_dirs[@]}"

        ssh -q -F /dev/null "$user@$domain" -p "$port" \
                -i "$ssh_key" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no '

                # Create directory structure
                for dir in '${db_backup_dirs[@]}' ; do
                        if ! [[ -d "'$parent_dir'/$dir" ]] ; then
                                mkdir -p "'$parent_dir'/$dir"
                        fi
                done
        '
}

# ------------ #
# Main Program #
# ------------ #

# Curate log files
curate_files "$INSTALL_LOCATION/$LOG_DIR" "$log_file_rollover"

# Perform backup
ipa-backup

# If backup successful
if [[ "$?" = "0" ]] ; then
        echo "IPA Backup Info: Successfully stored local backup" >> "$LOG_FILE"
        curate_files "$IPA_BACKUP_DIR" "$ipa_backup_rollover"

        create_remote_backup_dirs ${on_site_host_login_params[@]} \
                "$on_site_host_backup_dir" ipa-backup

        # Attempt remote sync
        rsync -az -e "ssh -e $on_site_host_ssh_key -p $on_site_host_port -o IdentitiesOnly=yes -o StrictHostKeyChecking=no" \
                "$IPA_BACKUP_DIR/" \
                "$on_site_host_user@$on_site_host_domain:$on_site_host_backup_dir"

        # Unsuccessful remote sync
        if ! [[ "$?" = "0" ]]; then
                echo -n "IPA Backup Info: Successfully synced " >> "$LOG_FILE"
                echo "to on-site backup location " >> "$LOG_FILE"

        fi
else
        echo "E: Something went wrong with the IPA backup" >> "$LOG_FILE"
fi