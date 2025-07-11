# Cloud watch alarm to trigger the lambda function if the squid process stops
resource "aws_cloudwatch_metric_alarm" "squid" {
  alarm_name          = "${local.name}-squid-alarm"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "procstat_lookup_pid_count"
  namespace           = "CWAgent"
  period              = 10
  statistic           = "Minimum"
  threshold           = 1.0
  treat_missing_data  = "breaching"
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.nat.name
    pattern              = "/usr/sbin/squid"
    pid_finder           = "native"
  }
  alarm_actions = [
    aws_sns_topic.alarm.arn,
  ]
}

# SNS topic for alarms
resource "aws_sns_topic" "alarm" {
  name              = "${local.name}-alarm-topic"
  kms_master_key_id = "alias/aws/sns"
}

resource "aws_sns_topic_subscription" "lambda" {
  topic_arn = aws_sns_topic.alarm.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.nat.arn
}
