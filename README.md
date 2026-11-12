# Nat Instance Module

This Terraform module provisions an Amazon Autoscaling group with an EC2 instance running iptables and squid proxy, allowing for a low-cost alternative to a NAT gateway whilst also providing filtering for outbound http/https traffic.

## Overview

The module creates:
- An Autoscaling group to maintain EC2 instances in a running state
- A Lambda function that moves the private default routes and the Elastic IP to the healthy instance
- Optionally, one Autoscaling group per availability zone, with failover between the zones (see [Availability modes](#availability-modes))
- An S3 bucket for the squid configuration files, which each instance applies when they change
- A cloud-init template to configure iptables, squid, the CloudWatch agent and the instance health check on the EC2 instances
- Cloudwatch log groups for the squid proxy cache and access logs, and Lambda invocation logs

The running instances can be accessed via SSM for debugging purposes.

## Instance replacement and failover

Instance refreshes, capacity rebalancing and health replacements launch the new instance before the old instance terminates. The private routes and the Elastic IP move to the new instance only after it is ready:

1. The new instance starts in `Pending:Wait`. The routes stay on the old instance while the new instance bootstraps.
2. The bootstrap script does a self-test (squid running, IP forwarding on, NAT rule present, proxy ports listening). If the self-test passes, the script completes the launch lifecycle action with `CONTINUE` and the instance goes `InService`. If a step fails, the script completes the action with `ABANDON` and the old instance continues to serve traffic.
3. The Lambda function moves the Elastic IP (when `enable_eip = true`), then the default route in each private route table, to the newest `InService` and `Healthy` instance.
4. A termination lifecycle hook holds the old instance in `Terminating:Wait` until the Lambda has moved the traffic off it. If there is no healthy replacement yet, the hook holds the old instance until one is available, or until the 10-minute heartbeat timeout. In `per_az` mode, an instance of a different AZ can be the replacement (see [Availability modes](#availability-modes)).

The Lambda runs on each lifecycle hook notification and every minute on an EventBridge schedule. The schedule repairs blackholed routes and releases held instances if a notification is lost or a Lambda invocation fails.

Existing TCP connections through the old instance are dropped at cutover because connection-tracking state is not shared between instances. New connections use the new instance.

## Availability modes

`availability_mode` sets how many NAT instances the module runs.

- `single` (default): one Auto Scaling group with one instance serves all the private route tables. If that instance fails without a replacement ready, private subnets have no outbound access until a new instance is `InService`.
- `per_az`: one Auto Scaling group, with one instance, for each availability zone that has private subnets. Each instance serves the route tables of the private subnets in its own AZ, so the traffic of an AZ stays in that AZ. While an AZ has no `InService` and `Healthy` instance, the Lambda moves the routes of that AZ to the instance of another AZ. When the AZ has a healthy instance again, the routes move back. Each Auto Scaling group replaces its instance with the flow above, but the routes do not wait on the old instance for the new one: when the old instance is `Unhealthy` or `Terminating:Wait`, the routes of its AZ move to a different AZ immediately, and the termination hook releases the old instance. The hook holds an instance only when no AZ has a healthy instance.

`per_az` has these requirements and costs:

- Each AZ that has private subnets must also have a public subnet in `public_subnet_ids`.
- The private subnets in each AZ must use their own route tables. A route table that is shared with private subnets in a different AZ fails the plan.
- The module runs one instance for each AZ, and pays for cross-AZ data transfer while an AZ uses the instance of a different AZ.
- The module must read the subnets during the plan, because the AZs are the keys of the Auto Scaling groups. So the subnets must exist before the plan, and the module block must not have `depends_on`.
- With `enable_eip = true`, each instance has its own Elastic IP. Traffic can leave from any of them, because of failover, so add all the addresses in the `public_ips` output to third-party allowlists.

A change from `single` to `per_az`, or back, replaces the Auto Scaling groups and the Elastic IPs. During the apply, the private subnets can have no outbound access for some minutes, until the new instances are `InService`. Do the change in a maintenance window. To keep the current Elastic IP, first apply this module version in `single` mode, which moves the Elastic IP in the state to `aws_eip.nat["single"]`. Then move it to the key of one AZ, for example `tofu state mv 'module.nat.aws_eip.nat["single"]' 'module.nat.aws_eip.nat["ap-southeast-2a"]'`, and then apply `per_az`.

## Instance health

Each instance checks itself every 30 seconds with `nat-health-check.timer`. The check is the same as the bootstrap self-test. After 3 failed checks in a row, the instance restarts squid if squid is the part that failed. After 5 failed checks in a row (about 2.5 minutes) it marks itself `Unhealthy`, and the Auto Scaling group replaces it with the flow above. If the instance stops responding completely, the EC2 status checks fail and the Auto Scaling group replaces it.

Failed checks, squid restarts and the `Unhealthy` call are logged to the `/nat-instance/instance.log` CloudWatch log group, in a stream named after the instance ID. Each failed check names the part that failed, for example `check failed (2 in a row): MASQUERADE rule is missing on ens5`. Passing checks are not logged.

## Squid configuration changes

Each instance checks the S3 bucket for changes every minute with `squid-config-sync.timer`. When a file in the bucket changes, the instance installs it, checks the config with `squid -k parse`, reloads squid with `squid -k reconfigure`, and then checks that squid is still running. The instance is not replaced.

If squid is not running when a change arrives, the instance waits and tries again on the next run. If any step fails, the instance puts the previous files back and restarts squid if it stopped. If squid itself rejected the config, the instance does not try those file contents again until they change; uploading the same contents again does not count as a change. To force a retry, delete `/var/lib/squid-config.rejected` on the instance. The result of each change is logged to the `/nat-instance/instance.log` CloudWatch log group. A rejected config is logged again every minute until it is fixed.

A new instance applies the config from S3 during bootstrap. If squid rejects that config, the launch is abandoned and the current instance keeps serving traffic. So fix a rejected config quickly: until then, the Auto Scaling group cannot replace the instance.

## Usage with Terraform

```hcl
module "nat-instance" {
  source = "git@github.com:<org>/nat-instance.git?ref=v2.3.1"

  additional_egress_rules = {
    mongodb = {
      cidr_ipv4   = "0.0.0.0/0"
      description = "Allow MongoDB connections"
      ip_protocol = "tcp"
      from_port   = 27016
      to_port     = 27017
    }
  }
  allowed_web_domains = [
    ".amazonaws.com",
    "api.sendgrid.com",
  ]
  availability_mode  = "per_az"
  enable_eip         = true
  name               = "myapp-test-nat"
  private_subnet_ids = ["subnet-10a214dfcd63a97a4", "subnet-c727b18850685046b"]
  public_subnet_ids  = ["subnet-37f911e98a8616eee", "subnet-233bfad11fdd81dfd"]
  vpc_id             = "vpc-1eb7bfbe312f068e1"
}
```

## Spot Instances

The module supports running on spot instances to reduce costs. When `enable_spot_instance` is set to `true`, the ASG will request spot capacity using a [mixed instances policy](https://docs.aws.amazon.com/autoscaling/ec2/userguide/mixed-instances-groups.html).

### Instance type diversification

Spot availability varies by instance type and availability zone. To improve the chances of obtaining capacity, provide multiple instance types via `instance_type_overrides`. AWS will select from these pools based on the chosen `spot_allocation_strategy`.

```hcl
module "nat-instance" {
  source = "git@github.com:<org>/nat-instance.git?ref=v3.0.0"

  enable_spot_instance    = true
  instance_type           = "t4g.small"
  instance_type_overrides = ["t4g.small", "t4g.micro", "t4g.medium"]

  # ... other variables
}
```

> **Important:** All instance types in `instance_type_overrides` must share the same CPU architecture as `var.instance_type`, since the AMI is selected based on the primary instance type's architecture. Mixing architectures (e.g. `t4g` ARM64 with `t3a` x86) will cause launch failures.

Compatible ARM64 (Graviton) instance types for NAT workloads:

| Family | Types | Notes |
| --- | --- | --- |
| `t4g` | `t4g.nano`, `t4g.micro`, `t4g.small`, `t4g.medium` | Burstable, lowest cost. Good default for low-to-moderate traffic. |
| `c7g` | `c7g.medium`, `c7g.large` | Compute-optimised Graviton3. Good for higher throughput NAT workloads. |
| `c6g` | `c6g.medium`, `c6g.large` | Compute-optimised Graviton2. Wider availability than c7g in some regions. |
| `m7g` | `m7g.medium`, `m7g.large` | General purpose Graviton3. |
| `m6g` | `m6g.medium`, `m6g.large` | General purpose Graviton2. Wide regional availability. |

For x86-based deployments (when `instance_type` is x86), compatible alternatives include `t3.small`, `t3a.small`, `c5.large`, and `c6i.large`.

### On-demand fallback

By default, when `enable_spot_instance = true` the ASG requests 100% spot capacity. If all spot pools are exhausted, **no instance will launch**. The mixed instances policy uses a fixed ratio, not a priority order — there is no native "prefer spot, fall back to on-demand" for a single-instance ASG. Use `on_demand_base_capacity` and `on_demand_percentage_above_base_capacity` to control the behaviour:

| Scenario | `on_demand_base_capacity` | `on_demand_percentage_above_base_capacity` | Result |
| --- | --- | --- | --- |
| 100% spot (default when spot enabled) | `0` | `0` | Spot only. If unavailable, nothing launches. |
| 100% on-demand (default when spot disabled) | `1` | `100` | On-demand only. Guaranteed availability. |

For a single-instance ASG, the recommendation is to use 100% spot with multiple `instance_type_overrides` to maximise pool diversity. With `price-capacity-optimized` and capacity rebalancing, the probability of exhausting all spot pools simultaneously is very low.

### Capacity rebalancing

When `enable_spot_instance = true`, `capacity_rebalance` is enabled by default. This allows the ASG to proactively replace spot instances that receive an [EC2 rebalance recommendation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/rebalance-recommendations.html) before they are interrupted. Set `capacity_rebalance = false` to disable this behaviour.

### Allocation strategy

The `spot_allocation_strategy` defaults to `price-capacity-optimized`, which AWS recommends for most workloads. This strategy selects spot pools that are both low-cost and have high available capacity, reducing the likelihood of interruption. The `lowest-price` strategy is supported but not recommended, as it cannot be used with capacity rebalancing.

## Development

The `tests/` directory has two test suites. Neither needs AWS credentials. The `Tests` workflow runs both on each pull request to `main`.

The pytest tests cover the Lambda function in `src/main.py`, with mocked AWS clients, and the instance scripts in `templates/cloud-init.tpl`, with stubbed commands. To run them locally, use the Python version of the Lambda runtime in `lambda.tf`:

```sh
python3 -m venv .venv
.venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest
```

The Terraform module has Terratest tests. They validate the [examples](examples/) and run `tests/*.tftest.hcl` with mocked providers. See [tests/README.md](tests/README.md).

## Notes

- The launch template uses the newest Amazon Linux 2023 AMI. When a newer AMI is available, the next apply updates the launch template and starts an instance refresh.

<!-- BEGIN_TF_DOCS -->


## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_additional_egress_rules"></a> [additional\_egress\_rules](#input\_additional\_egress\_rules) | Additional egress rules to apply to the security group. | <pre>map(object({<br/>    name = optional(string)<br/><br/>    cidr_ipv4                    = optional(string)<br/>    cidr_ipv6                    = optional(string)<br/>    description                  = optional(string)<br/>    from_port                    = optional(string)<br/>    ip_protocol                  = optional(string, "tcp")<br/>    prefix_list_id               = optional(string)<br/>    referenced_security_group_id = optional(string)<br/>    tags                         = optional(map(string), {})<br/>    to_port                      = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_additional_ingress_rules"></a> [additional\_ingress\_rules](#input\_additional\_ingress\_rules) | Additional ingress rules to apply to the security group. | <pre>map(object({<br/>    name = optional(string)<br/><br/>    cidr_ipv4                    = optional(string)<br/>    cidr_ipv6                    = optional(string)<br/>    description                  = optional(string)<br/>    from_port                    = optional(string)<br/>    ip_protocol                  = optional(string, "tcp")<br/>    prefix_list_id               = optional(string)<br/>    referenced_security_group_id = optional(string)<br/>    tags                         = optional(map(string), {})<br/>    to_port                      = optional(string)<br/>  }))</pre> | `{}` | no |
| <a name="input_allowed_web_domains"></a> [allowed\_web\_domains](#input\_allowed\_web\_domains) | List of allowed domains. | `list(string)` | <pre>[<br/>  ".amazonaws.com",<br/>  ".amazon.com"<br/>]</pre> | no |
| <a name="input_architectures"></a> [architectures](#input\_architectures) | Lambda function architecture. | `list(string)` | <pre>[<br/>  "arm64"<br/>]</pre> | no |
| <a name="input_availability_mode"></a> [availability\_mode](#input\_availability\_mode) | "single" runs one NAT instance for all private subnets. "per\_az" runs one NAT instance, in its own Auto Scaling group, for each availability zone that has private subnets. Each instance serves the route tables of its own AZ, and also serves another AZ's route tables while that AZ has no healthy instance. per\_az needs a public subnet in each of those AZs and a separate private route table per AZ, and gives each instance its own EIP when enable\_eip is true. | `string` | `"single"` | no |
| <a name="input_capacity_rebalance"></a> [capacity\_rebalance](#input\_capacity\_rebalance) | Whether capacity rebalancing is enabled. When true, the ASG proactively replaces spot instances that receive a rebalance recommendation. | `bool` | `null` | no |
| <a name="input_detailed_monitoring"></a> [detailed\_monitoring](#input\_detailed\_monitoring) | Whether or not to enable detailed monitoring for the EC2 instance. | `bool` | `false` | no |
| <a name="input_enable_eip"></a> [enable\_eip](#input\_enable\_eip) | Whether or not to enable a consistent elastic IP for the EC2 instances. | `bool` | `false` | no |
| <a name="input_enable_spot_instance"></a> [enable\_spot\_instance](#input\_enable\_spot\_instance) | Whether or not to use spot instances for the ASG. | `bool` | `false` | no |
| <a name="input_instance_type"></a> [instance\_type](#input\_instance\_type) | The instance type to use for the ASG. Also used as the primary instance type in the mixed instances policy. | `string` | `"t4g.small"` | no |
| <a name="input_instance_type_overrides"></a> [instance\_type\_overrides](#input\_instance\_type\_overrides) | Additional instance types for the mixed instances policy. Provides more capacity pools for spot and improves availability. When empty, only var.instance\_type is used. | `list(string)` | `[]` | no |
| <a name="input_name"></a> [name](#input\_name) | The name to use for resources. | `string` | `"nat"` | no |
| <a name="input_on_demand_base_capacity"></a> [on\_demand\_base\_capacity](#input\_on\_demand\_base\_capacity) | Minimum number of on-demand instances in the ASG. For a single-instance ASG, set to 1 to guarantee an on-demand instance when spot is unavailable. | `number` | `null` | no |
| <a name="input_on_demand_percentage_above_base_capacity"></a> [on\_demand\_percentage\_above\_base\_capacity](#input\_on\_demand\_percentage\_above\_base\_capacity) | Percentage of instances above the base capacity that should be on-demand. Set to 100 to fall back to on-demand when spot is unavailable. | `number` | `null` | no |
| <a name="input_private_subnet_ids"></a> [private\_subnet\_ids](#input\_private\_subnet\_ids) | List of private subnet ID's in the VPC. | `list(string)` | n/a | yes |
| <a name="input_public_subnet_ids"></a> [public\_subnet\_ids](#input\_public\_subnet\_ids) | List of public subnet ID's to deploy the ASG to. | `list(string)` | n/a | yes |
| <a name="input_spot_allocation_strategy"></a> [spot\_allocation\_strategy](#input\_spot\_allocation\_strategy) | Strategy for allocating spot instances. Valid values: 'capacity-optimized', 'capacity-optimized-prioritized', 'lowest-price', 'price-capacity-optimized'. Note: AWS recommends 'price-capacity-optimized' over 'lowest-price'. | `string` | `"price-capacity-optimized"` | no |
| <a name="input_spot_instance_pools"></a> [spot\_instance\_pools](#input\_spot\_instance\_pools) | Number of spot instance pools across which to allocate instances. Used only when enable\_spot\_instance is true and spot\_allocation\_strategy is 'lowest-price'; ignored otherwise. When null or 0, AWS uses its default of 2. | `number` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to the resources. | `map(string)` | `{}` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | The ID of the VPC to deploy the NAT instance/squid proxy to. | `string` | n/a | yes |
## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_config_bucket"></a> [config\_bucket](#module\_config\_bucket) | terraform-aws-modules/s3-bucket/aws | ~> 5.0 |
| <a name="module_squid_config"></a> [squid\_config](#module\_squid\_config) | terraform-aws-modules/s3-bucket/aws//modules/object | ~> 5.0 |
| <a name="module_whitelist"></a> [whitelist](#module\_whitelist) | terraform-aws-modules/s3-bucket/aws//modules/object | ~> 5.0 |
## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_public_ip"></a> [public\_ip](#output\_public\_ip) | Elastic IP of the NAT instance, or null when enable\_eip is false or availability\_mode is per\_az. |
| <a name="output_public_ips"></a> [public\_ips](#output\_public\_ips) | Elastic IPs of the NAT instances, keyed by availability zone in per\_az mode or "single" in single mode. Empty when enable\_eip is false. Traffic can leave from any of them, so third-party allowlists need all of them. |
## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_archive"></a> [archive](#provider\_archive) | n/a |
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.58 |
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.8 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.58 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.6 |
| <a name="requirement_time"></a> [time](#requirement\_time) | 0.13.1 |
## Resources

| Name | Type |
| ---- | ---- |
| [aws_autoscaling_group.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group) | resource |
| [aws_autoscaling_lifecycle_hook.terminating](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_lifecycle_hook) | resource |
| [aws_cloudwatch_event_rule.reconcile](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.reconcile](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.cache](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.iptables](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_iam_instance_profile.instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_policy.instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.asg_lifecycle](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.asg_lifecycle](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.cloudwatch](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.custom](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.lambda_custom](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.lambda_managed](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_lambda_function.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.lifecycle_sns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_lambda_permission.reconcile_schedule](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_launch_template.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [aws_security_group.instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_sns_topic.asg_lifecycle](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_subscription.lambda_sub](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_sqs_queue.dlq](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_vpc_security_group_egress_rule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [archive_file.lambda_source_code](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file) | data source |
| [aws_ami.amazon_linux_2](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |
| [aws_caller_identity.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_ec2_instance_type.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ec2_instance_type) | data source |
| [aws_iam_policy_document.instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.lambda](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route_table) | data source |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnet) | data source |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |
<!-- END_TF_DOCS -->
