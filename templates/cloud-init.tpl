#cloud-config
write_files:
  - path: /root/startup.sh
    permissions: '0755'
    content: |
      #!/bin/bash -xe
      # Redirect the user-data output to the console logs
      exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

      # Apply the latest security patches
      yum update -y --security

      # Disable source / destination check. It cannot be disabled from the launch configuration
      region=${aws_region}
      TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
      instanceid=$(curl -H "X-aws-ec2-metadata-token: $TOKEN" -s http://169.254.169.254/latest/meta-data/instance-id)
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
      iptables -F
      iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 3129
      iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 3130

      # Create a SSL certificate for the SslBump Squid module
      mkdir /etc/squid/ssl
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
                  "log_group_name": "/squid-proxy/access.log",
                  "log_stream_name": "{instance_id}",
                  "timezone": "Local"
                },
                {
                  "file_path": "/var/log/squid/cache.log*",
                  "log_group_name": "/squid-proxy/cache.log",
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
        --lifecycle-hook-name squid-asg-hook \
        --auto-scaling-group-name "$asg_name" \
        --lifecycle-action-result CONTINUE \
        --instance-id "$instanceid" \
        --region $region

runcmd:
  - /root/startup.sh
