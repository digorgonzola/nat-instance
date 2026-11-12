# Complete example

The NAT instance with the optional features turned on:

- One instance per availability zone that has private subnets, with failover between the zones. Each AZ needs a public subnet and its own private route tables.
- An Elastic IP for each instance, which the Lambda moves to each replacement instance, so the outbound IPs do not change.
- Spot instances across several instance types, with capacity rebalancing.
- Detailed monitoring, extra allowed web domains and tags.

## Usage

The VPC and subnets must already exist. Copy `terraform.tfvars.example` to `terraform.tfvars`, set the IDs, then:

```sh
tofu init
tofu plan
tofu apply
```
