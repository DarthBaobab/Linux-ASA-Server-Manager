#!/bin/bash

export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export LANGUAGE=C.UTF-8

#set -e

# Color definitions
RED='🔴'
YELLOW='🟡'
GREEN='🟢'
BLUE='🔵'
MAGENTA='🟣'
CYAN='🔷'

# Signal handling to inform the user and kill processes
trap 'echo -e "${RED}Script interrupted. Servers that have already started will continue running."; pkill -P $$; exit 1' SIGINT SIGTERM

# Base directory for all instances
BASE_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
INSTANCES_DIR="$BASE_DIR/instances"
RCON_SCRIPT="$BASE_DIR/rcon.py"
ARK_RESTART_MANAGER="$BASE_DIR/ark_restart_manager.sh"
ARK_INSTANCE_MANAGER="$BASE_DIR/ark_instance_manager.sh"

# Define the base paths as variables
STEAMCMD_DIR="$BASE_DIR/steamcmd"
SERVER_FILES_DIR="$BASE_DIR/server-files"
PROTON_VERSION="GE-Proton9-21"
PROTON_DIR="$BASE_DIR/$PROTON_VERSION"

log_dir="$BASE_DIR/logs"
mkdir -p "$log_dir"
log_file="$log_dir/asa-manager_$(date +%F).log"
log_tmp="$log_dir/tmp.log"
#Logging Discord Webhook.
config_file="$BASE_DIR/ark_discord_control_config.json"
#discord_webhook=$(jq -r '.general.webhook // ""' "$config_file")

# Define URLs for SteamCMD and Proton.
STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
PROTON_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$PROTON_VERSION/$PROTON_VERSION.tar.gz"

# create log and Discord Message
log_message() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Log in Datei
    echo "$timestamp - $message" >> "$log_file"

    # auch auf der Konsole anzeigen
    echo -e "$message"

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

# Function to check for dependencies
check_dependencies() {
    local missing=()
    local package_manager=""
    local dependencies=()
    local config_file="$BASE_DIR/.ark_server_manager_config"

    # Detect the package manager
    if command -v apt-get >/dev/null 2>&1; then
        package_manager="apt-get"
        dependencies=("wget" "tar" "grep" "libc6:i386" "libstdc++6:i386" "libncursesw6:i386" "python3" "libfreetype6:i386" "libfreetype6:amd64" "pkill" "cron")
    elif command -v zypper >/dev/null 2>&1; then
        package_manager="zypper"
        dependencies=("wget" "tar" "grep" "libX11-6-32bit" "libX11-devel-32bit" "gcc-32bit" "libexpat1-32bit" "libXext6-32bit" "python3" "pkill" "libfreetype6" "libfreetype6-32bit" "cron")
    elif command -v dnf >/dev/null 2>&1; then
        package_manager="dnf"
        dependencies=("wget" "tar" "grep" "glibc-devel.i686" "ncurses-devel.i686" "libstdc++-devel.i686" "python3" "freetype" "procps-ng" "cronie")
    elif command -v pacman >/dev/null 2>&1; then
        package_manager="pacman"
        dependencies=("wget" "tar" "grep" "lib32-libx11" "gcc-multilib" "lib32-expat" "lib32-libxext" "python" "freetype2" "cronie")
    else
        log_message "${RED}Error: No supported package manager found on this system."
        exit 1
    fi

    # Check for missing dependencies
    for cmd in "${dependencies[@]}"; do
        if [ "$package_manager" == "apt-get" ] && [[ "$cmd" == *:i386* || "$cmd" == *:amd64* ]]; then
            if ! dpkg-query -W -f='${Status}' "$cmd" 2>/dev/null | grep -q "install ok installed"; then
                missing+=("$cmd")
            fi
        elif [ "$package_manager" == "zypper" ]; then
            if ! rpm -q "${cmd}" >/dev/null 2>&1 && ! command -v "${cmd}" >/dev/null 2>&1; then
                missing+=("$cmd")
            fi
        elif [ "$package_manager" == "dnf" ]; then
            if ! rpm -q "${cmd}" >/dev/null 2>&1 && ! command -v "${cmd}" >/dev/null 2>&1; then
                missing+=("$cmd")
            fi
        elif [ "$package_manager" == "pacman" ]; then
            if ! pacman -Qi "${cmd}" >/dev/null 2>&1 && ! ldconfig -p | grep -q "${cmd}"; then
                missing+=("$cmd")
            fi
        elif [ "$cmd" == "pkill" ]; then
            if ! command -v pkill >/dev/null 2>&1; then
                missing+=("procps")
            fi
        else
            if ! command -v "${cmd}" >/dev/null 2>&1; then
                missing+=("$cmd")
            fi
        fi
    done

    # Report missing dependencies and ask to continue
    if [ ${#missing[@]} -ne 0 ]; then
        # Check if the user has chosen to suppress warnings
        if [ -f "$config_file" ] && grep -q "SUPPRESS_DEPENDENCY_WARNINGS=true" "$config_file"; then
            log_message "${YELLOW}Continuing despite missing dependencies (warnings suppressed)..."
            return
        fi

        log_message "${YELLOW}Warning: The following required packages are missing: ${missing[*]}"
        log_message "${BLUE}Please install them using the appropriate command for your system:"
        case $package_manager in
            "apt-get")
                log_message "${MAGENTA}sudo dpkg --add-architecture i386"
                log_message "${MAGENTA}sudo apt update"
                log_message "${MAGENTA}sudo apt-get install ${YELLOW}${missing[*]}"
                ;;
            "zypper")
                log_message "${MAGENTA}sudo zypper install ${YELLOW}${missing[*]}"
                ;;
            "dnf")
                log_message "${MAGENTA}sudo dnf install ${YELLOW}${missing[*]}"
                ;;
            "pacman")
                echo -e "${BLUE}For Arch Linux users:"
                echo -e "${CYAN}1. Edit the pacman configuration file:"
                echo -e "   ${MAGENTA}sudo nano /etc/pacman.conf"
                echo
                echo -e "${CYAN}2. Find and uncomment the following lines to enable the multilib repository:"
                echo -e "   ${GREEN}[multilib]"
                echo -e "   ${GREEN}Include = /etc/pacman.d/mirrorlist"
                echo
                echo -e "${CYAN}3. Save the file and exit the editor"
                echo
                echo -e "${CYAN}4. Update the package database:"
                echo -e "   ${MAGENTA}sudo pacman -Sy"
                echo
                echo -e "${CYAN}5. Install the missing packages:"
                echo -e "   ${MAGENTA}sudo pacman -S ${YELLOW}${missing[*]}"
                ;;
        esac

        log_message "\n"
        log_message "${YELLOW}Continue anyway? ${RED}(not recommended) ${YELLOW}[y/N]"
        read -r response
        if [[ ! $response =~ ^[Yy]$ ]]; then
            log_message "${RED}Exiting due to missing dependencies."
            exit 1
        fi

        echo
        log_message "${YELLOW}Do you want to suppress this warning in the future? [y/N]"
        read -r suppress_response
        if [[ $suppress_response =~ ^[Yy]$ ]]; then
            log_message "SUPPRESS_DEPENDENCY_WARNINGS=true" >> "$config_file"
            log_message "${GREEN}Dependency warnings will be suppressed in future runs."
        fi

        log_message "${YELLOW}Continuing despite missing dependencies..."
    fi
}

# Check dependencies before proceeding
check_dependencies

# Function to check if required scripts are executable
check_executables() {
    local required_files=("$RCON_SCRIPT" "$ARK_RESTART_MANAGER" "$ARK_INSTANCE_MANAGER")
    for file in "${required_files[@]}"; do
        if [ ! -x "$file" ]; then
            log_message "${RED}Error: Required file '$file' is not executable."
            log_message "${BLUE}Run 'chmod +x $file' to fix this issue."
            exit 1
        fi
    done
}

# Call the function at the start of the script
check_executables

#Sets up a symlink
setup_symlink() {
    # Target directory for the symlink
    local target_dir="$HOME/.local/bin"
    # Name under which the script can be invoked
    local script_name="asa-manager"

    # Check if the target directory exists
    if [ ! -d "$target_dir" ]; then
        log_message "Creating directory $target_dir..."
        mkdir -p "$target_dir" || {
            log_message "Error: Could not create directory $target_dir."
            exit 1
        }
    fi

    # Create or update the symlink
    log_message "Creating or updating the symlink $target_dir/$script_name..."
    ln -sf "$(realpath "$0")" "$target_dir/$script_name" || {
        log_message "Error: Could not create symlink."
        exit 1
    }

    # Check if $HOME/.local/bin is in the PATH
    if [[ ":$PATH:" != *":$target_dir:"* ]]; then
        log_message "Adding $target_dir to PATH..."
        log_message 'export PATH=$PATH:$HOME/.local/bin' >> "$HOME/.bashrc"
        log_message "The change will take effect after restarting the shell or running 'source ~/.bashrc'."
    fi

    log_message "Setup completed. You can now run the script using 'asa-manager'."
}

