#!/usr/bin/env bash
# Description: A utility to reliably open files in a preferred editor,
#              waiting for completion. It honors $VISUAL/$EDITOR,
#              applies wait flags, and offers interactive configuration.
# Maintainer: ${MAINTAINER}

# ——————————
# Strict mode
# ——————————
# Unofficial bash strict mode
set -euo pipefail
shopt -s errtrace # Ensure ERR trap is inherited by functions, command substitutions, and subshells

# ——————————
# Globals and constants
# ——————————
PROGRAM="${0##*/}"

CONFIG_FILE_PRIMARY="${HOME}/.weditrc"
CONFIG_FILE_SECONDARY="${HOME}/.selected_editor" # Fallback for reading

# Associative array for editor properties. Key: editor command name.
# Value: "wait_flag type" or "type" (if no specific wait flag, e.g., for TTY).
# Type can be "gui" or "tty".
declare -A EDITOR_PROPERTIES
EDITOR_PROPERTIES=(
    ["code"]="--wait gui"
    ["subl"]="--wait gui"
    ["atom"]="--wait gui"
    ["gedit"]="--wait gui"
    ["kate"]="--block gui"
    ["gvim"]="--remote-wait-silent gui"
    ["vim"]="tty"
    ["nvim"]="tty"
    ["nano"]="tty"
    ["emacsclient"]="--no-wait gui" # --no-wait makes emacsclient wait
    ["vi"]="tty" # Common fallback
)

# CLI Flags
FLAG_CONFIG_MODE="false"
FLAG_LIST_MODE="false"
FLAG_NO_WAIT="false"
FLAG_FORCE_WAIT="false" # This flag's utility is mostly to ensure GUI wait flags are active if not default.

# Array for files to edit
declare -a FILES_TO_EDIT_ARR=()

# Chosen editor details (populated by _get_editor_command or interactive_select)
declare -a CHOSEN_EDITOR_CMD_PARTS=()
CHOSEN_EDITOR_NAME=""

# Error messages
ERROR_NO_EDITOR_FOUND="No suitable editor found. Please configure one or install a supported editor."
ERROR_RECURSION_DETECTED="Recursive call to ${PROGRAM} detected. Aborting to prevent infinite loop."

# ——————————
# Usage function
# ——————————
function usage {
    # Description: Displays the help message and exits.
    # Inputs: None
    # Outputs: Prints usage to STDOUT and exits.
    cat <<-EOF
	Usage: ${PROGRAM} [options] [--] <file> [<file>...]
	       ${PROGRAM} [options]

	A utility to reliably open files in a preferred editor, waiting for completion.

	Options:
	  -h, --help         Show this help message and exit.
	  -c, --config       Configure the preferred editor interactively and save to '${CONFIG_FILE_PRIMARY}'.
	                     If a selection is made, ${PROGRAM} will then open '${CONFIG_FILE_PRIMARY}' with the chosen editor.
	  -l, --list         List all detected known editors and their properties.
	  -n, --no-wait      Override default wait behavior; do not add wait flags for GUI editors.
	  -w, --wait         Force waiting behavior (this is default for GUI editors with wait flags and all TTY editors).
	                     This option primarily ensures GUI wait flags are used if they might otherwise be suppressed.

	The editor is chosen based on the following hierarchy:
	1. \$VISUAL environment variable.
	2. \$EDITOR environment variable.
	3. User configuration file ('${CONFIG_FILE_PRIMARY}' or, if not found, '${CONFIG_FILE_SECONDARY}').
	4. System 'editor' alternative (via update-alternatives on Linux).
	5. First available editor from a built-in list of known editors.
	6. Interactive prompt (if no editor is found and no configuration exists yet).
	7. Fallback to 'vi' or 'nano' if available.
	8. Error if no editor can be found.
	EOF
    exit 0
} # End of function usage

