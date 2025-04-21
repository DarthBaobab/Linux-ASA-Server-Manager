#!/bin/bash

# Note: Make sure that both this script (ark_restart_manager.sh) and the ark_instance_manager.sh script are located in the same directory.

# --------------------------------------------- CONFIGURATION STARTS HERE --------------------------------------------- #

# Define your server instances here (use the names you use in ark_instance_manager.sh)
instances=("all" )

# Define the exact announcement times in seconds
announcement_times=(1800 1200 600 90 30 10 )

# Corresponding messages for each announcement time
announcement_messages=(
    "Server wird in 30 Minuten neugestartet!"
    "Server wird in 20 Minuten neugestartet!"
    "Server wird in 10 Minuten neugestartet! Zeit sich in Sicherheit zu bringen."
    "Server wird in 3 Minuten neugestartet! Letzte Chance sich in Sicherheit zu bringen."
    "ACHTUNG! Server Neustart in 30 Sekunden! Bitte schonmal ausloggen. Danke."
    "ACHTUNG! Server Neustart steht unmittelbar bevor!"
)


# --------------------------------------------- CONFIGURATION ENDS HERE --------------------------------------------- #
#                                                                                         \   |   /                   #
#                               &&& &&  & &&                        .-~~~-.                 .-*-.                     #
#                           & &\/&\|& ()|/ @, &&                .-~~       ~~-.           --  *  --                   #
#                             &\/(/&/&||/& /_/)_&              (               )            '-*-'                     #
#                          &() &\/&|()|/&\/ '%" &               `-.__________.-'          /   |   \                   #
#                             &_\/_&&_/ \|&  _/&_&                                          .-~~~-.                   #
#                        &   && & &| &| /& & % ()& /&&                                  .-~~       ~~-.               #
#                  __      ()&_---()&\&\|&&-&&--%---()~                                (               )              #
#                 / _)                \|||                                              `-.__________.-'              #
#        _.----._/ /                   |||                                                                            #
#       /         /                    |||                                      O                                     #
#    __/ (  | (  |                     |||                                     /|\                                    #
#   /__.-'|_|--|_|                     |||                                     / \                                    #
#   , -=-~  .-^- _, -=-~  .-^- _, -=-~  .-^- _, -=-~  .-^- _, -=-~  .-^- _, -=-~  .-^- _, -=-~  .-^- _, -=-~  .-^- _  #
#######################################################################################################################

# Define script and configuration paths as variables
script_dir="$(dirname "$(realpath "$0")")"
ark_manager="$script_dir/ark_instance_manager.sh"
log_dir="$script_dir/logs"
mkdir -p "$log_dir"
log_file="$log_dir/asa-manager_$(date +%F).log"
#Logging Discord Webhook. link or ""
discord_webhook="https://discord.com/api/webhooks/1360984927000072192/ihQhXEzwO7Dt7EIpewdLYJtGmFTLuzfKPa4mW4b_6qtf-Z9wLwgZU0KgwteyOaOSQR4J"

# Time to wait between starting instances (in seconds). The server needs enough time to load the config, before the next instance starts.
start_wait_time=30

# Function to log messages
log_message() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Log in Datei
    echo "$timestamp - $message" >> "$log_file"

    # auch auf der Konsole anzeigen
    echo -e "${CYAN}$timestamp - $message${RESET}"

    # Farben für Discord entfernen
    local message_no_color
    message_no_color=$(echo -e "$message" | sed -r 's/\x1B\[[0-9;]*[mK]//g')

    # an Discord schicken
    if [[ -n "$discord_webhook" ]]; then
        curl -s -H "Content-Type: application/json" \
            -X POST \
            -d "{\"content\": \"$timestamp - $message_no_color\"}" \
            "$discord_webhook" > /dev/null
    fi
	
	# Alte Logs löschen (älter als 30 Tage)
	find "$log_dir" -name 'asa-manager_*.log' -type f -mtime +30 -exec rm -f {} \;
}

# Function to get list of instances
resolve_instances() {
	if [[ "${instances[0]}" == "all" ]]; then
		log_message "Fetching available instances using ark_instance_manager.sh get_available_instances..."

		mapfile -t resolved_instances < <(get_available_instances)

		if [ ${#resolved_instances[@]} -eq 0 ]; then
			log_message "❌ No available instances found via get_available_instances."
			exit 1
		fi

		instances=("${resolved_instances[@]}")
	fi
}

get_available_instances() {
    local instances_dir="$script_dir/instances"
    local found_instances=()

    if [[ ! -d "$instances_dir" ]]; then
        log_message "❌ Instances directory '$instances_dir' does not exist."
        return 1
    fi

    for entry in "$instances_dir"/*; do
        local name
        name="$(basename "$entry")"
        if [[ -d "$entry" && ! "$name" =~ _off$ ]]; then
            found_instances+=("$name")
        fi
    done

    # Ausgabe als Liste – Zeile pro Instanz
    printf "%s\n" "${found_instances[@]}"
}

# Function to execute a command for each instance (with optional wait time)
manage_instances() {
    local action=$1
    local wait_time=$2
	local target_instances=()
	
    for instance in "${instances[@]}"; do
        log_message "Executing '$action' for instance $instance..."
        $ark_manager "$instance" "$action"
        if [ $? -ne 0 ]; then
            log_message "Error: Failed to $action instance $instance."
        fi
        if [ -n "$wait_time" ]; then
            log_message "Waiting $wait_time seconds before proceeding to the next instance..."
            sleep $wait_time
        fi
    done
}

# Function to send RCON command to all instances
send_rcon_to_all() {
    local command=$1
    for instance in "${instances[@]}"; do
        log_message "Sending RCON command '$command' to instance $instance..."
        $ark_manager "$instance" send_rcon "$command"
    done
}

# Function to announce the restart to all players
announce_restart() {
    # Send each announcement
    for i in "${!announcement_times[@]}"; do
        local time_before_restart=${announcement_times[$i]}
        local message="${announcement_messages[$i]}"

        send_rcon_to_all "serverchat $message"
        log_message "Announced: $message."

        # Only if there is a next value, calculate the time difference
        if [ $i -lt $((${#announcement_times[@]} - 1)) ]; then
            local next_time=${announcement_times[$((i+1))]}
            local sleep_time=$(( time_before_restart - next_time ))
            sleep "$sleep_time"
        else
            # For the last entry: Wait for the defined time
            sleep "$time_before_restart"
        fi
    done
}

# ---------- MAIN SCRIPT ----------
log_message "Starting ARK server restart process."

resolve_instances

# 1. Announce the restart with warning messages
announce_restart

# 2. Stop the server instances one by one (no wait time between stops)
log_message "stopping servers"
manage_instances "stop" ""

# 3. Update the server
log_message "Wait 30 sec befor starting the update prozess"
sleep 30
log_message "Updating all instances..."
$ark_manager update
log_message "Update completed."
log_message "Wait 30 sec befor starting the servers"
sleep 30

# 4. Start the server instances one by one (with wait time between starts)
manage_instances "start" "$start_wait_time"

# 5. remove old Backups
$ark_manager cleanup_backups

log_message "ARK servers have been successfully restarted and updated."