# This function searches all instance_config.ini files in the $INSTANCES_DIR folder
# and collects the ports into arrays
check_for_duplicate_ports() {
    declare -A port_occurrences
    declare -A rcon_occurrences
    declare -A query_occurrences

    local duplicates_found=false

    # Iterate over all instance folders
    for instance_dir in "$INSTANCES_DIR"/*; do
        if [ -d "$instance_dir" ]; then
            local config_file="$instance_dir/instance_config.ini"
            if [ -f "$config_file" ]; then
                local instance_name
                instance_name=$(basename "$instance_dir")

                # Extract ports from the config
                local game_port rcon_port query_port
                game_port=$(grep -E "^Port=" "$config_file" | cut -d= -f2- | xargs)
                rcon_port=$(grep -E "^RCONPort=" "$config_file" | cut -d= -f2- | xargs)
                query_port=$(grep -E "^QueryPort=" "$config_file" | cut -d= -f2- | xargs)

                # Ignore entries if they are empty
                [ -z "$game_port" ] && game_port="NULL"
                [ -z "$rcon_port" ] && rcon_port="NULL"
                [ -z "$query_port" ] && query_port="NULL"

                # Check for conflicts
                if [ "$game_port" != "NULL" ]; then
                    if [ -n "${port_occurrences[$game_port]}" ]; then
                        log_message "${RED}Conflict: Game port $game_port is used by both '${port_occurrences[$game_port]}' and '$instance_name'."
                        duplicates_found=true
                    else
                        port_occurrences[$game_port]="$instance_name"
                    fi
                fi

                if [ "$rcon_port" != "NULL" ]; then
                    if [ -n "${rcon_occurrences[$rcon_port]}" ]; then
                        log_message "${RED}Conflict: RCON port $rcon_port is used by both '${rcon_occurrences[$rcon_port]}' and '$instance_name'."
                        duplicates_found=true
                    else
                        rcon_occurrences[$rcon_port]="$instance_name"
                    fi
                fi

                if [ "$query_port" != "NULL" ]; then
                    if [ -n "${query_occurrences[$query_port]}" ]; then
                        log_message "${RED}Conflict: Query port $query_port is used by both '${query_occurrences[$query_port]}' and '$instance_name'."
                        duplicates_found=true
                    else
                        query_occurrences[$query_port]="$instance_name"
                    fi
                fi
            fi
        fi
    done

    if [ "$duplicates_found" = true ]; then
        log_message "${RED}Port duplicates were found. Please correct the ports in the instance_config.ini files."
        return 1
    else
        log_message "${GREEN}No duplicate ports found."
        return 0
    fi
}

# Function to check if a server is running
is_server_running() {
    local instance=$1
    load_instance_config "$instance" || return 1
    if pgrep -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" > /dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to install or update the base server
install_base_server() {
    local running_instances=0
    local gauge_steps=5
    local gauge_stage=0
    
    set +e

    # Iterate over all instance directories to check if any instance is running
    for instance in "$INSTANCES_DIR"/*; do
        if [ -d "$instance" ]; then
            local instance_name=$(basename "$instance")
            if is_server_running "$instance_name"; then
                log_message "${RED}Instance '$instance_name' is currently running. Please stop all instances before updating the base server."
                ((running_instances++))
            fi
        fi
    done
    
    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps
    
    set -e

    # Check if any instances were running
    if [ "$running_instances" -gt 0 ]; then
        log_message "${YELLOW}Base server update skipped because $running_instances instance(s) are running."
    
        gauge_stage=gauge_steps
        gauge_progress $gauge_stage $gauge_steps
        return 0
    fi

    log_message "${BLUE}Installing/updating base server..."
    
    ((gauge_stage++))
    #log_message "DEBUG: gauge_stage=$gauge_stage, gauge_steps=$gauge_steps"
    gauge_progress $gauge_stage $gauge_steps
    
    # Create necessary directories
    mkdir -p "$STEAMCMD_DIR" "$PROTON_DIR" "$SERVER_FILES_DIR"
    
    # Download and unpack SteamCMD if not already installed
    if [ ! -f "$STEAMCMD_DIR/steamcmd.sh" ]; then
        log_message "${CYAN}Downloading SteamCMD..."
        wget -q -O "$STEAMCMD_DIR/steamcmd_linux.tar.gz" "$STEAMCMD_URL"
        tar -xzf "$STEAMCMD_DIR/steamcmd_linux.tar.gz" -C "$STEAMCMD_DIR"
        rm "$STEAMCMD_DIR/steamcmd_linux.tar.gz"
    else
        log_message "${GREEN}SteamCMD already installed."
    fi
    
    ((gauge_stage++))
    #log_message "DEBUG: gauge_stage=$gauge_stage, gauge_steps=$gauge_steps"
    gauge_progress $gauge_stage $gauge_steps
    
    # Download and unpack Proton if not already installed
    if [ ! -d "$PROTON_DIR/files" ]; then
        log_message "${CYAN}Downloading Proton..."
        wget -q -O "$PROTON_DIR/$PROTON_VERSION.tar.gz" "$PROTON_URL"
        tar -xzf "$PROTON_DIR/$PROTON_VERSION.tar.gz" -C "$PROTON_DIR" --strip-components=1
        rm "$PROTON_DIR/$PROTON_VERSION.tar.gz"
    else
        log_message "${GREEN}Proton already installed."
    fi
    
    ((gauge_stage++))
    #log_message "DEBUG: gauge_stage=$gauge_stage, gauge_steps=$gauge_steps"
    gauge_progress $gauge_stage $gauge_steps
    
    # Install or update ARK server using SteamCMD
    log_message "${CYAN}Installing/updating ARK server..."
    "$STEAMCMD_DIR/steamcmd.sh" +force_install_dir "$SERVER_FILES_DIR" +login anonymous +app_update 2430930 validate +quit | stdbuf -oL sed -r 's/\x1B\[[0-9;]*[mK]//g'

    # Check if configuration directory exists
    if [ ! -d "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer/" ]; then
        log_message "${CYAN}First installation detected. Initializing Proton prefix..."

        # Set Proton environment variables
        export STEAM_COMPAT_DATA_PATH="$SERVER_FILES_DIR/steamapps/compatdata/2430930/0-default"
        export STEAM_COMPAT_CLIENT_INSTALL_PATH="$BASE_DIR"

        # Initialize Proton prefix
        initialize_proton_prefix "0-default"

        log_message "${CYAN}Starting server once to generate configuration files... This will take 60 seconds"

        # Initial server start to generate configs
        "$PROTON_DIR/proton" run "$SERVER_FILES_DIR/ShooterGame/Binaries/Win64/ArkAscendedServer.exe" \
            "TheIsland_WP?listen" \
            -NoBattlEye \
            -crossplay \
            -server \
            -log \
            -nosteamclient \
            -game &
        # Wait to generate files
        sleep 60
        # Stop the server
        pkill -f "ArkAscendedServer.exe.*TheIsland_WP" || true
        log_message "${GREEN}Initial server start completed."
    else
        log_message "${GREEN}Server configuration directory already exists. Skipping initial server start."
    fi

    log_message "${GREEN}Base server installation/update completed."
        
    ((gauge_stage++))
    #log_message "DEBUG: gauge_stage=$gauge_stage, gauge_steps=$gauge_steps"
    gauge_progress $gauge_stage $gauge_steps
}

# Function to initialize Proton prefix
initialize_proton_prefix() {
    local instance=$1
    local proton_prefix="$SERVER_FILES_DIR/steamapps/compatdata/2430930/$instance"

    log_message "${CYAN}Initializing Proton prefix for instance '$instance'..."

    # Ensure the directory exists
    mkdir -p "$proton_prefix"

    # Copy the default Proton prefix
    cp -r "$PROTON_DIR/files/share/default_pfx/." "$proton_prefix/"

    log_message "${GREEN}Proton prefix initialized."
}

# Function to populate an array with available instances from INSTANCES_DIR
get_available_instances() {
    local include_disabled="$1"
	# Clear the array to avoid stale entries
    available_instances=()

	for entry in "$INSTANCES_DIR"/*; do
		name="$(basename "$entry")"
		#if [[ -d "$entry" && ! "$name" =~ _off$ ]]; then
		if [[ -d "$entry" ]]; then
			if [[ "$include_disabled" == "all" ]] || { [[ ! "$name" =~ _off$ ]] && [[ ! "$name" =~ Testserver ]]; }; then
				available_instances+=("$name")
			fi    
		fi
done
}

# Function to list all instances
list_instances() {
    # Reuse the helper function
    get_available_instances "all"

    if [ ${#available_instances[@]} -eq 0 ]; then
        log_message "${RED}No instances found in '$INSTANCES_DIR'."
        return
    fi

    log_message "Available instances:"
    for inst in "${available_instances[@]}"; do
        log_message "$inst"
    done
}

# Function to create or edit instance configuration
edit_instance_config() {
    local instance=$1
    local config_file="$INSTANCES_DIR/$instance/instance_config.ini"
    local game_ini_file="$INSTANCES_DIR/$instance/Config/Game.ini"

    # Create instance directory if it doesn't exist
    if [ ! -d "$INSTANCES_DIR/$instance" ]; then
        log_message "${BLUE}No instance directory found. Created for '$instance'"
        mkdir -p "$INSTANCES_DIR/$instance"
    fi

      # Create the Config directory if it doesn't exist
    if [ ! -d "$INSTANCES_DIR/$instance/Config" ]; then
        log_message "${GREEN}No Config directory found. Created for '$instance'"
        mkdir -p "$INSTANCES_DIR/$instance/Config"
    fi

    # Create config file if it doesn't exist
    if [ ! -f "$config_file" ]; then
        log_message "${BLUE}Create config file for '$instance'"
        cat <<EOF > "$config_file"
[ServerSettings]
ServerName=$instance
ServerPassword=
ServerAdminPassword=
MaxPlayers=
MapName=
RCONPort=
QueryPort=
Port=
ModIDs=
CustomStartParameters=-NoBattlEye -crossplay -NoHangDetection -exclusivejoin
#When changing SaveDir, make sure to give it a unique name, as this can otherwise affect the stop server function.
#Do not use umlauts, spaces, or special characters.
SaveDir=$instance
ClusterID=
EOF
        chmod 600 "$config_file"  # Set file permissions to be owner-readable and writable
    fi

     # Create an empty Game.ini, if it doesnt exist
    if [ ! -f "$game_ini_file" ]; then
        touch "$game_ini_file"
        log_message "${BLUE}Empty Game.ini for '$instance' Created. Optional: Edit it for your needs"
    fi

	log_message "${GREEN}Open instance config file for '$instance'"

    # Open the config file in the default text editor
    if [ -n "$EDITOR" ]; then
        "$EDITOR" "$config_file"
    elif command -v nano >/dev/null 2>&1; then
        nano "$config_file"
    elif command -v vim >/dev/null 2>&1; then
        vim "$config_file"
    else
        log_message "${RED}No suitable text editor found. Please edit $config_file manually."
    fi
}

# Function to load instance configuration
load_instance_config() {
    local instance=$1
    local config_file="$INSTANCES_DIR/$instance/instance_config.ini"

    if [ ! -f "$config_file" ]; then
        log_message "${RED}Configuration file for instance $instance not found."
        return 1
    fi

    # Read configuration into variables
    SERVER_NAME=$(grep -E '^ServerName=' "$config_file" | cut -d= -f2- | xargs)
    SERVER_PASSWORD=$(grep -E '^ServerPassword=' "$config_file" | cut -d= -f2- | xargs)
    ADMIN_PASSWORD=$(grep -E '^ServerAdminPassword=' "$config_file" | cut -d= -f2- | xargs)
    MAX_PLAYERS=$(grep -E '^MaxPlayers=' "$config_file" | cut -d= -f2- | xargs)
    MAP_NAME=$(grep -E '^MapName=' "$config_file" | cut -d= -f2- | xargs)
    RCON_PORT=$(grep -E '^RCONPort=' "$config_file" | cut -d= -f2- | xargs)
    QUERY_PORT=$(grep -E '^QueryPort=' "$config_file" | cut -d= -f2- | xargs)
    GAME_PORT=$(grep -E '^Port=' "$config_file" | cut -d= -f2- | xargs)
    MOD_IDS=$(grep -E '^ModIDs=' "$config_file" | cut -d= -f2- | xargs)
    SAVE_DIR=$(grep -E '^SaveDir=' "$config_file" | cut -d= -f2- | xargs)
    CLUSTER_ID=$(grep -E '^ClusterID=' "$config_file" | cut -d= -f2- | xargs)
    CUSTOM_START_PARAMETERS=$(grep -E '^CustomStartParameters=' "$config_file" | cut -d= -f2- | xargs)

    return 0
}

# Function to create a new instance (using 'read' with validation)
create_instance() {
    # Check if the directory exists
    if [ ! -d "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer/" ]; then
        log_message "${RED}The required directory does not exist: $SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer/"
        log_message "${YELLOW}Cannot proceed with instance creation. You need to install Base Server first"
        return
    fi

    #while true; do
        instance_name=$(dialog --begin 1 5 --no-shadow --inputbox "Enter the name for the new instance:" 10 50 2>&1 >/dev/tty)
        local dialog_exit_code=$?
        clear
        if [ $dialog_exit_code -ne 0 ]; then
            dialog --begin 1 5 --no-shadow --msgbox "${YELLOW}Instance creation cancelled." 10 50
            log_message "${YELLOW}Instance creation cancelled."
        elif [ -z "$instance_name" ]; then
            dialog --begin 1 5 --no-shadow --msgbox "${RED}Instance name cannot be empty." 10 50
            log_message "${RED}Instance name cannot be empty."
        elif [ -d "$INSTANCES_DIR/$instance_name" ]; then
            dialog --begin 1 5 --no-shadow --msgbox "${RED}Instance already exists." 10 50
            log_message "${RED}Instance already exists."
        else
            mkdir -p "$INSTANCES_DIR/$instance_name"
            edit_instance_config "$instance_name"
            initialize_proton_prefix "$instance_name"
            dialog --begin 1 5 --no-shadow --msgbox "${GREEN}Instance '$instance_name' created successfully." 10 50
            log_message "${GREEN}Instance $instance_name created and configured."
        fi
    #done
}

# Function to select an instance using 'select'
select_instance() {
    local instances=()
    local menu_items=()
    local i=1

    # Populate the instances array
    for dir in "$INSTANCES_DIR"/*; do
        if [ -d "$dir" ]; then
            local name
            name="$(basename "$dir")"
            instances+=("$name")
            menu_items+=("$i" "$name")
            ((i++))
        fi
    done

    if [ ${#instances[@]} -eq 0 ]; then
        log_message "${RED}No instances found."
        return 1
    fi

    # Dialog menu
    local choice
    choice=$(dialog --begin 1 5 --no-shadow --clear --title "Select Instance" \
        --menu "Please select an instance:" 0 50 0 \
        "${menu_items[@]}" \
        2>&1 >/dev/tty)

    clear

    if [ -z "$choice" ] || [ "$choice" = "0" ]; then
        log_message "${YELLOW}Operation cancelled."
        return 1
    fi

    local idx=$((choice - 1))
    selected_instance="${instances[$idx]}"
    log_message "${GREEN}You have selected: $selected_instance"
    return 0
}
# Function to start the server
start_server() {
    gauge_steps=11
    gauge_stage=0

    local instance=$1
    # Check for duplicate ports
    if ! check_for_duplicate_ports; then
        log_message "${YELLOW}Port conflicts detected. Server start aborted."
        return 1
    fi

    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps

    if is_server_running "$instance"; then
        log_message "${YELLOW}Server for instance $instance is already running."
        return 0
    fi

    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps

    load_instance_config "$instance" || return 1

    log_message "${CYAN}Starting server for instance: $instance"

    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps

    # Set Proton environment variables
    export STEAM_COMPAT_DATA_PATH="$SERVER_FILES_DIR/steamapps/compatdata/2430930/$instance"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$BASE_DIR"
    
    # Check if the Proton prefix exists
    if [ ! -d "$STEAM_COMPAT_DATA_PATH" ]; then
        # Initialize Proton prefix
        initialize_proton_prefix "$instance"
    fi

    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps

    # Ensure per-instance Config directory exists
    local instance_config_dir="$INSTANCES_DIR/$instance/Config"
    if [ ! -d "$instance_config_dir" ]; then
        mkdir -p "$instance_config_dir"
        cp -r "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer/." "$instance_config_dir/" || true
        # Set permissions for GameUserSettings.ini
        chmod 600 "$instance_config_dir/GameUserSettings.ini" || true
    fi

    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps

    # Backup the original Config directory if not already backed up
    if [ ! -L "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" ] && [ -d "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" ]; then
        mv "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer.bak" || true
    fi

    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps

    # Link the instance Config directory
    rm -rf "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" || true
    ln -s "$instance_config_dir" "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" || true

    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps

    # Ensure per-instance save directory exists
    local save_dir="$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$SAVE_DIR"
    mkdir -p "$save_dir" || true

    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps

    # Set cluster parameters if ClusterID is set
    local cluster_params=""
    if [ -n "$CLUSTER_ID" ]; then
        local cluster_dir="$BASE_DIR/clusters/$CLUSTER_ID"
        mkdir -p "$cluster_dir" || true
        cluster_params="-ClusterDirOverride=\"$cluster_dir\" -ClusterId=\"$CLUSTER_ID\""
    fi

    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps

    # Start the server using the loaded configuration variables

    # Adding a trailing space to the ServerName to avoid conflicts if the ServerName is identical to the instance name.
    # This ensures the server processes the name correctly, even though the space is invisible to users.
    "$PROTON_DIR/proton" run "$SERVER_FILES_DIR/ShooterGame/Binaries/Win64/ArkAscendedServer.exe" \
    "$MAP_NAME?listen?SessionName=$SERVER_NAME ?ServerPassword=$SERVER_PASSWORD?RCONEnabled=True?ServerAdminPassword=$ADMIN_PASSWORD?AltSaveDirectoryName=$SAVE_DIR" \
    $CUSTOM_START_PARAMETERS \
    -WinLiveMaxPlayers=$MAX_PLAYERS \
    -Port=$GAME_PORT \
    -QueryPort=$QUERY_PORT \
    -RCONPort=$RCON_PORT \
    -game \
    $cluster_params \
    -server \
    -log="$instance.log" \
    -mods="$MOD_IDS" \
    > "$INSTANCES_DIR/$instance/server.log" 2>&1 &

    log_message "${BLUE}Server started for instance: $instance. Waiting for it to become operational..."

    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps

    # Wait for the server to start and check if it's running
    local timeout=60
    local waited=0
    while ! is_server_running "$instance"; do
        sleep 2
        ((waited += 2))
        if [ $waited -ge $timeout ]; then
            log_message "${RED}Server for instance $instance failed to start within $timeout seconds."
            return 1
        fi
    done

    log_message "${GREEN}Server for instance $instance is now running and operational."

    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps
}

# Function to stop the server
stop_server() {
    local instance="$1"

    if ! is_server_running "$instance"; then
        log_message "${YELLOW}Server for instance $instance is not running."
        return 0
    fi

    load_instance_config "$instance" || return 1

    send_rcon_command "$instance" "broadcast Server is shutting down. Please exit the game."

    # Save world before stopping
    save_instance "$instance"

    log_message "${BLUE}Attempting graceful shutdown for instance $instance..."

    # Send the "DoExit" command and capture the response
    local response
    response=$(send_rcon_command "$instance" "DoExit")

    # Check if the response matches "Exiting..."
    #if [[ "$response" == "Exiting..." ]]; then
	if echo "$response" | grep -qi "Exiting..."; then	
        log_message "${GREEN}Server instance $instance reported 'Exiting...'. Awaiting shutdown..."

        # Check in a loop if the process is still running
        local timeout=120  # Give 30 seconds
        local waited=0

        while pgrep -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" > /dev/null; do
            sleep 2
            (( waited+=2 ))
            if [ $waited -ge $timeout ]; then
                log_message "${RED}Server $instance didn't shut down within $timeout seconds. Forcing kill..."
                pkill -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR"
                break
            fi
        done

        log_message "${GREEN}Server for instance $instance has exited (or was force-killed)."
        #return 0
    else
        log_message "${RED}Graceful shutdown failed or timed out. Forcing shutdown."
        pkill -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" || true
        log_message "${GREEN}Server for instance $instance has been forcefully stopped."
        #return 0
    fi
	
	# --- 🟢 BACKUP nach dem Stop ---
    log_message "${CYAN}Creating backup after stopping instance '$instance'..."
    backup_instance_world "$instance"
    if [ $? -ne 0 ]; then
        log_message "${RED}❌ Backup failed or skipped."
    else
        log_message "${GREEN}✅ Backup completed after shutdown."
    fi
    # ------------------------------

    return 0
}

# Function to restart the server
restart_server() {
    local instance=$1

    if [ "$instance" == "all" ]; then
        log_message "${BLUE}Restarting all instances..."
        send_rcon_command_to_all "broadcast Server restart. Please exit the game."
        stop_all_instances
        start_all_instances
    else
        if ! is_server_running "$instance"; then
            log_message "${YELLOW}Server for instance $instance is not running. Starting the server..."
            start_server "$instance"
        else
            log_message "${BLUE}Stopping server for instance $instance..."
            stop_server "$instance"
            log_message "${BLUE}Starting server for instance $instance..."
            start_server "$instance"
        fi
    fi
}

# Function to start RCON CLI
start_rcon_cli() {
    local instance=$1

    if ! is_server_running "$instance"; then
        log_message "${YELLOW}Server for instance $instance is not running."
        return 0
    fi

    load_instance_config "$instance" || return 1

    log_message "${CYAN}Starting RCON CLI for instance: $instance"

    # Use the new RCON-Client
    "$RCON_SCRIPT" "localhost:$RCON_PORT" -p "$ADMIN_PASSWORD" || {
        log_message "${RED}Failed to start RCON CLI for instance $instance."
        return 1
    }

    return 0
}

# Function to change map
change_map() {
    local instance=$1
    load_instance_config "$instance" || return 1
    log_message "${BLUE}Current map: $MAP_NAME"
    log_message "${BLUE}Enter the new map name (or type 'cancel' to abort):"
    read -r -e -i "$MAP_NAME" new_map_name
    if [[ "$new_map_name" == "cancel" ]]; then
        log_message "${YELLOW}Map change aborted."
        return 0
    fi
    sed -i "s/MapName=.*/MapName=$new_map_name/" "$INSTANCES_DIR/$instance/instance_config.ini"
    log_message "${GREEN}Map changed to $new_map_name. Restart the server for changes to take effect."
}

