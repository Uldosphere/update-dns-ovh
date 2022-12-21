# Update DNS OVH

Automate the DNS record's update (OVH) when your server is behind a dynamic IP (Livebox).

The script uses Livebox API to get your current IP address. Then, it gets the A record of your domain (or subdomain) and compares both IP addresses. If they are different, the script continues and updates all records found in your domain by the current Livebox IP address using OVH API.

## General information

The repository content 2 files:
- `update-dns-ovh.sh`: the script you will run
- `README.md`: the file you are reading

We recommend to copy the script in `/usr/local/sbin/update-dns-ovh.sh` and setting up a config file in `/etc/update-dns-ovh.conf` based on variables contained into the script:
```shell
# Livebox vars
LIVEBOX_USERNAME="admin"
LIVEBOX_PASSWORD="yourpassword"
LIVEBOX_LAN_IP="192.168.1.1"

# OVH vars
OVH_ENDPOINT="https://eu.api.ovh.com/1.0"
OVH_AK="mk***********az"                  #Application Key
OVH_AS="ljN*************************nk3"  #Application Secret
OVH_CK="jkf*************************zf6"  #Consumer Key
# Set your domain name
OVH_ZONE_NAME="example.com"
# File where we export the whole DNS zone
OVH_ZONE_BACKUP=/var/lib/backup/zone_backup-${DATE}.txt
# FQDN used to retrieve current IP address assigned in your OVH DNS zone
OVH_FQDN_CONTROL="sub.example.com"
```

You can also change variables:
- directly inside the script
- by setting variables when running the script (ie: `LIVEBOX_PASSWORD=mypass ./update-dns-ovh.sh`)

The script should be scheduled on regular basis (ie: every hour or less). For each record using your dynamic IP, you should also reduce the record TTL (ie: 3600 seconds or less).
