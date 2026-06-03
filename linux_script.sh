#!/bin/bash

###################################################################
# SYSTEM - LINUX | 
#          BTRFS | 
#          Backups via read-only BTRFS Snapshots (to eliminate race conditions) | 
#          Unencrypted Local + Encrypted Backblaze B2 Backups | 
#          Separate preferences/configuration directory (so that cache data is not written into the temporary snapshot) | 
#          Health Check monitoring via pings to an uptime monitoring service

# --- MAKE SURE TO DO STEPS 0-6 BEFORE RUNNING THIS SCRIPT! ---
# 0. Install duplicacy and curl via your package manager.
# 0.1 Move this script to a folder where you'll run it from.

# 1. Expose your encryption password to Duplicacy
# 1.1 Create a "Vault" file in the same folder as the script (for easier referencing)
# sudo nano /home/<user>/Duplicacy/.env

# 1.2 Paste your password inside to show up as an environment variable
# DUPLICACY_B2_STORAGE_PASSWORD="your_super_secret_local_password"
# DUPLICACY_B2_STORAGE_B2_ID="your_backblaze_key_id"
# DUPLICACY_B2_STORAGE_B2_KEY="your_backblaze_application_key"

# 1.3 Lock the "Vault"
# sudo chown root:root /home/<user>/Duplicacy/.env
# sudo chmod 600 /home/<user>/Duplicacy/.env

# 2. Create a preferences/configuration folder for your backup path and `cd` into it
# Make sure to have a separate preferences folder for each folder you're backing up!
# Name preferences folders like this: Backup path: /home/<user>/Some/Backup | Preferences folder name: _home_<user>_Some_Backup
# cd /home/<user>/Duplicacy/_home_<user>_Some_Backup

# 3. Initialize the Primary Storage (Local Hard Drive)
# Use this command to find the `-repository` path (substitute TARGET path with your backup source folder path):
# ( TARGET="/home/<user>/Some/Backup"; MNT=$(findmnt -no TARGET -T "$TARGET"); REL="${TARGET#$MNT}"; echo "${MNT%/}/.duplicacy_snapshot/${REL#/}" )
# Don't worry if the repository path does not exist yet, the script will create it later.
# sudo duplicacy init -repository /home/.duplicacy_snapshot/<user>/Some/Backup -zstd <snapshot_id_label> <destination_path>

# 4. Add the Secondary Storage (Backblaze B2) 
# The -copy flag is CRITICAL. It tells B2 to use the exact same encryption/chunking as the local drive.
# -e means encrypt the cloud storage (highly recommended).
# sudo duplicacy add -e -copy default b2_storage <snapshot_id_label> b2://<backup_bucket_name>

# Repeat 2-4 for all other folders to backup. Make sure to change the <snapshot_id_label> for each.

# 5. Set up Systemd Timers (set up as System-wide service so that it can run as root for snapshots)
# 5.1 Create a file at '/etc/systemd/system/duplicacy-backup.service' (you may need to create those folders first):
# --- COPY FROM BELOW THIS LINE AND PASTE INSIDE THE FILE. REMOVE THE LEADING '#' FROM ALL LINES ---
#[Unit]
#Description=Daily Duplicacy Backup
#After=local-fs.target
#Wants=network-online.target
#After=network-online.target
#
#[Service]
#Type=oneshot
## Put the exact path to your Vault file here
#EnvironmentFile=/home/<user>/Duplicacy/linux/.env
## Put the exact path to the script here
#ExecStart=/home/<user>/Duplicacy/linux/linux_script.sh
#
## Security: Prevents systemd from killing child processes in the middle of running (e.g. BTRFS commands)
#KillMode=process
# --- COPY TILL THE ABOVE LINE ---