# Function to change mods
change_mods() {
    local instance=$1
    load_instance_config "$instance" || return 1
    log_message "${BLUE}Current mods: $MOD_IDS"
    log_message "${BLUE}Enter the new mod IDs (comma-separated, or type 'cancel' to abort):"
    #read -r new_mod_ids
    read -r -e -i "$MOD_IDS" new_mod_ids
    if [[ "$new_mod_ids" == "cancel" ]]; then
        log_message "${YELLOW}Mod change aborted."
        return 0
    fi
    sed -i "s/ModIDs=.*/ModIDs=$new_mod_ids/" "$INSTANCES_DIR/$instance/instance_config.ini"
    log_message "${GREEN}Mods changed to $new_mod_ids. Restart the server for changes to take effect."
}

# Function to check server status
check_server_status() {
    local instance=$1
    load_instance_config "$instance" || return 1
    if pgrep -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" > /dev/null; then
        log_message "${GREEN}Server for instance $instance is running."
    else
        log_message "${RED}Server for instance $instance is not running."
    fi
}

# Function to start all instances with a delay between each
start_all_instances() {
    log_message "${CYAN}Starting all server instances..."
    get_available_instances
    gauge_steps=${#available_instances[@]}
    gauge_stage=0

    for instance_name in "${available_instances[@]}"; do
	instance="$INSTANCES_DIR/$instance_name"

    ((gauge_stage++))
    gauge_progress $gauge_stage $gauge_steps

        if [ -d "$instance" ]; then
            # Check if the server is already running
            if is_server_running "$instance_name"; then
                log_message "${BLUE}Instance $instance_name is already running. Skipping..."
                continue
            fi

            # Attempt to start the server
            if start_server "$instance_name"; then
                # Only wait 30 seconds if the server started successfully
                log_message "${YELLOW}Waiting 30 seconds before starting the next instance..."
                sleep 30
            else
                log_message "${RED}Server $instance_name could not be started due to conflicts or errors. Skipping wait time."
            fi
        fi
    done
    log_message "${GREEN}All instances have been processed."
}

# Function to stop all instances
stop_all_instances() {
    log_message "${CYAN}Stopping all server instances..."
    get_available_instances "all"
    gauge_steps=${#available_instances[@]}
    gauge_stage=0

    for instance_name in "${available_instances[@]}"; do
        instance="$INSTANCES_DIR/$instance_name"
        
        ((gauge_stage++))
        gauge_progress $gauge_stage $gauge_steps

        if [ -d "$instance" ]; then
            if ! is_server_running "$instance_name"; then
                log_message "${YELLOW}Instance $instance_name is not running. Skipping..."
                continue
            fi
            stop_server "$instance_name"
        fi
    done
    log_message "${GREEN}All instances have been stopped."
}

# Function to send RCON command
send_rcon_command() {
    local instance=$1
    local command=$2

    if ! is_server_running "$instance"; then
        log_message "${YELLOW}Server for instance $instance is not running. Cannot send RCON command."
        return 1
    fi

    load_instance_config "$instance" || return 1

    # Always use the silent mode of the RCON client
	log_message "Sending $command to $instance"
	local response
    response=$("$RCON_SCRIPT" "localhost:$RCON_PORT" -p "$ADMIN_PASSWORD" -c "$command" --silent 2>&1)

    # Check if the RCON command was successful
    if [ $? -ne 0 ]; then
        log_message "${RED}Failed to send RCON command to instance $instance."
        return 1
    fi

    # Return the RCON response
    log_message "$response"
    return 0
}

# Function to send RCON command to all
send_rcon_command_to_all() {
    local command=$1
    get_available_instances
    for instance_name in "${available_instances[@]}"; do
    	instance="$INSTANCES_DIR/$instance_name"
        if [ -d "$instance" ]; then
            if ! is_server_running "$instance_name"; then
                log_message "${YELLOW}Instance $instance_name is not running. Skipping..."
                continue
            fi
			send_rcon_command "$instance_name" "$command"
        fi
    done
    #log_message "${GREEN}All instances have been stopped."
}

# Function to show running instances
show_running_instances() {
    log_message "${CYAN}Checking running instances..."
    local running_count=0
    for instance in "$INSTANCES_DIR"/*; do
        if [ -d "$instance" ]; then
            instance_name=$(basename "$instance")
            # Load instance configuration
            load_instance_config "$instance_name" || continue
            # Check if the server is running
            if pgrep -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" > /dev/null; then
                log_message "${GREEN}$instance_name"
                ((running_count++)) || true
            else
                log_message "${RED}$instance_name"
            fi
        fi
    done
    if [ $running_count -eq 0 ]; then
        log_message "${CYAN}No instances are currently running."
    else
        log_message "${CYAN}Total running instances: $running_count"
    fi
}

# Function to delete an instance
delete_instance() {
    local instance=$1
    if [ -z "$instance" ]; then
        if ! select_instance; then
            return
        fi
        instance=$selected_instance
    fi
    if [ -d "$INSTANCES_DIR/$instance" ]; then
        log_message "${YELLOW}Warning: This will permanently delete the instance '$instance' and all its data."
        log_message "Type CONFIRM to delete the instance '$instance', or cancel to abort"
        read -p "> " response

        if [[ $response == "CONFIRM" ]]; then
            # Load instance config
            load_instance_config "$instance"
            # Stop instance if it's running
            if pgrep -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" > /dev/null; then
                log_message "${CYAN}Stopping instance '$instance'..."
                stop_server "$instance"
            fi
            # Check if other instances are running
            if pgrep -f "ArkAscendedServer.exe" > /dev/null; then
                log_message "${YELLOW}Other instances are still running. Not removing the Config symlink to avoid affecting other servers."
            else
                # Remove the symlink and restore the original configuration directory
                rm -f "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" || true
                if [ -d "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer.bak" ]; then
                    mv "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer.bak" "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" || true
                fi
            fi
            # Deleting the instance directory and save games
            rm -rf "$INSTANCES_DIR/$instance" || true
            rm -rf "$SERVER_FILES_DIR/ShooterGame/Saved/$instance" || true
            rm -rf "$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$instance" || true
            echo -e "${GREEN}Instance '$instance' has been deleted."
        elif [[ $response == "cancel" ]]; then
            log_message "${YELLOW}Deletion cancelled."
        else
            log_message "${RED}Invalid response. Deletion cancelled."
        fi
    else
        log_message "${RED}Instance '$instance' does not exist."
    fi

   	get_available_instances all
}

# Function to change instance name
change_instance_name() {
    local instance=$1
    load_instance_config "$instance" || return 1

    # Check if Server are running
	if is_server_running "$instance"; then
        log_message "${YELLOW}Server for instance $instance is running. Please stop it first."
        return 0
    fi

    log_message "${CYAN}Enter the new name for instance '$instance' (or type 'cancel' to abort):"
    read -r -e -i "$instance" new_instance_name

    # Validation
    if [ "$new_instance_name" = "cancel" ]; then
        log_message "${YELLOW}Instance renaming cancelled."
        return
    elif [ -z "$new_instance_name" ]; then
        log_message "${RED}Instance name cannot be empty."
        return 1
    elif [ -d "$INSTANCES_DIR/$new_instance_name" ]; then
        log_message "${RED}An instance with the name '$new_instance_name' already exists."
        return 1
    fi

    # Rename instance directory
    mv "$INSTANCES_DIR/$instance" "$INSTANCES_DIR/$new_instance_name" || {
        log_message "${RED}Failed to rename instance directory."
        return 1
    }

    # Rename save directories if they exist
    if [ -d "$SERVER_FILES_DIR/ShooterGame/Saved/$instance" ]; then
        mv "$SERVER_FILES_DIR/ShooterGame/Saved/$instance" "$SERVER_FILES_DIR/ShooterGame/Saved/$new_instance_name" || true
    fi

    if [ -d "$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$instance" ]; then
        mv "$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$instance" "$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$new_instance_name" || true
    fi
    
    # Rename Proton Prefix directories if they exist    
    if [ -d "$SERVER_FILES_DIR/steamapps/compatdata/2430930/$instance" ]; then
        mv "$SERVER_FILES_DIR/steamapps/compatdata/2430930/$instance" "$SERVER_FILES_DIR/steamapps/compatdata/2430930/$new_instance_name" || true
    fi

    # Update SaveDir in the instance configuration
    sed -i "s/^SaveDir=.*/SaveDir=$new_instance_name/" "$INSTANCES_DIR/$new_instance_name/instance_config.ini"

    log_message "${GREEN}Instance renamed from '$instance' to '$new_instance_name'."

   	get_available_instances all
}

# Function to enable/disable instance
enable_disable_instance() {
    local instance=$1
    load_instance_config "$instance" || return 1
	local new_instance_name
    
    # Check if Server are running
	if is_server_running "$instance"; then
        log_message "${YELLOW}Server for instance $instance is running. Please stop it first."
        return 0
    fi

    # Determine new instance name
    if [[ "$instance" == *_off ]]; then
        new_instance_name="${instance%_off}"
    else
        new_instance_name="${instance}_off"
    fi
	
    # Check if new name already exists
    if [ -d "$INSTANCES_DIR/$new_instance_name" ]; then
        log_message "${RED}An instance with the name '$new_instance_name' already exists."
        return 1
    fi	
	
    # Rename instance directory
    mv "$INSTANCES_DIR/$instance" "$INSTANCES_DIR/$new_instance_name" || {
        log_message "${RED}Failed to rename instance directory."
        return 1
    }

    # Rename save directories if they exist
    if [ -d "$SERVER_FILES_DIR/ShooterGame/Saved/$instance" ]; then
        mv "$SERVER_FILES_DIR/ShooterGame/Saved/$instance" "$SERVER_FILES_DIR/ShooterGame/Saved/$new_instance_name" || true
    fi

    if [ -d "$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$instance" ]; then
        mv "$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$instance" "$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$new_instance_name" || true
    fi
    
    # Rename Proton Prefix directories if they exist
    if [ -d "$SERVER_FILES_DIR/steamapps/compatdata/2430930/$instance" ]; then
        mv "$SERVER_FILES_DIR/steamapps/compatdata/2430930/$instance" "$SERVER_FILES_DIR/steamapps/compatdata/2430930/$new_instance_name" || true
    fi

    # Update SaveDir in the instance configuration
    sed -i "s/^SaveDir=.*/SaveDir=$new_instance_name/" "$INSTANCES_DIR/$new_instance_name/instance_config.ini"

    if [[ "$new_instance_name" == *_off ]]; then
		log_message "${GREEN}Instance '$instance' disabled."
    else
		log_message "${GREEN}Instance '$new_instance_name' enabled."
    fi
	
	get_available_instances all
}

# Function to edit GameUserSettins.ini
edit_gameusersettings() {
    local instance=$1
    local file_path="$INSTANCES_DIR/$instance/Config/GameUserSettings.ini"

    #Check if server is running
    if is_server_running "$instance"; then
        log_message "${YELLOW}Server for instance $instance is running. Stop it to edit config"
        return 0
    fi
    if [ ! -f "$file_path" ]; then
        log_message "${RED}Error: No GameUserSettings.ini found. Start the server once to generate one or place your own in the instances/$instance/Config folder."
        return
    fi
	log_message "${GREEN}Open GameUserSettins.ini for '$instance'"
    select_editor "$file_path"
}

# Function to edit Game.ini
edit_game_ini() {
    local instance=$1
    local file_path="$INSTANCES_DIR/$instance/Config/Game.ini"

    #Check if server is running
    if is_server_running "$instance"; then
        log_message "${YELLOW}Server for instance $instance is running. Stop it to edit config"
        return 0
    fi
    if [ ! -f "$file_path" ]; then
        log_message "${YELLOW}Game.ini not found for instance '$instance'. Creating a new one."
        touch "$file_path"
    fi
	log_message "${GREEN}Open Game.ini for '$instance'"
    select_editor "$file_path"
}

# MENU ENTRY: Create a backup of an existing world
menu_backup_world() {
    log_message "${CYAN}Please select an instance to create a backup from:"
    if select_instance; then
        backup_instance_world "$selected_instance"
    fi
}

# MENU ENTRY: Restore an existing backup into an instance
menu_restore_world() {
    log_message "${CYAN}Please select the target instance to restore the backup to:"
    if select_instance; then
        restore_backup_to_instance "$selected_instance"
    fi
}

#Save a world's backup from an instance
backup_instance_world() {
    local instance=$1
	local max_age_hours=6  # ⏱ Hier einstellbar: Nur alle 6 Stunden neues Backup
	
    # Check if the server is running
    if is_server_running "$instance"; then
        log_message "${RED}The server for instance '$instance' is running. Stop it before creating a backup."
        return 0
    fi

	# Create backup directory
	local backups_dir="$BASE_DIR/backups"
	mkdir -p "$backups_dir"


    # ⏱ Find latest backup for this instance
    local latest_backup
    latest_backup=$(find "$backups_dir" -type f -name "${instance}_*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)

    if [[ -n "$latest_backup" ]]; then
        local last_time=$(stat -c %Y "$latest_backup")
        local now=$(date +%s)
        local diff=$(( (now - last_time) / 3600 ))

        if (( diff < max_age_hours )); then
            log_message "${BLUE}⏱ Skipping backup: Last backup for '$instance' was only $diff hours ago (threshold: $max_age_hours h)."
            return 0
        fi
    fi

    # -- List all world folders in $SERVER_FILES_DIR/ShooterGame/Saved/$instance --
    local instance_dir="$SERVER_FILES_DIR/ShooterGame/Saved/$instance"
    if [ ! -d "$instance_dir" ]; then
        log_message "${RED}Instance directory '$instance_dir' not found."
        return 1
    fi

    # Detect world folders
    local worlds=()
	for d in "$instance_dir"/*; do
		[ -d "$d" ] && worlds+=("$(basename "$d")")
	done

    if [ ${#worlds[@]} -eq 0 ]; then
        log_message "${RED}No world folders found for '$instance'."
        return 1
    elif [ ${#worlds[@]} -eq 1 ]; then
        local world_folder="${worlds[0]}"
        log_message "${BLUE}Auto-detected world folder: $world_folder"
    else
        log_message "${YELLOW}Multiple world folders found for '$instance'. Please choose manually:"
        for i in "${!worlds[@]}"; do
            log_message "  [$((i+1))] ${worlds[$i]}"
        done
        return 1
    fi
        

	local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
	local archive_name="${instance}_${world_folder}_${timestamp}.tar.gz"
	local archive_path="$backups_dir/$archive_name"
	log_message "${BLUE}Creating Backup: ${YELLOW}$archive_name"
	tar -czf "$archive_path" -C "$instance_dir" "$world_folder"
	if [ $? -eq 0 ]; then
		log_message "${GREEN}✅ Backup successfully created: ${YELLOW}$archive_name"
	else
		log_message "${RED}❌ Error creating the backup."
		return 1
	fi
	
	# Verify archive integrity
	if tar -tzf "$archive_path" > /dev/null 2>&1; then
		log_message "${GREEN}✅ Archive integrity verified."
	else
		log_message "${RED}❌ Backup archive is corrupted. Deleting: ${YELLOW}$archive_name"
		rm -f "$archive_path"
		return 1
	fi
	
	# 🧮 Erzeuge SHA256-Checksumme
	sha256sum "$archive_path" > "${archive_path}.sha256"
	log_message "${GREEN}🔐 SHA256 checksum saved to ${YELLOW}${archive_name}.sha256"	
}

#Load an existing backup (from the backups folder) into a target instance
restore_backup_to_instance() {
    local target_instance=$1

    # Check if the server is running
    if is_server_running "$target_instance"; then
        log_message "${RED}The server for instance '$target_instance' is running. Stop it before restoring a backup."
        return 1
    fi

    local backups_dir="$BASE_DIR/backups"
    set +e
    if [ ! -d "$backups_dir" ]; then
        log_message "${RED}Backup directory '$backups_dir' does not exist."
        return 1
    fi
    set -e

    # Gather all *.tar.gz files in $backups_dir
    local backup_files=()
    while IFS= read -r -d $'\0' file; do
        backup_files+=("$file")
    done < <(find "$backups_dir" -maxdepth 1 -type f -name "*.tar.gz" -print0 | sort -z)

    if [ ${#backup_files[@]} -eq 0 ]; then
        log_message "${RED}No backups found in '$backups_dir'."
        return 1
    fi

    log_message "${CYAN}Select a backup to load into instance '$target_instance':"
    PS3="Selection: "
    select chosen_backup in "${backup_files[@]}" "Cancel"; do
        if [ "$REPLY" -gt 0 ] && [ "$REPLY" -le "${#backup_files[@]}" ]; then
            local backup_file="$chosen_backup"
            log_message "${CYAN}Selected backup: $backup_file"
        elif [ "$REPLY" -eq $((${#backup_files[@]} + 1)) ]; then
            log_message "${YELLOW}Operation canceled."
            return 0
        else
            log_message "${RED}Invalid selection."
            continue
        fi

        # WARNING about overwriting
        log_message "${YELLOW}⚠️ WARNING: Restoring this backup may overwrite existing worlds."
        log_message "Type '${YELLOW}CONFIRM' to proceed, or '${YELLOW}cancel' to abort:"
        read -r user_input
        if [ "$user_input" != "CONFIRM" ]; then
            echo -e "${YELLOW}Operation canceled."
            return 0
        fi

		# ✅ Checksum prüfen
		if [ -f "${backup_file}.sha256" ]; then
			log_message "${BLUE}Verifying SHA256 checksum for backup..."
			if sha256sum -c "${backup_file}.sha256"; then
				log_message "${GREEN}✅ Checksum verified. Backup is valid."
			else
				log_message "${RED}❌ Checksum verification failed! Backup may be corrupted."
				log_message "${RED}Restore aborted to avoid data loss."
				return 1
			fi
		else
			log_message "${BLUE}⚠ No checksum file found for this backup. Skipping integrity check."
		fi

        # Extract the backup into $SERVER_FILES_DIR/ShooterGame/Saved/$target_instance/
        mkdir -p "$SERVER_FILES_DIR/ShooterGame/Saved/$target_instance"
        log_message "${BLUE}Extracting backup..."
        tar -xzf "$backup_file" -C "$SERVER_FILES_DIR/ShooterGame/Saved/$target_instance/"

        if [ $? -eq 0 ]; then
            log_message "${GREEN}✅ Backup successfully loaded into instance '$target_instance'."
        else
            log_message "${RED}❌ Error extracting the backup."
        fi

        break
    done
}

#Save a world's backup from an instance via CLI
backup_instance_world_cli() {
    local instance=$1
    local world_folder=$2

    # Check if the server is running
    if is_server_running "$instance"; then
        log_message "${RED}The server for instance '$instance' is running. Please stop it first."
        return 1
    fi

    local instance_dir="$SERVER_FILES_DIR/ShooterGame/Saved/$instance"
    if [ ! -d "$instance_dir" ]; then
        log_message "${RED}Instance directory '$instance_dir' not found."
        return 1
    fi

    local src_path="$instance_dir/$world_folder"
    if [ ! -d "$src_path" ]; then
        log_message "${RED}World folder '$world_folder' does not exist (${src_path})."
        return 1
    fi

    local backups_dir="$BASE_DIR/backups"
    mkdir -p "$backups_dir"

    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local archive_name="${instance}_${world_folder}_${timestamp}.tar.gz"
    local archive_path="$backups_dir/$archive_name"

    log_message "${CYAN}Creating backup for '$world_folder' in instance '$instance'..."
    tar -czf "$archive_path" -C "$instance_dir" "$world_folder"
    if [ $? -eq 0 ]; then
        log_message "${GREEN}Backup successfully created: $archive_path"
    else
        log_message "${RED}Error creating the backup."
        return 1
    fi
}

#backup folder cleanup
cleanup_backups() {
    local backups_dir="$BASE_DIR/backups"
    local instance_filter="$1"  # optional: nur bestimmte Instanz

    log_message "${CYAN}Cleaning up backups..."

    # 1) Letzte 24h → alles behalten
    # 2) Letzte 7 Tage → 1 pro Tag
    # 3) Letzte 30 Tage → 1 pro Woche
    # 4) Älter → löschen

    # --- Filter anwenden (falls gewünscht)
    local pattern="*.tar.gz"
    if [ -n "$instance_filter" ]; then
        pattern="${instance_filter}_*.tar.gz"
    fi

    # --- Hole Liste der Backups
    mapfile -t backups < <(find "$backups_dir" -type f -name "$pattern" | sort)

    # --- Gruppieren nach Datum (Format: YYYY-MM-DD)
    declare -A daily_map weekly_map monthly_map
    local now_ts=$(date +%s)

    for f in "${backups[@]}"; do
        local f_ts=$(stat -c %Y "$f")
        local f_date=$(date -d @"$f_ts" +%F)
        local age_days=$(( (now_ts - f_ts) / 86400 ))

        if (( age_days <= 1 )); then
            #continue  # Behalte alles < 24h
			current_day_map["$f_ts"]="$f"
        elif (( age_days <= 7 )); then
            daily_map["$f_date"]="$f"
        elif (( age_days <= 30 )); then
            local week_id=$(date -d @"$f_ts" +%G-%V)
            weekly_map["$week_id"]="$f"
        elif (( age_days <= 365 )); then
            local month_id=$(date -d @"$f_ts" +%Y-%m)
            monthly_map["$month_id"]="$f"
        else
            # Älter als 1 Jahr → löschen
            log_message "${BLUE}🧹 Deleting old backup: $f"
            rm -f "$f" "${f}.sha256" 2>/dev/null
        fi
    done

    # --- Duplikate entfernen (außer die "letzten")
    for f in "${backups[@]}"; do
        if [[ ! " ${current_day_map[*]} ${daily_map[*]} ${weekly_map[*]} ${monthly_map[*]} " =~ $f ]]; then
            log_message "${BLUE}🧹 Removing redundant backup: $f"
            rm -f "$f" "${f}.sha256" 2>/dev/null
        fi
    done

    log_message "${GREEN}✔ Backup cleanup complete."
}

#Save world
save_instance() {
    local instance="$1"
    local delay=20

    if ! is_server_running "$instance"; then
        log_message "${YELLOW}Instance '$instance' is not running. Skipping saveworld."
        return 0
    fi

    log_message "${CYAN}Sending 'saveworld' to instance '$instance'..."
    send_rcon_command "$instance" "broadcast Server is saving world..."
    local response
    response=$(send_rcon_command "$instance" "saveworld")
	
    if [[ -z "$response" ]]; then
        log_message "${BLUE}⚠ No RCON response received from '$instance'."
    elif [[ "$response" == "World Saved" ]]; then
		 log_message "${GREEN}✅ Save confirmed for '$instance'. RCON response: $response"
	elif echo "$response" | grep -qi "World Saved"; then	
		 log_message "${GREEN}✅ Save confirmed for '$instance'. RCON response: $response"
	else
        log_message "${RED}❌ Unexpected RCON response from '$instance': $response"
    fi
    
	log_message "${CYAN}Waiting ${delay}s to allow save to complete..."
    sleep "$delay"
    return 0

}

#Function to select editor and open a file in editor
select_editor() {
local file_path="$1"

# Open the file in the default text editor
    if [ -n "$EDITOR" ]; then
        "$EDITOR" "$file_path"
    elif command -v nano >/dev/null 2>&1; then
        nano "$file_path"
    elif command -v vim >/dev/null 2>&1; then
        vim "$file_path"
    else
        log_message "${RED}No suitable text editor found. Please edit $file_path manually."
    fi
}

# Menu to edit configuration files
edit_configuration_menu() {
    local instance=$1
    log_message "${CYAN}Choose configuration to edit:"
    options=(
        "Instance Configuration"
        "GameUserSettings.ini"
        "Game.ini"
        "Back"
    )
    PS3="Please select an option: "
    select opt in "${options[@]}"; do
        case "$REPLY" in
            1)
                edit_instance_config "$instance"
                break
                ;;
            2)
                edit_gameusersettings "$instance"
                break
                ;;
            3)
                edit_game_ini "$instance"
                break
                ;;
            4)
                return
                ;;
            *)
                log_message "${RED}Invalid option selected."
                ;;
        esac
    done
}

# Check if a new version is available but not apply it
function checkForUpdate(){
  #tput sc
  log_message "Querying Steam database for latest version..."

  if isUpdateNeeded; then
    #tput rc; tput ed;
    log_message "Current version: ${RED} $instver"
    log_message "Available version: ${GREEN} $bnumber"
    log_message "${RED} Your server needs to be restarted in order to receive the latest update."
#    echo -e "Run \"arkmanager update\" to do so"
    return 1
  else
    #tput rc; tput ed;
    log_message "Current version: ${GREEN} $instver"
    log_message "Available version: ${GREEN} $bnumber"
    log_message "${GREEN} Your server is up to date!"
    return 0
  fi
}

# Check if the server need to be updated
# Return 0 if update is needed, else return 1
function isUpdateNeeded(){
  instver="$(getCurrentVersion)"
  bnumber="$(getAvailableVersion)"
  if [[ -z "$bnumber" || "$bnumber" -eq "$instver" ]]; then
    return 1   # no update needed
  elif checkUpdateManifests; then
    log_message "Build ID changed but manifests have not changed"
    return 1
  else
    return 0   # update needed
  fi
}

# Return the current version number
function getCurrentVersion(){
  if [ -f "${SERVER_FILES_DIR}/steamapps/appmanifest_2430930.acf" ]; then
    while read -r name val; do if [ "${name}" == "{" ]; then parseSteamACF "" "buildid"; break; fi; done <"${SERVER_FILES_DIR}/steamapps/appmanifest_2430930.acf"
  fi
}

# Get the current available server version on steamdb
function getAvailableVersion(){
  rm -f "$(getSteamAppInfoCache)"
  runSteamCMD +app_info_update 1 +app_info_print "2430930" | while read -r name val; do if [ "${name}" == "{" ]; then parseSteamACF ".depots.branches.${appbranch:-public}" "buildid"; break; fi; done
}

# Determine SteamCMD data directory
getSteamAppInfoCache(){
  steamcmdhome="${HOME}"

  local appcachefile="$(
    for d in "$steamcmdhome/.steam/steam" "$steamcmdhome/.steam" "$steamcmdhome/Steam"; do
      if [[ -d "${d}" && -f "${d}/appcache/appinfo.vdf" ]]; then
        stat -c "%Y %n" "${d}/appcache/appinfo.vdf"
      fi
    done |
      sort -n |
      tail -n1 |
      cut -d' ' -f2-
  )"

  if [[ -n "$appcachefile" && -f "$appcachefile" ]]; then
    echo "${appcachefile}"
  else
    echo "${steamcmd_appinfocache:-$steamcmdhome/Steam/appcache/appinfo.vdf}"
  fi
}

# Check if the update manifest matches the current manifest
function checkUpdateManifests(){
  local appinfo="$(runSteamCMD +app_info_print "2430930")"
  if [ -z "$appbranch" ]; then
    appbranch="$(getCurrentBranch)"
  fi
  local hasmanifest=
  while read -r depot manifest <&3; do
    hasmanifest=1
    depot="${depot//\"/}"
    manifest="${manifest//\"/}"
    newmanifest="$(echo "${appinfo}" | while read -r name val; do if [ "${name}" == "{" ]; then parseSteamACF ".depots.${depot}.manifests" "${appbranch:-public}"; break; fi; done)"
    if [[ -z "${newmanifest}" && "${appbranch:-public}" != "public" ]]; then
      newmanifest="$(echo "${appinfo}" | while read -r name val; do if [ "${name}" == "{" ]; then parseSteamACF ".depots.${depot}.manifests" "public"; break; fi; done)"
    fi
    if [ "${newmanifest}" != "${manifest}" ]; then
      return 1
    fi
  done 3< <(sed -n '/^[{]$/,/^[}]$/{/^\t"MountedDepots"$/,/^\t[}]$/{/^\t\t/p}}' "${SERVER_FILES_DIR}/steamapps/appmanifest_2430930.acf")
  if [ -z "$hasmanifest" ]; then
    return 1
  else
    return 0
  fi
}

# Return the installed beta / branch
function getCurrentBranch(){
  if [ -f "${SERVER_FILES_DIR}/steamapps/appmanifest_2430930.acf" ]; then
    while read -r name val; do if [ "${name}" == "{" ]; then parseSteamACF ".UserConfig" "betakey"; break; fi; done <"${SERVER_FILES_DIR}/steamapps/appmanifest_2430930.acf"
  fi
}

# Parse an ACF structure
# $1 is the desired path
# $2 is the desired property
# $3 is the current path
function parseSteamACF(){
  local sname
  while read -r name val; do
    name="${name#\"}"
    name="${name%\"}"
    val="${val#\"}"
    val="${val%\"}"
    if [ "$name" = "}" ]; then
      break
    elif [ "$name" == "{" ]; then
      parseSteamACF "$1" "$2" "${3}.${sname}"
    else
      if [ "$3" == "$1" ] && [ "$name" == "$2" ]; then
        echo "$val"
        break
      fi
      sname="${name}"
    fi
  done
}

# SteamCMD helper function
function runSteamCMD(){
  if [[ -z "${steamcmdhome}" || ! -d "${steamcmdhome}" ]]; then
    steamcmdhome="${HOME}"
  fi
  # shellcheck disable=SC2086
  HOME="${steamcmdhome}" "$STEAMCMD_DIR/steamcmd.sh" +@NoPromptForPassword 1 +force_install_dir "$SERVER_FILES_DIR" +login anonymous "$@" +quit
}

# Function to configure the restart_manager.sh
configure_companion_script() {
    local companion_script="$BASE_DIR/ark_restart_manager.sh"
    if [ ! -f "$companion_script" ]; then
        log_message "${RED}Error: Companion script not found at '$companion_script'."
        return 1
    fi

    log_message "${CYAN}-- Restart Manager Configuration --"

    # 1) Dynamically get all available instances
    get_available_instances
    if [ ${#available_instances[@]} -eq 0 ]; then
        log_message "${RED}No instances found in '$INSTANCES_DIR'. Returning to main menu."
        return 0
    fi

    # Show them to the user
    log_message "${CYAN}Available instances:"
    local i
    for i in "${!available_instances[@]}"; do
        log_message "$((i+1))) ${available_instances[$i]}"
    done
    log_message "Type the numbers of the instances you want to choose (space-separated), or type 'all' to select all."
    read -r user_input

    local selected_instances=()

    # 2) Parse user selection
    if [[ "$user_input" == "all" ]]; then
        selected_instances=("${available_instances[@]}")
    else
        local choices=($user_input)
        for choice in "${choices[@]}"; do
            local idx=$((choice - 1))
            if (( idx >= 0 && idx < ${#available_instances[@]} )); then
                selected_instances+=("${available_instances[$idx]}")
            else
                log_message "${RED}Warning: '$choice' is not a valid selection and will be ignored."
            fi
        done
    fi

    if [ ${#selected_instances[@]} -eq 0 ]; then
        log_message "${RED}No valid instances selected."
        return 1
    fi

    # 3) Ask for announcement times
    log_message "${CYAN}Enter announcement times in seconds (space-separated), e.g. '1800 1200 600 180 10':"
    read -r -a user_times

    # 4) Ask for corresponding announcement messages
    log_message "${CYAN}Please enter one announcement message for each time above."
    user_messages=()
    for time in "${user_times[@]}"; do
        log_message "Message for $time seconds before restart:"
        read -r msg
        user_messages+=( "$msg" )
    done

    # Build the config block
    local instances_str=""
    for inst in "${selected_instances[@]}"; do
        instances_str+="\"$inst\" "
    done

    local times_str=""
    for t in "${user_times[@]}"; do
        times_str+="$t "
    done

    local messages_str=""
    for m in "${user_messages[@]}"; do
        messages_str+="    \"$m\"\n"
    done

    local new_config_block="# --------------------------------------------- CONFIGURATION STARTS HERE --------------------------------------------- #

# Define your server instances here (use the names you use in ark_instance_manager.sh)
instances=($instances_str)

# Define the exact announcement times in seconds
announcement_times=($times_str)

# Corresponding messages for each announcement time
announcement_messages=(
$messages_str)

# --------------------------------------------- CONFIGURATION ENDS HERE --------------------------------------------- #"

    # Backup companion script
    cp "$companion_script" "$companion_script.bak"

    # Replace old config block with new one via awk
    awk -v new_conf="$new_config_block" '
        BEGIN { skip=0 }
        /# --------------------------------------------- CONFIGURATION STARTS HERE --------------------------------------------- #/ {
            print new_conf
            skip=1
            next
        }
        /# --------------------------------------------- CONFIGURATION ENDS HERE --------------------------------------------- #/ {
            skip=0
            next
        }
        skip==0 { print }
    ' "$companion_script.bak" > "$companion_script"

    log_message "${GREEN}Restart Manager script has been updated successfully."

    # 5) Ask for cron job
    log_message "${CYAN}Would you like to schedule a daily cron job for server restart? [y/N]"
    read -r add_cron
    if [[ "$add_cron" =~ ^[Yy]$ ]]; then
        log_message "${CYAN}At what time should the daily restart occur?"
        log_message "${YELLOW}(Use 24-hour format: HH:MM, e.g., '16:00' for 4 PM or '03:00' for 3 AM)"
        read -r cron_time
        local cron_hour=$(echo "$cron_time" | cut -d':' -f1)
        local cron_min=$(echo "$cron_time" | cut -d':' -f2)

        # 1) Read the current crontab (if any),
        # 2) Remove all lines referencing our manager script,
        # 3) Append a new line with the chosen schedule,
        # 4) Save back to crontab
        ( crontab -l 2>/dev/null | grep -v "$companion_script"
        log_message "$cron_min $cron_hour * * * $companion_script"
        ) | crontab -

        log_message "${GREEN}Cron job scheduled daily at $cron_time."
    fi
}

# Function to run a command with a live dialog
run_with_live_dialog() {
    local output_title="${1:-"Output"}"
    shift
    local gauge_title="$1"
    shift
    local func="$1"
    shift

    # Mindestbreite 40, Maximalbreite 100
    min_width=46
    max_width=100

    gauge_height=5
    log_height=20
    
    # Logfenster
    log_top=1
    log_left=5

    # Gaugefenster
    gauge_top=$(( log_top + log_height ))
    gauge_left=$log_left

    : > "$log_tmp"
    local fifo="/tmp/asa_manager_gauge_fifo_$$"
    mkfifo "$fifo"

    # FIFO bei Abbruch oder Funktionsende löschen
    trap 'rm -f "$fifo"' EXIT

    # Starte die Funktion im Hintergrund, leite stdout (Prozentwerte) in die FIFO
    (
        "$func" "$@" 2>&1 | while IFS= read -r line; do
            if [[ "$line" =~ ^GAUGE:([0-9]{1,3})$ ]]; then
                #echo "$line" >> "$log_tmp"
                echo "${BASH_REMATCH[1]}"
            else

                # Fülle Zeile auf Mindestbreite auf
                line_padded=$(printf "%-${min_width}s" "$line")
                # Brich bei Maximalbreite um
                echo "$line_padded" | fold -s -w $max_width >> "$log_tmp"            
                fi
        done
    ) > "$fifo" &
    local bg_pid=$!
    # Starte dialog im Vordergrund, liest Prozentwerte aus FIFO
    dialog --no-shadow --colors --begin "$log_top" "$log_left" --title "Server-Log" --tailboxbg "$log_tmp" "$log_height" "$max_width" \
        --and-widget \
        --begin "$gauge_top" "$gauge_left" --title "$gauge_title" --gauge "$gauge_title..." "$gauge_height" "$max_width" 0 < "$fifo"

    # Warte auf den Hintergrundprozess, bevor FIFO gelöscht wird!
    wait $bg_pid
    rm -f "$fifo"

    # Jetzt das Log als Textbox anzeigen, die der Benutzer mit OK schließen muss
    dialog --begin 1 5 --no-shadow --title "$output_title" --textbox "$log_tmp" "$log_height" 0
}

# Progress function
gauge_progress() {
    local current_stage=$1
    local total_stages=$2
    local percent=$(( current_stage * 100 / total_stages ))
    #echo "STEP: $current_stage/$total_stages - $percent%"
    echo "GAUGE:$percent"
    sleep 0.1
}

# Main menu using 'select'
main_menu() {
    while true; do
        # Define menu options
        local options=(
            1 "↓   Install/Update Base Server"
            2 "↻   Check Update"
            3 "☰   List Instances"
            4 "+   Create New Instance"
            5 "🛠   Manage Instance"
            6 "▶   Start All Instances"
            7 "■   Stop All Instances"
            8 "↻   Restart All Instances"
            9 "ℹ   Show Running Instances"
            10 "⎌   Backup a World from Instance"
            11 "⎗   Load Backup to Instance"
            12 "⏰  Configure Restart Manager"
        )

        # Display the menu using dialog
        local choice=$(dialog --begin 1 5 --no-shadow --clear --title "ARK Server Instance Management" \
            --menu "Use the arrow keys to navigate and select an option:" 0 50 0 \
            "${options[@]}" 2>&1 >/dev/tty)

        # Clear the screen after the menu
        clear

        # Handle Cancel or Escape
        if [ -z "$choice" ]; then
            #echo -e "${GREEN}Exiting ARK Server Manager. Goodbye!"
            exit 0
        fi

        # Handle user input
        case "$choice" in
            1)
                run_with_live_dialog "" "Install/Update Base Server" install_base_server
                ;;
            2)
                run_with_live_dialog "" "Check Update" checkForUpdate
                ;;
            3)
                run_with_live_dialog "Available Instances:" "List Instances" list_instances
                ;;
            4)
                create_instance
                ;;
            5)
                if select_instance; then
                    manage_instance "$selected_instance"
                fi
                ;;
            6)
                run_with_live_dialog "Start Instances" "Start Instances" start_all_instances
                ;;
            7)
                run_with_live_dialog "Stop Instances" "Stop Instances" stop_all_instances
                ;;
            8)
                run_with_live_dialog "Restart Instances" "Restart Instances" restart_server "all"
                ;;
            9)
                run_with_live_dialog "Show Running Instances" "Show Running Instances" show_running_instances
                ;;
            10)
                if select_instance; then
                    backup_instance_world "$selected_instance"
                fi
                ;;
            11)
                menu_restore_world
                ;;
            12)
                dialog --title "Information" --msgbox "Restart Manager Configuration is not available!"
                ;;
        esac
    done
}

# Instance management menu using 'select'
manage_instance() {
    local start_instance="$1"

    get_available_instances all

    if [ ${#available_instances[@]} -eq 0 ]; then
        log_message "${RED}❌ No instances found."
        return
    fi

    # Index ermitteln, bei dem wir starten sollen
    local index=0
    for i in "${!available_instances[@]}"; do
        if [[ "${available_instances[$i]}" == "$start_instance" ]]; then
            index=$i
            break
        fi
    done

    while true; do
        if (( index < 0 )); then index=0; fi
        if (( index >= ${#available_instances[@]} )); then index=$(( ${#available_instances[@]} - 1 )); fi

        local instance="${available_instances[$index]}"

        local options=(
            1 "▶   Start Server"
            2 "■   Stop Server"
            3 "↻   Restart Server"
            4 "⌨   Open RCON Console"
            5 "✎   Edit Configuration"
            6 "🗺   Change Map"
            7 "🔧   Change Mods"
            8 "ℹ   Check Server Status"
            9 "✏   Change Instance Name"
            10 "⇄   Enable/Disable Instance"
            11 "🗑   Delete Instance"
            12 "↑   Previous Instance"
            13 "↓   Next Instance"
        )

        local choice=$(dialog --begin 1 5 --clear --title "Managing Instance: $instance ($((index + 1))/${#available_instances[@]})" \
            --menu "Choose an option:" 0 0 0 \
            "${options[@]}" 2>&1 >/dev/tty)

        clear

        # Handle Cancel or Escape
        if [ -z "$choice" ]; then
            return
        fi

        case "$choice" in
            1)
                run_with_live_dialog "Server Start" "Server Start" start_server "$instance"
                ;;
            2)
                run_with_live_dialog "Server Stop" "Server Stop" stop_server "$instance"
                ;;
            3)
                run_with_live_dialog "Server Restart" "Server Restart" restart_server "$instance"
                ;;
            4)
                start_rcon_cli "$instance"
                ;;
            5)
                edit_configuration_menu "$instance"
                ;;
            6)
                change_map "$instance"
                ;;
            7)
                change_mods "$instance"
                ;;
            8)
                check_server_status "$instance"
                ;;
            9)
                change_instance_name "$instance"
                instance=$new_instance_name  # Update the instance variable
                ;;
            10)
                enable_disable_instance "$instance"
                ;;
            11)
                delete_instance "$instance"
                ;;
            12)
                if (( index == 0 )); then
                    dialog --msgbox "Already at the first instance." 6 40
                else
                    ((index--))
                fi
                ;;
            13)
                if (( index == ${#available_instances[@]} - 1 )); then
                    dialog --msgbox "Already at the last instance." 6 40
                else
                    ((index++))
                fi
                ;;
        esac
    done
}

# Main script execution
if [ $# -eq 0 ]; then
    main_menu
else
    case $1 in
        update_now)
            if ! checkForUpdate; then
              stop_all_instances
              install_base_server
              start_all_instances
            fi
            ;;
        update)
              run_with_live_dialog "Install/Update Base Server" install_base_server
            ;;
        update_check)
            checkForUpdate
            ;;
        restart_all)
            $ARK_RESTART_MANAGER
            ;;   
        restart_all_now)
            restart_server "all"    
            ;;   
        setup)
            setup_symlink
            ;;
        start_all)
            start_all_instances
            ;;
        stop_all)
            stop_all_instances
            ;;
        show_running)
            show_running_instances
            ;;
        list_instances)
            list_instances
            ;;
        cleanup_backups)
            cleanup_backups
            ;;
		send_rcon)
			if [ $# -lt 2 ]; then
				log_message "${RED}Usage: $0 send_rcon \"<rcon_command>\""
				exit 1
			fi
			rcon_command="${@:2}"  # Get all arguments from the second onwards
			send_rcon_command_to_all "$rcon_command"
			;;
        delete)
            if [ -z "$2" ]; then
                log_message "${RED}Usage: $0 delete <instance_name>"
                exit 1
            fi
            delete_instance "$2"
            ;;
        *)
            instance_name=$1
            action=$2
            case $action in
                start)
                    start_server "$instance_name"
                    ;;
                stop)
                    stop_server "$instance_name"
                    ;;
                restart)
                    restart_server "$instance_name"
                    ;;
                send_rcon)
                    if [ $# -lt 3 ]; then
                        log_message "${RED}Usage: $0 <instance_name> send_rcon \"<rcon_command>\""
                        exit 1
                    fi
                    rcon_command="${@:3}"  # Get all arguments from the third onwards
                    send_rcon_command "$instance_name" "$rcon_command"
                    ;;
                backup)
                    if [ $# -lt 3 ]; then
                        log_message "${RED}Usage: $0 $instance_name backup <world_folder>"
                        exit 1
                    fi
                    world_folder=$3
                    backup_instance_world_cli "$instance_name" "$world_folder"
                    ;;
                *)
                    echo -e "${RED}Usage: $0 [update|restart_all|restart_all_now|start_all|stop_all|show_running|delete <instance_name>]"
                    echo -e "${RED}       $0 <instance_name> [start|stop|restart|send_rcon \"<rcon_command>\" |backup <world_folder>]"
                    echo "Or run without arguments to enter interactive mode."
                    exit 1
                    ;;
            esac
            ;;
    esac
fi



