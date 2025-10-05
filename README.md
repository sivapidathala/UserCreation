# UserCreation
Linux User Creation Script

The script aims to:
- Read a list of employees from a text file (format: `user; groups`)
- Automatically create users and their **personal groups**
- Add users to multiple additional groups
- Create home directories with proper permissions
- Generate strong random passwords
- Log every operation for auditing
- Store generated passwords securely in a root-only file

Example Input:
```bash
light; sudo,dev,www-data
idimma; sudo
mayowa; dev,www-data
```

## Design & Implementation Details

### 1. Input format
Each line follows the format:
- Semicolon (`;`) separates the username from group list.  
- Commas (`,`) separate multiple groups.  
- Whitespace and comment lines (`#`) are ignored.  

This makes the file human-readable and script-friendly.

### 2. Root privileges check
User management commands like `useradd` and `groupadd` require root.  
Hence, the script begins with:
```bash
if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi
```


### 3. Personal Groups
Every user has a primary group matching their username:
```bash
useradd -g "$username" "$username"
useradd -g "$username" "$username"
```

### 4. Additional groups
The script automatically creates and assigns extra groups listed in the input file:
```bash
groupadd "$g"
usermod -aG "$g" "$username"
```

### 5. Home directory setup
When a user is created, their home directory (/home/username) is created with:
```bash
useradd -m -d "/home/${username}" ...
chown -R "${username}:${username}" "/home/${username}"
chmod 750 "/home/${username}"
```

`-m` ensures the home directory is created.
Ownership and permissions protect user privacy while allowing controlled group access.

### 6. Random password generation
Security is a priority — each user gets a random 16-character alphanumeric password:
```bash
openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | cut -c1-16
```

Passwords are applied with:
```bash
echo "${username}:${password}" | chpasswd
```

### 7. Secure password storage
Passwords are written to:
```bash
/var/secure/user_passwords.csv
```

This file contains:
```bash
username,password
light,H7sj9Kl82NkQ4fT1
idimma,Pq29LmFJ83gh4Ns2
```
Only the root user can view password.

### 8. Logging
Every action (except passwords) is logged with timestamps in:
```bash
/var/log/user_management.log
```


### 9. Error handling & idempotency

If a user or group already exists, it is skipped gracefully.

Existing users are updated with missing groups.

All errors are logged without interrupting other operations.


### Conclusion

`create_users.sh` automates the most tedious user creation and group assignment task — while maintaining security, consistency, and auditability.

It demonstrates how well-structured Bash scripting can handle real-world administrative challenges securely.