# 5.2 Create a file in the exact same folder named 'duplicacy-backup.timer':
# --- COPY FROM BELOW THIS LINE AND PASTE INSIDE THE FILE. REMOVE THE LEADING '#' FROM ALL LINES ---
#[Unit]
#Description=Timer for Daily Duplicacy Backup
#
#[Timer]
## Run at 3:00 AM every day
#OnCalendar=*-*-* 03:00:00
## If the computer was off at 3 AM, run it as soon as it boots
#Persistent=true
#RandomizedDelaySec=900
#
#[Install]
#WantedBy=timers.target
# --- COPY TILL THE ABOVE LINE ---

# 5.3 Run these commands in your terminal to reload systemd, enable the timer to survive reboots, and start it:
# sudo systemctl daemon-reload
# sudo systemctl enable --now duplicacy-backup.timer

# 5.4 To check when your next backup will run, just type:
# sudo systemctl list-timers | grep duplicacy

# 6. Change all the variables below as per your requirements.
###################################################################

# ===================================================
# GLOBAL VARIABLES & CONFIGURATION
# ===================================================
# Path access for Systemd/Cron
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# The path to your external backup hard drive (or any other destination path)
external_drive="<destination_path>"
test_file="${external_drive}/.zombie_drive_test.tmp"

# Paths to folders you want to backup
backup_paths=(
    "/home/<user>/Some/Backup"
    "/mnt/datadrive/Some/Other/Backup"
)

# Path to duplicacy's preferences/configuration directory for the backups
pref_base_dir="/home/<user>/Duplicacy/"

# Path to the encryption password "Vault"
vault_path="/home/<user>/Duplicacy/.env"

# URLs to ping for uptime monitoring
ping_ok_url="https://uptime.domain.tld/api/push/xyz?status=up&msg=Backup-OK"
ping_not_ok_url="https://uptime.domain.tld/api/push/xyz?status=down&msg=Backup-NOT-OK"

log_folder="/var/log/duplicacy/"
log_file_name="duplicacy.log"
log_path="${log_folder}${log_file_name}"
log_max_size=5242880

# Global non-catastrophic error flag (0 = No error occured, 1 = Some error occured)
script_has_error=0

# Check for root access
if [ "$EUID" -ne 0 ]; then
  echo "ERROR: This script must be run as root to manage BTRFS snapshots."
  curl -s -o /dev/null "$ping_not_ok_url"
  exit 1
fi

# ===================================================
# GLOBAL SYSTEM STATE HEALTH CHECK
# ===================================================
finalize_and_exit() {
    # Catastrophic error flag
    # Accept an exit code as the first argument, default to 0 if none provided
    local exit_code="${1:-0}"
    
    echo "==================================================="
    echo "Finalizing system state..."

    # If the function was called with an error exit code, force the global error flag to 1
    if [ "$exit_code" -ne 0 ]; then
        script_has_error=1
    fi
    
    # Evaluate the final state and send the appropriate ping
    if [ "$script_has_error" -eq 1 ]; then
        echo "ERRORS were detected."
        curl -s -o /dev/null "$ping_not_ok_url"
    else
        echo "No errors were detected."
        curl -s -o /dev/null "$ping_ok_url"
    fi

    echo "All operations completed at $(date -Iseconds)"
    echo "==================================================="
    
    # Kill the script with the intended exit code
    exit "$exit_code"
} >> "$log_path" 2>&1

# ===================================================
# PRE-FLIGHT CHECKS
# ===================================================
# Load the encryption password for when script is run manually
if [ -f "$vault_path" ]; then
    set -a
    source "$vault_path"
    set +a
else
    echo "ERROR: Encryption password vault file not found." >> "$log_path"
    finalize_and_exit 1
fi

# ===================================================
# ROLL OVER LOGS
# ===================================================
mkdir -p "$log_folder"

if [ ! -f "$log_path" ]; then
    echo "Log file missing. Created at $(date -Iseconds)" >> "$log_path"
fi

# Delete old log files older than 30 days
find "$log_folder" -name "${log_file_name}.*" -type f -mtime +30 -delete

