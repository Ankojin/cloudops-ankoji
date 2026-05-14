# Chrony NTP Configuration Scripts

This directory contains scripts to configure Chrony NTP service on multiple Linux servers with a custom NTP server (`10.189.61.9`) via SSH.

## Contents

- **enable-chrony-ntp.sh** - Bash script for single server configuration
- **deploy-chrony-ssh.sh** - SSH-based deployment script for multiple servers
- **servers-example.txt** - Sample server list file

## Prerequisites

### For Single Server Script:
- Root or sudo access on target server
- Supported OS: RHEL, CentOS, Rocky Linux, AlmaLinux, Ubuntu, Debian, SLES, OpenSUSE
- Internet connectivity for package installation

### For Multi-Server SSH Deployment:
- SSH client (OpenSSH) on control machine
- SSH access to target servers (key-based or password)
- Root or sudo privileges on target servers
- Bash shell
- Optional: `sshpass` for password-based authentication

## Usage

### Option 1: Single Server Deployment

1. Copy the script to the target server:
```bash
scp enable-chrony-ntp.sh user@server:/tmp/
```

2. Connect to the server and run the script:
```bash
ssh user@server
sudo bash /tmp/enable-chrony-ntp.sh
```

3. Review the output and log file:
```bash
sudo cat /var/log/chrony-setup-*.log
```

### Option 2: Multiple Servers via SSH

1. **Prepare server list file:**
```bash
cp servers-example.txt servers.txt
nano servers.txt
```

Add your servers (one per line):
```
192.168.1.10
192.168.1.11
192.168.1.12
server1.example.com
```

2. **Deploy using SSH key (recommended):**
```bash
# Using root with default SSH key
./deploy-chrony-ssh.sh -f servers.txt

# Using specific user and key file
./deploy-chrony-ssh.sh -f servers.txt -u admin -k ~/.ssh/id_rsa

# With 10 parallel deployments
./deploy-chrony-ssh.sh -f servers.txt -u admin -k ~/.ssh/id_rsa -j 10
```

3. **Deploy using password authentication:**
```bash
# Requires sshpass to be installed
./deploy-chrony-ssh.sh -f servers.txt -u admin -p 'YourPassword'
```

4. **View deployment results:**
```bash
# Check the summary displayed at the end
# Detailed logs are in: logs/deployment-TIMESTAMP.log
# Per-server logs: logs/SERVER_TIMESTAMP.log
# Results CSV: logs/results-TIMESTAMP.csv
```

## What the Scripts Do
### enable-chrony-ntp.sh (Single Server)
1. **Detect OS** - Identifies the Linux distribution
2. **Install Chrony** - Installs chrony package if not present
3. **Backup Configuration** - Creates timestamped backup of existing config
4. **Configure NTP Server** - Adds `server 10.189.61.9 iburst` to `/etc/chrony.conf`
5. **Disable Old Servers** - Comments out existing server/pool entries
6. **Configure Firewall** - Allows NTP traffic (if firewall is active)
7. **Enable Service** - Enables and starts chronyd/chrony service
8. **Verify Sync** - Checks NTP synchronization status

### deploy-chrony-ssh.sh (Multiple Servers)
1. **Read Server List** - Parses servers from input file
2. **Check SSH Connectivity** - Tests connection to each server
3. **Copy Script** - Transfers enable-chrony-ntp.sh to target servers
4. **Execute Remotely** - Runs configuration script via SSH
5. **Parallel Execution** - Deploys to multiple servers concurrently
6. **Collect Results** - Gathers status from all servers
7. **Generate Reports** - Creates detailed logs and CSV summaryony service
8. **Verify Sync** - Checks NTP synchronization status

## Configuration Details

- **NTP Server:** `10.189.61.9`
- **Config File:** `/etc/chrony.conf`
- **Service Name:** `chronyd` (RHEL/CentOS) or `chrony` (Ubuntu/Debian)
- **Backup Location:** `/etc/chrony.conf.backup.TIMESTAMP`

## Verification

After running the scripts, verify NTP synchronization:

```bash
# Check service status
systemctl status chronyd

# Check tracking status
chronyc tracking

# Check NTP sources
chronyc sources -v

# Check source statistics
chronyc sourcestats

# View configuration
cat /etc/chrony.conf | grep -v "^#" | grep -v "^$"
```

## Troubleshooting

### Service won't start:
```bash
# Check service status
systemctl status chronyd -l

# Check configuration syntax
chronyd -t

# View recent logs
journalctl -u chronyd -n 50
```

### NTP not synchronizing:
```bash
# Check if NTP port is open
ss -tulnp | grep 123

# Check connectivity to NTP server
ping 10.189.61.9

# Force time sync (for testing only)
chronyc makestep

# Check tracking
chronyc tracking
```

### Firewall blocking NTP:
```bash
# RHEL/CentOS with firewalld
firewall-cmd --list-services
firewall-cmd --permanent --add-service=ntp
firewall-cmd --reload

# Ubuntu with ufw
ufw status
ufw allow ntp
```

## Security Considerations

- Scripts require root/sudo privileges
- Configuration backups are created automatically
- Existing NTP servers are commented out (not deleted)
- Firewall rules are added for NTP service
- All actions are logged for audit purposes

## Rollback

To restore previous configuration:

```bash
# Find backup file
ls -lt /etc/chrony.conf.backup.*

# Restore backup
cp /etc/chrony.conf.backup.TIMESTAMP /etc/chrony.conf

# Restart service
systemctl restart chronyd
```

## Support

For issues or questions:
- Check log files: `/var/log/chrony-setup-*.log` (bash script)
- Check Ansible output for detailed error messages
- Review system logs: `journalctl -u chronyd`

## Notes

- The scripts are idempotent - safe to run multiple times
- Existing configurations are preserved as backups
- NTP synchronization may take a few minutes after configuration
- Ensure network connectivity to NTP server 10.189.61.9
- Scripts support major Linux distributions (RHEL, CentOS, Ubuntu, Debian, SLES)
