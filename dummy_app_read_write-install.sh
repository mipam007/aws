#!/usr/bin/env bash
set -euo pipefail

# === 1. Uninstall ===
echo "> Uninstalling existing systemd services if present..."

# Kill all dummy scripts
for pid in $(ps x | grep '[d]ummy-' | awk '{print $1}'); do
  echo ">> Killing PID $pid"
  kill -9 "$pid"
done

# Disable and remove services if they exist
for service in myapp-writer myapp-reader; do
  if systemctl list-units --full -all | grep -q "$service.service"; then
    echo ">> Disabling $service.service"
    systemctl disable "$service.service" || true
    rm -f "/etc/systemd/system/$service.service"
  fi
done

# Reload systemd
systemctl daemon-reload

for dev in /dev/nvme1n1p1 /dev/nvme2n1p1; do
  mountpoint=$(findmnt --noheadings --output TARGET "$dev" || true)
  if [[ -n "$mountpoint" ]]; then
    echo "Unmounting $dev from $mountpoint..."
    umount "$dev"
  else
    echo "$dev is not mounted."
  fi
done

# === 2. Partition and format ===
for i in $(ls /dev/nvme{1,2}n1); do echo $i; parted --script $i  mklabel gpt mkpart primary xfs 0% 100%; done

sleep 2  # Wait for partitions to register

for i in $(ls /dev/nvme{1,2}n1p1); do echo $i; mkfs.xfs -f $i; done

# === 3. Mount ===
mkdir -p /mnt/nvme{1,2}

mount /dev/nvme1n1p1 /mnt/nvme1
mount /dev/nvme2n1p1 /mnt/nvme2

mkdir -p /mnt/nvme{1,2}/{logs,myapp}
find /mnt/nvme{1,2} -type d -exec chmod 0755 {} +

# === 4. Create dummy-write.sh ===
cat <<'EOF' > /mnt/nvme1/myapp/dummy-write.sh
#!/usr/bin/env bash
set -euo pipefail

log1="/mnt/nvme2/logs/writeapp-write.log"
log2="/mnt/nvme2/logs/writeapp-read.log"

[[ ! -f "$log1" ]] && echo "timestamp,pid,uptime_sec,mem_kb,cpu_time_sec" > "$log1"
[[ ! -f "$log2" ]] && echo "timestamp,pid,uptime_sec,mem_kb,cpu_time_sec" > "$log2"

start_time=$(date +%s)
script_self="/mnt/nvme1/myapp/dummy-write.sh"
script_other="/mnt/nvme2/myapp/dummy-read.sh"
pid_self=$$

while true; do
  now=$(date '+%Y-%m-%d %H:%M:%S')
  uptime_self=$(( $(date +%s) - start_time ))
  mem_self=$(grep VmRSS /proc/$pid_self/status | awk '{print $2}')
  cpu_self=$(ps -p $pid_self -o cputime= | awk '{gsub(":", " "); print ($1*3600 + $2*60 + $3)}')

  echo "$now,$pid_self,$uptime_self,$mem_self,$cpu_self" >> "$log1"

  pid_other=$(ps -eo pid,args | awk -v self="$pid_self" -v other="$script_other" '$0 ~ other && $1 != self {print $1}' | head -n 1 || echo "")
  if [[ -n "$pid_other" ]]; then
    lstart=$(ps -o lstart= -p "$pid_other" 2>/dev/null | xargs || echo "")
    if [[ -n "$lstart" ]]; then
      start_time_other=$(date -d "$lstart" +%s)
      uptime_other=$(( $(date +%s) - start_time_other ))
      mem_other=$(grep VmRSS /proc/$pid_other/status 2>/dev/null | awk '{print $2}')
      cpu_other=$(ps -p $pid_other -o cputime= | awk '{gsub(":", " "); print ($1*3600 + $2*60 + $3)}')
      echo "$now,$pid_other,$uptime_other,${mem_other:-0},${cpu_other:-0}" >> "$log2"
    fi
  fi
  sleep 10
done
EOF
chmod +x /mnt/nvme1/myapp/dummy-write.sh

# === 5. Create dummy-read.sh ===
cat <<'EOF' > /mnt/nvme2/myapp/dummy-read.sh
#!/usr/bin/env bash
set -euo pipefail

log1="/mnt/nvme2/logs/writeapp-write.log"
log2="/mnt/nvme2/logs/writeapp-read.log"
output1="/mnt/nvme1/logs/readapp-write_log_size.log"
output2="/mnt/nvme1/logs/readapp-read_log_size.log"

[[ ! -f "$output1" ]] && echo "timestamp,log1_size_kb,log2_size_kb" > "$output1"
[[ ! -f "$output2" ]] && echo "timestamp,log1_size_kb,log2_size_kb" > "$output2"

while true; do
  now=$(date '+%Y-%m-%d %H:%M:%S')
  size1=$(du -b "$log1" 2>/dev/null | cut -f1 || echo 0)
  size2=$(du -b "$log2" 2>/dev/null | cut -f1 || echo 0)
  echo "$now,$size1,$size2" >> "$output1"
  echo "$now,$size1,$size2" >> "$output2"
  sleep 15
done
EOF
chmod +x /mnt/nvme2/myapp/dummy-read.sh

# === 6. Create systemd unit files ===
echo "> Installing systemd services..."
cat <<EOF > /etc/systemd/system/dummy-write.service
[Unit]
Description=Dummy Writer Service
After=network.target

[Service]
ExecStart=/mnt/nvme1/myapp/dummy-write.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/dummy-read.service
[Unit]
Description=Dummy Reader Service
After=network.target

[Service]
ExecStart=/mnt/nvme2/myapp/dummy-read.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# === 7. Reload systemd and enable services ===
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now dummy-write.service
systemctl enable --now dummy-read.service
systemctl status dummy-write.service
systemctl status dummy-read.service

echo ">>> DONE. Dummy write and read services are now running. <<"