# ——————————
# Logging
# ——————————
function log {
    # Description: Prints a message to STDERR.
    # Inputs:
    #   $1 - Message to log.
    # Outputs: Prints to STDERR.
    # Example: log "Informational message."
    if [[ -t 2 ]]; then # Only print to STDERR if it's a TTY
        printf '%s\n' "${PROGRAM}: $1" >&2
    fi
} # End of function log

function fatal {
    # Description: Log an error message to stderr and exit the program.
    #              The last argument can optionally be an integer to specify the exit code.
    #              If the last argument is not an integer, or if no exit code is provided,
    #              defaults to exit code 1.
    # Inputs:
    #   $1         - A string that is either the error message or a format string.
    #   $2..$(N-1) - Optional arguments for the format string.
    #   $N         - Optional: an integer exit code.
    # Outputs: Prints to STDERR. Exits the script.
    # Example: fatal "Error: Invalid input."
    #          fatal "Error: '%s' not found in directory '%s'." "\$filename" "\$directory"
    #          fatal "Error: Command '%s' not found." "\$cmd" 127

    local message_args=()
    local exit_code=1 # Default exit code
    local arg
    local last_arg_index=$(( $# ))

    if [[ $# -gt 0 ]]; then
        arg="${!last_arg_index}" # Get the last argument
        if [[ "$arg" =~ ^[0-9]+$ ]]; then
            exit_code="$arg"
            if [[ $# -gt 1 ]]; then
                message_args=("${@:1:$((last_arg_index - 1))}")
            else
                message_args=("")
            fi
        else
            message_args=("$@")
        fi
    else
        message_args=("An unspecified error occurred.")
    fi

    if (( ${#message_args[@]} == 0 )); then
        printf "${PROGRAM}: Exiting with code %d\n" "$exit_code" >&2
    elif (( ${#message_args[@]} == 1 )); then
        # Ensure the program name is prefixed for clarity
        printf '%s\n' "${PROGRAM}: ${message_args[0]}" >&2
    else
        # shellcheck disable=SC2059 # User intends to use first arg as format string
        printf "${PROGRAM}: ${message_args[0]}\n" "${message_args[@]:1}" >&2
    fi
    exit "$exit_code"
} # End of function fatal

# ——————————
# Argument parsing and dependency checking
# ——————————
function parse_arguments {
    # Description: Parses command-line arguments.
    # Inputs: $@ - The command-line arguments.
    # Outputs: Sets global FLAG_* variables and FILES_TO_EDIT_ARR.
    # Example: parse_arguments "$@"

    # No dependencies to check for this script itself, relies on shell builtins and common commands.

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                ;;
            -c|--config)
                FLAG_CONFIG_MODE="true"
                shift
                ;;
            -l|--list)
                FLAG_LIST_MODE="true"
                shift
                ;;
            -n|--no-wait)
                FLAG_NO_WAIT="true"
                shift
                ;;
            -w|--wait)
                FLAG_FORCE_WAIT="true"
                shift
                ;;
            --)
                shift
                FILES_TO_EDIT_ARR+=("$@")
                break
                ;;
            -*)
                fatal "Unknown option: $1" 2
                ;;
            *)
                FILES_TO_EDIT_ARR+=("$1")
                shift
                ;;
        esac
    done
} # End of function parse_arguments

# ——————————
# Plumbing commands
# ——————————

function _check_recursion_guard {
    # Description: Checks if the script is being recursively invoked.
    # Inputs: None (reads __wedit_INVOKED environment variable)
    # Outputs: Exits if recursion is detected.
    if [[ -n "${__wedit_INVOKED:-}" ]]; then
        fatal "$ERROR_RECURSION_DETECTED" 1
    fi
} # End of function _check_recursion_guard

function _detect_env_editor {
    # Description: Detects editor from $VISUAL or $EDITOR environment variables.
    # Inputs: None (reads $VISUAL, $EDITOR)
    # Outputs: Prints the editor command string if found, otherwise nothing.
    # Example: local editor_cmd; editor_cmd="$(_detect_env_editor)"

    if [[ -n "${VISUAL:-}" ]]; then
        printf '%s\n' "$VISUAL"
        return 0
    elif [[ -n "${EDITOR:-}" ]]; then
        printf '%s\n' "$EDITOR"
        return 0
    fi
    return 1
} # End of function _detect_env_editor

function _load_user_config {
    # Description: Loads editor command from user configuration file.
    #              Checks $CONFIG_FILE_PRIMARY, then $CONFIG_FILE_SECONDARY.
    # Inputs: None
    # Outputs: Prints the editor command string from config if found, otherwise nothing.
    # Example: local user_cfg_editor; user_cfg_editor="$(_load_user_config)"

    local config_file_to_use=""
    if [[ -f "$CONFIG_FILE_PRIMARY" ]]; then
        config_file_to_use="$CONFIG_FILE_PRIMARY"
    elif [[ -f "$CONFIG_FILE_SECONDARY" ]]; then
        config_file_to_use="$CONFIG_FILE_SECONDARY"
    fi

    if [[ -n "$config_file_to_use" ]]; then
        # Format is typically SELECTED_EDITOR="command args..."
        # We need to extract the "command args..." part.
        local line
        line="$(grep -E '^\s*SELECTED_EDITOR\s*=' "$config_file_to_use" | head -n 1)"
        if [[ -n "$line" ]]; then
            # Remove SELECTED_EDITOR= part and unquote.
            # Example: SELECTED_EDITOR="code --wait" -> code --wait
            local editor_val
            editor_val="${line#*=}" # Remove up to first =
            editor_val="${editor_val#"${editor_val%%[![:space:]]*}"}" # Trim leading whitespace
            editor_val="${editor_val%"${editor_val##*[![:space:]]}"}" # Trim trailing whitespace
            # Remove surrounding quotes if any
            if [[ "${editor_val:0:1}" == '"' ]] && [[ "${editor_val: -1}" == '"' ]]; then
                editor_val="${editor_val:1:-1}"
            elif [[ "${editor_val:0:1}" == "'" ]] && [[ "${editor_val: -1}" == "'" ]]; then
                editor_val="${editor_val:1:-1}"
            fi
            printf '%s\n' "$editor_val"
            return 0
        fi
    fi
    return 1
} # End of function _load_user_config

function _detect_system_alternative {
    # Description: Detects system editor alternative (Linux 'update-alternatives').
    # Inputs: None
    # Outputs: Prints the resolved editor command if found, otherwise nothing.
    # Example: local sys_alt_editor; sys_alt_editor="$(_detect_system_alternative)"

    if command -v editor &>/dev/null; then
        local editor_path
        editor_path="$(command -v editor)"
        local real_editor_path
        # readlink -f might not be POSIX, but works on Linux/macOS (with greadlink)
        # For simplicity and target platforms, assume it or equivalent behavior.
        if command -v readlink &>/dev/null && real_editor_path="$(readlink -f "$editor_path")"; then
            if [[ -n "$real_editor_path" ]] && [[ -x "$real_editor_path" ]]; then
                 printf '%s\n' "$real_editor_path"
                 return 0
            fi
        else # Fallback if readlink -f is not available or fails
            if [[ -x "$editor_path" ]]; then # Use the symlink path directly
                printf '%s\n' "$editor_path"
                return 0
            fi
        fi
    fi
    return 1
} # End of function _detect_system_alternative

function _scan_known_editors {
    # Description: Scans for the first available editor from the known list.
    #              The order in EDITOR_PROPERTIES implies preference if multiple are found.
    #              This function respects the order of definition in EDITOR_PROPERTIES.
    # Inputs: None
    # Outputs: Prints the name of the first found known editor, otherwise nothing.
    # Example: local known_ed; known_ed="$(_scan_known_editors)"

    # Bash associative arrays don't preserve insertion order when iterating keys with ${!array[@]}.
    # So, we define an explicit order for scanning.
    local ordered_known_editors=(
        code subl atom gedit kate gvim nvim vim nano emacsclient vi
    )

    local editor_name
    for editor_name in "${ordered_known_editors[@]}"; do
        if [[ -n "${EDITOR_PROPERTIES[$editor_name]}" ]]; then # Check if it's a configured known editor
            if command -v "$editor_name" &>/dev/null; then
                printf '%s\n' "$editor_name"
                return 0
            fi
        fi
    done
    return 1
} # End of function _scan_known_editors

function _apply_wait_flag {
    # Description: Constructs the final editor command array with appropriate wait flags.
    # Inputs:
    #   $1 - Name of the output array to populate (nameref).
    #   $2 - Short name of the editor (e.g., "code", "vim"). Used to look up properties.
    #   $3 - The editor executable command/path.
    #   $@ - Initial arguments for the editor (from $4 onwards).
    # Globals:
    #   FLAG_NO_WAIT - If true, suppress wait flags.
    #   FLAG_FORCE_WAIT - If true, try to ensure waiting.
    #   EDITOR_PROPERTIES - Associative array of editor properties.
    # Outputs: Populates the nameref array with the command and its arguments.
    # Example: local -a cmd_array; _apply_wait_flag cmd_array "code" "code" "--diff"

    local -n out_arr="$1"
    local editor_short_name="$2"
    local editor_executable="$3"
    shift 3
    local -a initial_args=("$@")

    out_arr=("$editor_executable")

    local props="${EDITOR_PROPERTIES[$editor_short_name]:-}" # Default to empty if not found
    local editor_type="tty" # Default to TTY if not known or no props
    local default_wait_flag=""

    if [[ -n "$props" ]]; then
        local -a props_parts
        read -r -a props_parts <<< "$props"
        if (( ${#props_parts[@]} == 2 )); then
            default_wait_flag="${props_parts[0]}"
            editor_type="${props_parts[1]}"
        elif (( ${#props_parts[@]} == 1 )); then
            editor_type="${props_parts[0]}"
        fi
    fi

    local effective_wait_flag=""
    if [[ "$FLAG_NO_WAIT" == "true" ]]; then
        log "Explicit --no-wait: No wait flag will be added for '$editor_short_name'."
        # For emacsclient, its "wait" flag is '--no-wait'.
        # If wedit's --no-wait is active, we should NOT add emacsclient's '--no-wait' flag.
        # This logic is implicitly handled as effective_wait_flag remains empty.
    else
        # Default behavior or FLAG_FORCE_WAIT is true
        if [[ "$editor_type" == "gui" ]] && [[ -n "$default_wait_flag" ]]; then
            local flag_already_present=false
            local arg
            for arg in "${initial_args[@]}"; do
                if [[ "$arg" == "$default_wait_flag" ]]; then
                    flag_already_present=true
                    break
                fi
            done

            if [[ "$flag_already_present" == "true" ]]; then
                log "Wait flag '$default_wait_flag' for '$editor_short_name' is already present in initial arguments."
            else
                effective_wait_flag="$default_wait_flag"
            fi
        elif [[ "$editor_type" == "tty" ]]; then
            log "Terminal editor '$editor_short_name' blocks by default. No wait flag needed."
        fi

        if [[ "$FLAG_FORCE_WAIT" == "true" ]] && [[ "$editor_type" == "gui" ]] && [[ -n "$default_wait_flag" ]] && [[ -z "$effective_wait_flag" ]]; then
            # This case handles if FLAG_FORCE_WAIT is set, and the flag wasn't set to be effective yet
            # (e.g., it was already present, but user insists with --wait).
            # However, if it's already present, adding it again is usually not desired.
            # The main effect of FLAG_FORCE_WAIT is to ensure GUI editors use their wait flag if one is defined for them.
            # This is largely covered by the default path when FLAG_NO_WAIT is false.
            log "Flag --wait active: ensuring wait flag for '$editor_short_name' if applicable."
            if [[ -z "$effective_wait_flag" ]]; then # If not already decided to add it
                 effective_wait_flag="$default_wait_flag" # Re-affirm adding it
            fi
        fi
    fi

    # Add initial arguments
    out_arr+=("${initial_args[@]}")

    # Add the determined wait flag, if any
    if [[ -n "$effective_wait_flag" ]]; then
        out_arr+=("$effective_wait_flag")
        log "Added wait flag '$effective_wait_flag' for '$editor_short_name'."
    fi
} # End of function _apply_wait_flag

function _get_editor_command {
    # Description: Determines the editor command based on the fallback hierarchy.
    #              Does NOT handle interactive selection directly.
    # Inputs: None
    # Outputs: Populates global CHOSEN_EDITOR_CMD_PARTS and CHOSEN_EDITOR_NAME.
    #          Returns 0 on success, 1 if no editor found through non-interactive means.

    CHOSEN_EDITOR_CMD_PARTS=()
    CHOSEN_EDITOR_NAME=""
    local editor_line=""

    editor_line="$(_detect_env_editor)"
    if [[ -n "$editor_line" ]]; then
        read -r -a CHOSEN_EDITOR_CMD_PARTS <<< "$editor_line"
        CHOSEN_EDITOR_NAME="${CHOSEN_EDITOR_CMD_PARTS[0]##*/}" # Basename
        log "Using editor from environment: ${CHOSEN_EDITOR_CMD_PARTS[0]}"
        return 0
    fi

    editor_line="$(_load_user_config)"
    if [[ -n "$editor_line" ]]; then
        read -r -a CHOSEN_EDITOR_CMD_PARTS <<< "$editor_line"
        CHOSEN_EDITOR_NAME="${CHOSEN_EDITOR_CMD_PARTS[0]##*/}" # Basename
        log "Using editor from user config: ${CHOSEN_EDITOR_CMD_PARTS[0]}"
        return 0
    fi

    editor_line="$(_detect_system_alternative)"
    if [[ -n "$editor_line" ]]; then
        # editor_line here is the resolved path to the executable
        CHOSEN_EDITOR_CMD_PARTS=("$editor_line") # Command is the full path
        CHOSEN_EDITOR_NAME="${editor_line##*/}"   # Basename for property lookup
        log "Using system alternative editor: $editor_line (resolved to $CHOSEN_EDITOR_NAME)"
        return 0
    fi

    local known_editor_name
    known_editor_name="$(_scan_known_editors)"
    if [[ -n "$known_editor_name" ]]; then
        CHOSEN_EDITOR_CMD_PARTS=("$known_editor_name")
        CHOSEN_EDITOR_NAME="$known_editor_name"
        log "Using detected known editor: $CHOSEN_EDITOR_NAME"
        return 0
    fi

    return 1 # No editor found by non-interactive means
} # End of function _get_editor_command

# ——————————
# Porcelain commands
# ——————————

function _interactive_select {
    # Description: Interactively prompts the user to select an editor from detected known editors.
    #              Saves the choice to $CONFIG_FILE_PRIMARY.
    # Inputs:
    #   $1 (force_prompt_text): Text to display before prompt if forcing. Can be empty.
    # Outputs: Prints the chosen editor command string (just the name, e.g., "code") if a selection is made.
    #          Otherwise, prints nothing.
    # Example: local choice; choice="$(_interactive_select "Please choose an editor:")"

    local force_prompt_text="${1:-}"
    if [[ -n "$force_prompt_text" ]]; then
        printf '%s\n' "$force_prompt_text"
    fi

    local -a available_editors=()
    local -A editor_display_names=(
        ["code"]="Visual Studio Code"
        ["subl"]="Sublime Text"
        ["atom"]="Atom"
        ["gedit"]="gedit (GNOME Text Editor)"
        ["kate"]="Kate (KDE Advanced Text Editor)"
        ["gvim"]="gVim (Graphical Vim)"
        ["vim"]="Vim (Vi IMproved)"
        ["nvim"]="Neovim"
        ["nano"]="Nano"
        ["emacsclient"]="Emacs Client (emacs --daemon)"
        ["vi"]="Vi"
    )

    # Use the same ordered list as _scan_known_editors for consistency
    local ordered_known_editors=(
        code subl atom gedit kate gvim nvim vim nano emacsclient vi
    )

    local editor_name
    for editor_name in "${ordered_known_editors[@]}"; do
        if [[ -n "${EDITOR_PROPERTIES[$editor_name]}" ]]; then # Check if it's a configured known editor
            if command -v "$editor_name" &>/dev/null; then
                available_editors+=("$editor_name")
            fi
        fi
    done

    if (( ${#available_editors[@]} == 0 )); then
        printf "No known editors detected in your PATH. Cannot offer interactive selection.\n" >&2
        printf "Please install one of the supported editors or configure one manually in '%s'.\n" "$CONFIG_FILE_PRIMARY" >&2
        return 1
    fi

    printf "Please select your preferred editor:\n"
    local i=0
    for ed in "${available_editors[@]}"; do
        i=$((i + 1))
        local display_name="${editor_display_names[$ed]:-$ed}"
        printf "  %d. %s (%s)\n" "$i" "$ed" "$display_name"
    done
    printf "  0. Cancel\n"

    local choice_num
    while true; do
        read -r -p "Enter number (0-$((${#available_editors[@]}))): " choice_num
        if [[ "$choice_num" =~ ^[0-9]+$ ]] && (( choice_num >= 0 && choice_num <= ${#available_editors[@]} )); then
            break
        else
            printf "Invalid input. Please enter a number between 0 and %d.\n" "${#available_editors[@]}" >&2
        fi
    done

    if (( choice_num == 0 )); then
        printf "Selection cancelled.\n" >&2
        return 1
    fi

    local selected_editor_name="${available_editors[$((choice_num - 1))]}"

    # Ensure config directory exists
    mkdir -p "$(dirname "$CONFIG_FILE_PRIMARY")"
    # Save to config file
    # Format: SELECTED_EDITOR="editor_name"
    if printf 'SELECTED_EDITOR="%s"\n' "$selected_editor_name" > "$CONFIG_FILE_PRIMARY"; then
        printf "Selected editor '%s' saved to '%s'.\n" "$selected_editor_name" "$CONFIG_FILE_PRIMARY" >&2
        printf '%s\n' "$selected_editor_name" # Output the name for main to use
        return 0
    else
        # The printf to file failed, its exit code will be non-zero.
        printf "Error: Could not write to config file '%s'.\n" "$CONFIG_FILE_PRIMARY" >&2
        return 1
    fi
} # End of function _interactive_select

function list_detected_editors {
    # Description: Lists all known editors and their detection status.
    # Inputs: None
    # Outputs: Prints list to STDOUT.
    # Example: list_detected_editors

    printf "Known editors and their status:\n"
    # Use the same ordered list for consistent output
    local ordered_known_editors=(
        code subl atom gedit kate gvim nvim vim nano emacsclient vi
    )
    local editor_name
    for editor_name in "${ordered_known_editors[@]}"; do
        local props="${EDITOR_PROPERTIES[$editor_name]:-}"
        local editor_type="N/A"
        local wait_flag_info="N/A"

        if [[ -n "$props" ]]; then
            local -a props_parts
            read -r -a props_parts <<< "$props"
            if (( ${#props_parts[@]} == 2 )); then
                wait_flag_info="Wait flag: ${props_parts[0]}"
                editor_type="${props_parts[1]}"
            elif (( ${#props_parts[@]} == 1 )); then
                editor_type="${props_parts[0]}"
                if [[ "$editor_type" == "tty" ]]; then
                    wait_flag_info="Blocks by default"
                else
                    wait_flag_info="No specific wait flag defined"
                fi
            fi
        fi

        local status
        local editor_path
        if command -v "$editor_name" &>/dev/null; then
            editor_path="$(command -v "$editor_name")"
            status="Detected: ${editor_path}"
        else
            status="Not found"
        fi
        printf "  %-12s (%-3s) [%s] %s\n" "$editor_name" "$editor_type" "$status" "$wait_flag_info"
    done
} # End of function list_detected_editors

# ——————————
# Main
# ——————————
function main {
    # Description: Main logic of the script.
    # Inputs: $@ - Original script arguments (passed from execution block).
    # Outputs: Executes the chosen editor or exits with error.
    # Example: main "$@"

    _check_recursion_guard
    parse_arguments "$@" # Populates global flags and FILES_TO_EDIT_ARR

    if [[ "$FLAG_LIST_MODE" == "true" ]]; then
        list_detected_editors
        exit 0
    fi

    local editor_cmd_from_interactive="" # Will hold command string if selected interactively this run

    if [[ "$FLAG_CONFIG_MODE" == "true" ]]; then
        editor_cmd_from_interactive="$(_interactive_select "Configuring preferred editor. This choice will be saved to '${CONFIG_FILE_PRIMARY}'.")"
        if [[ -z "$editor_cmd_from_interactive" ]]; then
            log "Configuration cancelled by user."
            exit 0 # User cancelled, not an error
        fi
        # If config mode, the file to edit is the config file itself
        FILES_TO_EDIT_ARR=("$CONFIG_FILE_PRIMARY")
        if [[ ! -e "${FILES_TO_EDIT_ARR[0]}" ]]; then
            # Create an empty config file if it doesn't exist so editor can open it
            # _interactive_select should have created it, but double check.
            touch "${FILES_TO_EDIT_ARR[0]}" || fatal "Could not create config file: ${FILES_TO_EDIT_ARR[0]}" 1
        fi
        log "Opening config file '${FILES_TO_EDIT_ARR[0]}' with newly selected editor '$editor_cmd_from_interactive'."
    else
        # Normal edit mode: ensure files are specified
        if (( ${#FILES_TO_EDIT_ARR[@]} == 0 )); then
            usage # Exits
        fi

        # Try to get editor command via hierarchy (env, config, system, known)
        if ! _get_editor_command; then # This populates CHOSEN_EDITOR_CMD_PARTS and CHOSEN_EDITOR_NAME
            # _get_editor_command failed. Check if we should do interactive select.
            # (Only if no config file exists - i.e., "first run" scenario)
            if [[ ! -f "$CONFIG_FILE_PRIMARY" ]] && [[ ! -f "$CONFIG_FILE_SECONDARY" ]]; then
                log "No editor found through standard detection and no user configuration exists."
                editor_cmd_from_interactive="$(_interactive_select "No editor configured. Please select one for future use:")"
                if [[ -z "$editor_cmd_from_interactive" ]]; then
                    # User cancelled interactive selection. Try minimal fallbacks before erroring.
                    log "Interactive selection cancelled."
                fi
            fi

            # If still no editor (either interactive select was skipped, or cancelled, or _get_editor_command failed with existing config)
            if [[ -z "$editor_cmd_from_interactive" ]] && (( ${#CHOSEN_EDITOR_CMD_PARTS[@]} == 0 )); then
                log "No editor determined. Attempting final fallbacks (vi, nano)."
                if command -v vi &>/dev/null; then
                    CHOSEN_EDITOR_CMD_PARTS=("vi")
                    CHOSEN_EDITOR_NAME="vi"
                    log "Falling back to 'vi'."
                elif command -v nano &>/dev/null; then
                    CHOSEN_EDITOR_CMD_PARTS=("nano")
                    CHOSEN_EDITOR_NAME="nano"
                    log "Falling back to 'nano'."
                else
                    fatal "$ERROR_NO_EDITOR_FOUND" 1
                fi
            fi
        fi
    fi

    # Consolidate editor choice
    local final_editor_exe
    local -a final_editor_initial_args=()
    local final_editor_short_name # Basename for properties lookup

    if [[ -n "$editor_cmd_from_interactive" ]]; then
        # Editor was chosen interactively in this run (either --config or first-run setup)
        # editor_cmd_from_interactive currently contains just the name, e.g., "code"
        final_editor_exe="$editor_cmd_from_interactive"
        # final_editor_initial_args remains empty unless interactive select is enhanced
        final_editor_short_name="$editor_cmd_from_interactive" # It's already the short name
    else
        # Editor was determined by _get_editor_command (env, config, system, known, or fallback vi/nano)
        if (( ${#CHOSEN_EDITOR_CMD_PARTS[@]} == 0 )); then
             # This should not happen if logic above is correct, but as a safeguard:
            fatal "Internal error: Editor command parts not determined." 1
        fi
        final_editor_exe="${CHOSEN_EDITOR_CMD_PARTS[0]}"
        if (( ${#CHOSEN_EDITOR_CMD_PARTS[@]} > 1 )); then
            final_editor_initial_args=("${CHOSEN_EDITOR_CMD_PARTS[@]:1}")
        fi
        final_editor_short_name="$CHOSEN_EDITOR_NAME" # CHOSEN_EDITOR_NAME is set by _get_editor_command
    fi

    # Ensure final_editor_short_name is a simple name for EDITOR_PROPERTIES lookup
    # It might be a path if it came from $EDITOR or resolved symlink.
    final_editor_short_name="${final_editor_short_name##*/}"

    # Apply wait flags
    local -a exec_command_array=()
    _apply_wait_flag exec_command_array "$final_editor_short_name" "$final_editor_exe" "${final_editor_initial_args[@]}"

    # Set recursion guard and exec
          
local cmd_to_exec="${exec_command_array[0]}"
    local resolved_cmd_path

    # command -v will return the full path if cmd_to_exec is found (either as a name in PATH or an existing command path itself)
    resolved_cmd_path="$(command -v "$cmd_to_exec")"

    if [[ -z "$resolved_cmd_path" ]]; then
        # If command -v returns nothing, it means it's not in PATH and not a valid direct command path.
        fatal "Editor command '${cmd_to_exec}' not found or is not a valid command. Please check your configuration." 127
    fi

    # Now check if the resolved path is executable.
    if [[ ! -x "$resolved_cmd_path" ]]; then
        fatal "Editor command '$resolved_cmd_path' (resolved from '${cmd_to_exec}') is not executable. Please check permissions or configuration." 126
    fi

    # Update the command in the array to the fully resolved path.
    # This is safer and avoids a potential second PATH lookup by exec.
    exec_command_array[0]="$resolved_cmd_path"

    log "Executing: ${exec_command_array[*]} ${FILES_TO_EDIT_ARR[*]}"
    export __wedit_INVOKED=1 # Set recursion guard *just before* exec

    exec "${exec_command_array[@]}" "${FILES_TO_EDIT_ARR[@]}"
    # If exec is successful, the script is replaced by the editor process, and no subsequent lines are executed.
    # If exec itself fails (e.g., command disappears between the check and exec, or other rare OS issues),
    # the shell will print its own error message (e.g., "bash: exec: command: not found") and exit
    # with an appropriate code (typically 127 for not found, 126 for not executable).
    # Therefore, any lines after 'exec' here would be unreachable or redundant for these common failure modes.

} # End of function main

# ——————————
# Execution block
# ——————————
# shellcheck disable=SC2128 # In this context, checking if BASH_SOURCE[0] (script path)
                            # equals $0 (invocation path) is the correct way to determine
                            # if the script is executed directly vs sourced. SC2128 warns
                            # about using BASH_SOURCE without an index if it were ambiguous,
                            # but here BASH_SOURCE[0] (or its first element default) is intended.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    # Setup trap for unexpected errors
    trap 'fatal "An unexpected error occurred. Exiting." $?' ERR

    main "$@"
fi
