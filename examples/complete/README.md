# Complete example

The NAT instance with the optional features turned on:

- An Elastic IP, which the Lambda moves to each replacement instance, so the outbound IP does not change.
- Spot instances across several instance types, with capacity rebalancing.
- Detailed monitoring, extra allowed web domains and tags.

## Usage

The VPC and subnets must already exist. Copy `terraform.tfvars.example` to `terraform.tfvars`, set the IDs, then:

```sh
tofu init
tofu plan
tofu apply
```
