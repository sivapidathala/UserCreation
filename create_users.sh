#!/usr/bin/env bash
#
# create_users.sh
#
# Usage:
#   sudo bash create_users.sh <userfile>
#
# <userfile> format: username; group1,group2,...
# - Fields separated by semicolon ';'
# - Groups separated by comma ','
#- Ignore whitespace
#
# The script:
# - Ensures it runs as root
# - Creates a personal group for each user (same name as username)
# - Creates any groups listed
# - Creates the user with home directory and correct primary group
# - Adds user to additional groups
# - Generates a random password and applies it
# - Logs actions to /var/log/user_management.log (no plaintext passwords)
# - Stores credentials in /var/secure/user_passwords.csv with perms 600 (owner root only)
#
set -euo pipefail

# Constants
LOGFILE="/var/log/user_management.log"
PASSWORD_DIR="/var/secure"
PASSWORD_FILE="${PASSWORD_DIR}/user_passwords.csv"

# Helpers
timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

log() {
  # Log message to stdout and to logfile with timestamp
  local msg="$1"
  echo "$(timestamp) ${msg}" | tee -a "${LOGFILE}"
}

err_exit() {
  local msg="$1"
  echo "$(timestamp) ERROR: ${msg}" | tee -a "${LOGFILE}" >&2
  exit 1
}

generate_password() {
  # Try openssl, else fallback to /dev/urandom base64 -> strip non-alnum to be safe for passwd
  if command -v openssl >/dev/null 2>&1; then
    # 16 bytes -> base64 -> roughly 22 chars; remove +/= for easier shells
    openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | cut -c1-16
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c16
  fi
}

# Ensure running as root
if [[ "$(id -u)" -ne 0 ]]; then
  err_exit "This script must be run as root. Use sudo."
fi

# Check input file arg
if [[ $# -lt 1 ]]; then
  err_exit "Usage: $0 <users_file>"
fi

USERFILE="$1"
if [[ ! -f "${USERFILE}" ]]; then
  err_exit "User file '${USERFILE}' not found"
fi

# Prepare log & password storage
mkdir -p "$(dirname "${LOGFILE}")"
touch "${LOGFILE}"
chmod 644 "${LOGFILE}"         
# log readable by standard tools; not secret
log "===== Starting user creation run (input: ${USERFILE}) ====="

# Prepare secure directory for password storage
mkdir -p "${PASSWORD_DIR}"
chown root:root "${PASSWORD_DIR}"
chmod 700 "${PASSWORD_DIR}"

# Initialize password file with header if not exist
if [[ ! -f "${PASSWORD_FILE}" ]]; then
  printf "username,password\n" > "${PASSWORD_FILE}"
  chown root:root "${PASSWORD_FILE}"
  chmod 600 "${PASSWORD_FILE}"
fi

# Process each non-empty, non-comment line
while IFS= read -r rawline || [[ -n "$rawline" ]]; do
  # Trim leading/trailing whitespace
  line="$(echo "$rawline" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  # Skip empty and comments
  [[ -z "$line" ]] && continue
  [[ "${line:0:1}" == "#" ]] && continue

  # Expect username;groups
  if ! echo "$line" | grep -q ";"; then
    log "Skipping invalid line (no semicolon): ${line}"
    continue
  fi

  username="$(echo "$line" | cut -d';' -f1 | tr -d '[:space:]')"
  groups_field="$(echo "$line" | cut -d';' -f2-)"   # allow semicolons in groups? (take rest)
  # Normalize whitespace and split groups by comma
  # Remove spaces around commas and trim
  groups_field="$(echo "$groups_field" | sed 's/[[:space:]]*,[[:space:]]*/,/g' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  # Build array of extra groups (may be empty)
  IFS=',' read -r -a extras <<< "$(echo "$groups_field" | tr -d '[:space:]')"

  # Create personal group (username) if not exist
  if getent group "${username}" >/dev/null; then
    log "Personal group '${username}' already exists"
  else
    if groupadd "${username}"; then
      log "Created personal group '${username}'"
    else
      log "Failed to create group '${username}' - continuing"
    fi
  fi

  # Create extra groups if needed; compile final extras list (skip empty strings)
  extra_list=()
  for g in "${extras[@]}"; do
    [[ -z "$g" ]] && continue
    if getent group "${g}" >/dev/null; then
      log "Group '${g}' already exists"
    else
      if groupadd "${g}"; then
        log "Created group '${g}'"
      else
        log "Failed to create group '${g}'"
      fi
    fi
    extra_list+=("$g")
  done

  # Check if user exists
  if id -u "${username}" >/dev/null 2>&1; then
    log "User '${username}' already exists - skipping user creation"
    # Optionally, we could still ensure group memberships; do that:
    if [[ ${#extra_list[@]} -gt 0 ]]; then
      # Add user to listed groups (comma separated)
      joined=$(IFS=, ; echo "${extra_list[*]}")
      if usermod -aG "${joined}" "${username}"; then
        log "Updated groups for existing user '${username}': ${joined}"
      else
        log "Failed to update groups for existing user '${username}'"
      fi
    fi
    continue
  fi

  # Create the user with a home dir and primary group = personal group
  # If there are extras, pass to -G
  if [[ ${#extra_list[@]} -gt 0 ]]; then
    joined=$(IFS=, ; echo "${extra_list[*]}")
    if useradd -m -d "/home/${username}" -s /bin/bash -g "${username}" -G "${joined}" "${username}"; then
      log "Created user '${username}' with primary group '${username}' and supplementary groups: ${joined}"
    else
      log "Failed to create user '${username}'"
      continue
    fi
  else
    if useradd -m -d "/home/${username}" -s /bin/bash -g "${username}" "${username}"; then
      log "Created user '${username}' with primary group '${username}'"
    else
      log "Failed to create user '${username}'"
      continue
    fi
  fi

  # Ensure proper ownership and permissions of home directory
  if chown -R "${username}:${username}" "/home/${username}" && chmod 750 "/home/${username}"; then
    log "Set ownership and permissions for /home/${username}"
  else
    log "Failed to set ownership/permissions for /home/${username}"
  fi

  # Generate password and apply it
  password="$(generate_password)"
  if echo "${username}:${password}" | chpasswd; then
    log "Password set for user '${username}'"
  else
    log "Failed to set password for user '${username}'"
    # continue to store? we skip storing if setting failed
    continue
  fi

  # Store credentials in CSV (username,password) - file already has header
  # Use a temp file to avoid race conditions
  {
    # avoid leaking to log; store silently
    printf "%s,%s\n" "${username}" "${password}" >> "${PASSWORD_FILE}"
    # ensure file still has correct perms/ownership
    chown root:root "${PASSWORD_FILE}"
    chmod 600 "${PASSWORD_FILE}"
  } >/dev/null 2>&1

  log "Stored credentials for '${username}' in secure password file"

done < "${USERFILE}"

log "===== Completed user creation run ====="
exit 0