log_size=$(wc -c < "$log_path")
if [ "$log_size" -gt "$log_max_size" ]; then
    echo "Log exceeds max size of ${log_max_size} bytes. Rolling over log..." >> "$log_path"
    mv "$log_path" "${log_path}.$(date +%Y%m%d_%H%M%S)"
    echo "Started new log file after rollover at $(date -Iseconds)" >> "$log_path"
fi

# ===================================================
# SAFETY CHECK - DESTINATION DRIVE STATUS
# ===================================================
{
    echo "==================================================="
    echo "Starting backup job at $(date -Iseconds)"
    
    # 'mountpoint' checks if a directory is an actual mounted filesystem
    if ! mountpoint -q "$external_drive"; then
        echo "CRITICAL ERROR: External drive is NOT mounted at ${external_drive}. Aborting backups."
        finalize_and_exit 1
    fi

    # Active cache-bypassing check just in case the drive is in a zombie state
    if ! timeout 10s bash -c "echo 'ping' > '$test_file' && sync '$test_file'"; then
        echo "CRITICAL ERROR: External drive is mounted at ${external_drive}, but unresponsive!"
	    finalize_and_exit 1
    fi
    
    rm -f "$test_file"
    echo "External drive verified and actively responding at ${external_drive}."
} >> "$log_path" 2>&1

# ===================================================
# DUPLICACY BACKUP
# ===================================================
for path in "${backup_paths[@]}"; do
    {
        echo "---------------------------------------------------"
        echo "Processing ${path}..."
        
        # Locating the preferences folder we created earlier
        clean_path="${path%/}"
        safe_name="${clean_path//\//_}"
        pref_dir="${pref_base_dir%/}/${safe_name}"
        
        if [ ! -d "$pref_dir/.duplicacy" ]; then
             echo "ERROR: Duplicacy configuration not found at ${pref_dir}. Skipping..."
             script_has_error=1
             continue
        fi
        
        # --- BTRFS SNAPSHOT ---
        
        # Returns the root mount point (BTRFS subvolume) of the backup folder for snapshotting
        mnt_point=$(df --output=target "$clean_path" | tail -n 1)
        
        snap_name=".duplicacy_snapshot"
        snap_root="${mnt_point}/${snap_name}"
        
        # Safety Check: Destroy any stale snapshot left over from a previous crash
        btrfs subvolume delete "$snap_root" > /dev/null 2>&1
        
        echo "Creating READ-ONLY BTRFS snapshot..."
        if ! btrfs subvolume snapshot -r "$mnt_point" "$snap_root" > /dev/null; then
            echo "ERROR: Failed to create BTRFS snapshot. Skipping..."
            script_has_error=1
            continue
        fi
        
        trap 'cd / && btrfs subvolume delete "$snap_root" > /dev/null 2>&1' EXIT
        
        # --- DUPLICACY ---
        
        # 1. Switch to the configuration folder
        if ! cd "$pref_dir"; then
            echo "ERROR: Problem switching to config path. Cleaning up and skipping..."
            cd /
            if ! btrfs subvolume delete "$snap_root" > /dev/null; then
                echo "CRITICAL ERROR: Failed to delete orphaned snapshot at ${snap_root}!"
            else
                echo "Cleanup successful. Snapshot deleted."
            fi
            script_has_error=1
            trap - EXIT
            continue
        fi
        
        # We just need to borrow ONE valid config folder to run check and prune from
        valid_pref_dir="$pref_dir"
        
        # 2. Backup to local drive (default storage)
        echo "Backing up ${path} to local storage..."
        if ! duplicacy backup -stats; then
            echo "CRITICAL ERROR: Local backup failed for ${snap_root}! Check Duplicacy output above."
            script_has_error=1
            # We do NOT use 'continue' here, because we still want to clean up and try the cloud sync.
        else
            echo "Local backup completed successfully."
        fi
        
        # 3. Clean up snapshot
        cd /
        echo "Deleting temporary BTRFS snapshot..."
        if ! btrfs subvolume delete "$snap_root" > /dev/null; then
            echo "CRITICAL ERROR: Failed to delete snapshot at ${snap_root} during final cleanup!"
            script_has_error=1
        else
            echo "Cleanup successful. Snapshot deleted."
        fi
        
        trap - EXIT
        
        # 4. Copy new chunks to Backblaze B2 (Multi-threaded to overcome network latency)
        # Need to switch back to configuration folder
        cd "$pref_dir"
        echo "Copying ${path} to Backblaze B2..."
        if ! duplicacy copy -to b2_storage -threads 4; then
            echo "WARNING: Cloud sync to B2 failed! (Usually a network or authentication issue, check above)."
            script_has_error=1
        else
            echo "Cloud sync completed successfully."
        fi
        
        echo "Finished backing up ${path} at $(date -Iseconds)"
    } >> "$log_path" 2>&1
