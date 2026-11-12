#cloud-config
write_files:
  - path: /etc/rsyslog.d/10-iptables.conf
    permissions: '0644'
    content: |
      # Log iptables messages to a separate file
      :msg, contains, "IPTABLES" /var/log/iptables.log
      & stop
  - path: /etc/logrotate.d/iptables
    permissions: '0644'
    content: |
      /var/log/iptables.log {
          weekly
          rotate 5
          compress
          delaycompress
          notifempty
          missingok
          nocreate
          sharedscripts
          postrotate
              /usr/bin/systemctl reload rsyslog.service > /dev/null 2>&1 || true
          endscript
      }
  - path: /etc/logrotate.d/nat-instance
    permissions: '0644'
    content: |
      /var/log/nat-instance.log {
          weekly
          rotate 5
          compress
          notifempty
          missingok
      }
  - path: /usr/local/bin/nat-healthy
    permissions: '0755'
    content: |
      #!/bin/bash
      # Fails when this instance cannot forward or proxy traffic. Used by the launch self-test
      # and by nat-health-check.timer.
      set -e
      systemctl is-active --quiet squid
      /usr/sbin/squid -k check
      [ "$(sysctl -n net.ipv4.ip_forward)" = "1" ]
      interface=$(ip route | awk '/^default/ {print $5; exit}')
      iptables -t nat -C POSTROUTING -o "$interface" -j MASQUERADE
      for port in 3128 3129 3130; do
        ss -ltn "sport = :$port" | grep -q LISTEN
      done
  - path: /usr/local/bin/nat-health-monitor
    permissions: '0755'
    content: |
      #!/bin/bash
      # After 3 failed checks in a row, restarts squid if squid is the part that failed. After 5,
      # marks the instance Unhealthy. The ASG launches the replacement first, and the Lambda keeps
      # the routes on this instance until the replacement is InService.
      failures_file=/run/nat-health-failures
      if check_output=$(/usr/local/bin/nat-healthy 2>&1); then
        echo 0 > "$failures_file"
        exit 0
      fi

      failures=$(( $(cat "$failures_file" 2>/dev/null || echo 0) + 1 ))
      echo "$failures" > "$failures_file"
      echo "nat-health-check: check failed ($failures in a row): $check_output"

      if [ "$failures" -eq 3 ] && ! /usr/sbin/squid -k check; then
        echo "nat-health-check: restarting squid"
        systemctl restart squid
      elif [ "$failures" -ge 5 ]; then
        token=$(curl -sf --max-time 5 -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
        instance_id=$(curl -sf --max-time 5 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/instance-id)
        echo "nat-health-check: marking $instance_id Unhealthy"
        aws autoscaling set-instance-health --instance-id "$instance_id" --health-status Unhealthy \
          --no-should-respect-grace-period --region ${aws_region}
      fi
  - path: /usr/local/bin/squid-config-sync
    permissions: '0755'
    content: |
      #!/bin/bash
      # Applies the files in the config bucket when they change. If squid rejects them, puts the
      # previous files back and skips those file contents until they change again.
      set -eE
      staging=/var/lib/squid-config
      rejected_file=/var/lib/squid-config.rejected
      mkdir -p "$staging"
      # Bounded so the whole run fits in the unit's TimeoutStartSec.
      timeout 30 aws s3 sync "s3://${s3_bucket}" "$staging" --delete --only-show-errors --region ${aws_region}

      # Regular files only: a "folder" key created in the S3 console syncs as a directory.
      shopt -s nullglob
      names=()
      for file in "$staging"/*; do
        if [ -f "$file" ]; then names+=("$(basename "$file")"); fi
      done
      if [ "$${#names[@]}" -eq 0 ]; then
        echo "squid-config-sync: the config bucket has no files" >&2
        exit 1
      fi

      changed=false
      for name in "$${names[@]}"; do
        cmp -s "$staging/$name" "/etc/squid/$name" || changed=true
      done
      $changed || exit 0

      version=$(cd "$staging" && sha256sum "$${names[@]}" | sha256sum)
      if [ "$version" = "$(cat "$rejected_file" 2>/dev/null)" ]; then
        echo "squid-config-sync: squid rejected this config before, keeping the previous config" >&2
        exit 1
      fi

      # A failure after this point is only the config's fault if squid was running before it.
      if ! systemctl is-active --quiet squid || ! /usr/sbin/squid -k check > /dev/null 2>&1; then
        echo "squid-config-sync: squid is not running, the config from S3 will be applied later" >&2
        exit 1
      fi

      previous=$(mktemp -d)
      added=()
      squid_rejected_config=false
      roll_back() {
        trap - ERR TERM
        echo "squid-config-sync: could not apply the config from S3, restoring the previous config" >&2
        for name in "$${added[@]}"; do rm -f -- "/etc/squid/$name"; done
        cp -a "$previous/." /etc/squid/
        if [ "$1" != terminated ] && $squid_rejected_config; then
          echo "$version" > "$rejected_file"
          echo "squid-config-sync: squid rejected the config, it is skipped until the files change" >&2
        fi
        if ! systemctl is-active --quiet squid || ! /usr/sbin/squid -k check; then
          systemctl restart squid
        fi
        exit 1
      }
      trap roll_back ERR
      trap 'roll_back terminated' TERM

      for name in "$${names[@]}"; do
        if [ -f "/etc/squid/$name" ]; then cp -p "/etc/squid/$name" "$previous/"; else added+=("$name"); fi
        cp "$staging/$name" "/etc/squid/$name"
      done
      squid_rejected_config=true
      /usr/sbin/squid -k parse
      /usr/sbin/squid -k reconfigure
      # reconfigure only signals squid, so check that squid is still running with the new config.
      sleep 5
      systemctl is-active --quiet squid
      /usr/sbin/squid -k check

      trap - ERR TERM
      echo "squid-config-sync: applied the config from S3"
  - path: /etc/systemd/system/nat-health-check.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Check that this NAT instance can forward and proxy traffic

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/nat-health-monitor
      TimeoutStartSec=25s
      StandardOutput=append:/var/log/nat-instance.log
      StandardError=append:/var/log/nat-instance.log
  - path: /etc/systemd/system/nat-health-check.timer
    permissions: '0644'
    content: |
      [Unit]
      Description=Run the NAT instance health check every 30 seconds

      [Timer]
      OnActiveSec=30s
      OnUnitActiveSec=30s
      AccuracySec=1s

      [Install]
      WantedBy=timers.target
  - path: /etc/systemd/system/squid-config-sync.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Apply squid config changes from S3

      [Service]
      Type=oneshot
      ExecStart=/usr/local/bin/squid-config-sync
      TimeoutStartSec=50s
      StandardOutput=append:/var/log/nat-instance.log
      StandardError=append:/var/log/nat-instance.log
  - path: /etc/systemd/system/squid-config-sync.timer
    permissions: '0644'
    content: |
      [Unit]
      Description=Check S3 for squid config changes every minute

      [Timer]
      OnActiveSec=60s
      OnUnitActiveSec=60s
      AccuracySec=5s

      [Install]
      WantedBy=timers.target
  - path: /root/startup.sh
    permissions: '0755'
    content: |
      #!/bin/bash -xeE
      # Redirect the user-data output to the console logs
      exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

      region=${aws_region}
      TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
      instanceid=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)
      asg_name=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/tags/instance/aws:autoscaling:groupName)

      complete_launch() {
        aws autoscaling complete-lifecycle-action \
          --lifecycle-hook-name "${lifecycle_hook_name}" \
          --auto-scaling-group-name "$asg_name" \
          --lifecycle-action-result "$1" \
          --instance-id "$instanceid" \
          --region "$region"
      }

      # Fail the launch straight away instead of waiting for the hook timeout. The previous
      # instance keeps the routes because traffic only moves to an InService instance.
      abandon_launch() {
        trap - ERR
        complete_launch ABANDON
        exit 1
      }
      trap abandon_launch ERR

      # Apply the latest security patches
      yum update -y --security

      # Enable IP forwarding
      echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
      sysctl -p

      # Disable source / destination check. It cannot be disabled from the launch configuration
      aws ec2 modify-instance-attribute --no-source-dest-check --instance-id $instanceid --region $region

      #Install iptables and cron
      yum install cronie -y
      systemctl enable crond.service
      systemctl start crond.service

      yum install iptables-services -y
      systemctl enable iptables
      systemctl start iptables

      # Install and start Squid
      yum install -y squid
      systemctl enable squid

      # Install and start rsyslog-ng
      yum install -y rsyslog
      systemctl enable rsyslog
      systemctl start rsyslog

      # Configure iptables for both proxy and NAT gateway functionality
      iptables -F
      iptables -t nat -F
      iptables -t mangle -F

      # Set default policies
      iptables -P INPUT ACCEPT
      iptables -P FORWARD ACCEPT
      iptables -P OUTPUT ACCEPT

      # Allow loopback traffic
      iptables -A INPUT -i lo -j ACCEPT
      iptables -A OUTPUT -o lo -j ACCEPT

      # Allow established and related connections
      iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
      iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

      # Get the internet-facing interface name
      INTERNET_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -1)

      # Allow SSH access (port 22)
      iptables -A INPUT -p tcp --dport 22 -j ACCEPT

      # Allow Squid proxy ports
      iptables -A INPUT -p tcp --dport 3128 -j ACCEPT
      iptables -A INPUT -p tcp --dport 3129 -j ACCEPT
      iptables -A INPUT -p tcp --dport 3130 -j ACCEPT

      # Log and redirect HTTP traffic to Squid (only for traffic not from local machine)
      iptables -t nat -A PREROUTING -p tcp --dport 80 ! -s 127.0.0.1 -j LOG --log-prefix "IPTABLES HTTP-REDIRECT: " --log-level 4
      iptables -t nat -A PREROUTING -p tcp --dport 80 ! -s 127.0.0.1 -j REDIRECT --to-port 3129

      # Log and redirect HTTPS traffic to Squid (only for traffic not from local machine)
      iptables -t nat -A PREROUTING -p tcp --dport 443 ! -s 127.0.0.1 -j LOG --log-prefix "IPTABLES HTTPS-REDIRECT: " --log-level 4
      iptables -t nat -A PREROUTING -p tcp --dport 443 ! -s 127.0.0.1 -j REDIRECT --to-port 3130

      # Log NAT traffic going out to the internet (sample only some traffic to avoid log spam)
      iptables -t nat -A POSTROUTING -o $INTERNET_INTERFACE -m limit --limit 10/minute -j LOG --log-prefix "IPTABLES NAT-OUT: " --log-level 4
      iptables -t nat -A POSTROUTING -o $INTERNET_INTERFACE -j MASQUERADE

      # Log forwarded traffic from private networks (with rate limiting)
      iptables -A FORWARD -s ${vpc_cidr_block} -m limit --limit 20/minute -j LOG --log-prefix "IPTABLES FORWARD-VPC: " --log-level 4
      iptables -A FORWARD -s ${vpc_cidr_block} -j ACCEPT

      # Allow forwarding for established connections
      iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT

      # Log dropped packets (useful for debugging)
      iptables -A INPUT -m limit --limit 5/minute -j LOG --log-prefix "IPTABLES INPUT-DROP: " --log-level 4
      iptables -A FORWARD -m limit --limit 5/minute -j LOG --log-prefix "IPTABLES FORWARD-DROP: " --log-level 4

      # Save iptables rules
      service iptables save

      # Create a SSL certificate for the SslBump Squid module
      mkdir -p /etc/squid/ssl
      cd /etc/squid/ssl
      openssl genrsa -out squid.key 4096
      openssl req -new -key squid.key -out squid.csr -subj "/C=XX/ST=XX/L=squid/O=squid/CN=squid"
      openssl x509 -req -days 3650 -in squid.csr -signkey squid.key -out squid.crt
      cat squid.key squid.crt >> squid.pem

      # Initialize the SSL certificates database
      /usr/lib64/squid/security_file_certgen -c -s /var/spool/squid/ssl_db -M 4MB
      chown -R squid:squid /var/spool/squid/ssl_db
      chmod -R 750 /var/spool/squid/ssl_db

      # Start Squid service
      systemctl start squid

      # Get the Squid configuration files from S3
      /usr/local/bin/squid-config-sync

      # Retry logic for installing the CloudWatch Agent with a maximum of 5 attempts
      retry=0
      max_retries=5
      while [ $retry -lt $max_retries ]; do
          if rpm -Uvh https://amazoncloudwatch-agent-${aws_region}.s3.${aws_region}.amazonaws.com/amazon_linux/${architecture}/latest/amazon-cloudwatch-agent.rpm; then
              break
          else
              retry=$((retry+1))
              echo "Retry $retry/$max_retries"
              sleep 10
          fi
      done

      if [ $retry -eq $max_retries ]; then
          echo "Failed to install CloudWatch Agent after $max_retries attempts"
          abandon_launch
      fi

      cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
      {
        "logs": {
          "logs_collected": {
            "files": {
              "collect_list": [
                {
                  "file_path": "/var/log/squid/access.log*",
                  "log_group_name": "/nat-instance/access.log",
                  "log_stream_name": "{instance_id}",
                  "timezone": "Local"
                },
                {
                  "file_path": "/var/log/squid/cache.log*",
                  "log_group_name": "/nat-instance/cache.log",
                  "log_stream_name": "{instance_id}",
                  "timezone": "Local"
                },
                {
                  "file_path": "/var/log/iptables.log",
                  "log_group_name": "/nat-instance/iptables.log",
                  "log_stream_name": "{instance_id}",
                  "timezone": "Local"
                },
                {
                  "file_path": "/var/log/nat-instance.log",
                  "log_group_name": "/nat-instance/instance.log",
                  "log_stream_name": "{instance_id}",
                  "timezone": "Local"
                }
              ]
            }

          }
        }
      }
      EOF
      /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

      systemctl daemon-reload
      systemctl enable --now nat-health-check.timer squid-config-sync.timer

      # Self-test before going InService: the Lambda moves routes to this instance as soon
      # as it is InService, so any failure here must abandon the launch instead.
      /usr/local/bin/nat-healthy

      trap - ERR
      complete_launch CONTINUE

runcmd:
  - /root/startup.sh
  - [ systemctl, restart, rsyslog ]
