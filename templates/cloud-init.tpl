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
  - path: /root/startup.sh
    permissions: '0755'
    content: |
      #!/bin/bash -xe
      # Redirect the user-data output to the console logs
      exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

      # Apply the latest security patches
      yum update -y --security

      # Enable IP forwarding
      echo 'net.ipv4.ip_forward = 1' >> /etc/sysctl.conf
      sysctl -p

      # Disable source / destination check. It cannot be disabled from the launch configuration
      region=${aws_region}
      TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
      instanceid=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)
      aws ec2 modify-instance-attribute --no-source-dest-check --instance-id $instanceid --region $region

      # Associate the Elastic IP with this instance if an allocation ID is provided
      if [ -n "${eip_allocation_id}" ]; then
        interface_id=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s \
          http://169.254.169.254/latest/meta-data/network/interfaces/macs/ | head -n1)

        eni_id=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s \
          http://169.254.169.254/latest/meta-data/network/interfaces/macs/$${interface_id}interface-id)

        private_ip=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s \
          http://169.254.169.254/latest/meta-data/network/interfaces/macs/$${interface_id}local-ipv4s)

          echo "EIP: ${eip_allocation_id}"
          echo "ENI: $eni_id"
          echo "Private IP: $private_ip"

        aws ec2 associate-address \
          --allocation-id "${eip_allocation_id}" \
          --network-interface-id "$eni_id" \
          --private-ip-address "$private_ip" \
          --allow-reassociation \
          --region "$region"
      fi

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
      aws s3 sync s3://${s3_bucket} /etc/squid
      /usr/sbin/squid -k parse && /usr/sbin/squid -k reconfigure || (cp /etc/squid/old/* /etc/squid/; exit 1)

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
          exit 1
      fi

      cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
      {
        "agent": {
          "metrics_collection_interval": 10,
          "omit_hostname": true
        },
        "metrics": {
          "metrics_collected": {
            "procstat": [
              {
                "pattern": "/usr/sbin/squid",
                "measurement": [
                  "pid_count"
                ]
              }
            ]
          },
          "append_dimensions": {
            "AutoScalingGroupName": "$${aws:AutoScalingGroupName}"
          },
          "force_flush_interval": 5
        },
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
                }
              ]
            }

          }
        }
      }
      EOF
      /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

      # Get the Auto Scaling Group name from instance metadata
      asg_name=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/tags/instance/aws:autoscaling:groupName)

      # Complete the lifecycle action
      aws autoscaling complete-lifecycle-action \
        --lifecycle-hook-name "${lifecycle_hook_name}" \
        --auto-scaling-group-name "$asg_name" \
        --lifecycle-action-result CONTINUE \
        --instance-id "$instanceid" \
        --region $region

runcmd:
  - /root/startup.sh
  - [ systemctl, restart, rsyslog ]