done

# ===================================================
# GLOBAL VERIFICATION (QUICK CHECK)
# ===================================================
{
    echo "==================================================="
    echo "Starting global verification at $(date -Iseconds)"
    
    if [ -z "$valid_pref_dir" ] || ! cd "$valid_pref_dir"; then
        echo "CRITICAL ERROR: No valid configuration path. Cannot run Check or Prune."
        finalize_and_exit 1
    fi
    
    echo "Running verification from config: $valid_pref_dir"

    # 1. Check Local USB Drive (Single thread to prevent I/O thrashing)
    echo "Checking local storage integrity..."
    if ! duplicacy check -storage default -a; then
        echo "CRITICAL ERROR: Local backup corruption detected!"
        script_has_error=1
    else
        echo "Local storage verified successfully."
    fi

    # 2. Check Backblaze B2 (Multi-threaded to overcome network latency)
    echo "Checking Backblaze B2 integrity..."
    if ! duplicacy check -storage b2_storage -threads 8 -a; then
        echo "CRITICAL ERROR: Cloud backup corruption detected!"
        script_has_error=1
    else
        echo "Cloud storage verified successfully."
    fi
} >> "$log_path" 2>&1

# ===================================================
# PRUNE DUPLICACY BACKUPS (ONLY IF PERFECTLY HEALTHY)
# ===================================================
{
    if [ "$script_has_error" -eq 1 ]; then
        echo "==================================================="
        echo "CRITICAL: Errors were detected during backup or verification!"
        echo "ABORTING PRUNE SEQUENCE to protect potentially restorable data."
        echo "==================================================="
        finalize_and_exit 1
    fi

    echo "==================================================="
    echo "Starting global prune at $(date -Iseconds)"
    echo "Running global prune from config: $valid_pref_dir"
    
    # --- DUPLICACY ---
    
    # Note: If multiple computers back up to this B2 bucket, 
    # REMOVE the '-exclusive' flag!
    
    # 1. Prune Local Storage for ALL folders (-a)
    echo "Pruning all repositories on local storage..."
    if ! duplicacy prune -a -exclusive -keep 0:360 -keep 30:180 -keep 7:30 -keep 1:7; then
        echo "WARNING: Prune failed on local storage! Check Duplicacy output above."
        script_has_error=1
    else
        echo "Local prune completed successfully."
    fi
    
    # 2. Prune B2 Storage for ALL folders (-a)
    echo "Pruning all repositories on Backblaze B2..."
    if ! duplicacy prune -a -exclusive -storage b2_storage -threads 4 -keep 0:360 -keep 30:180 -keep 7:30 -keep 1:7; then
        echo "WARNING: Prune failed on B2! Check network or B2 API limits, and logs above."
        script_has_error=1
    else
        echo "Cloud prune completed successfully."
    fi
    
    echo "Finished prune at $(date -Iseconds)"
    echo "==================================================="
    
    # Finally exit properly
    finalize_and_exit 0
} >> "$log_path" 2>&1

