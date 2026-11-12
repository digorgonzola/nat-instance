# Minimal example

The NAT instance with the module defaults: one on-demand `t4g.small` instance and no Elastic IP. Outbound traffic uses the public IP of the current instance, which changes when the instance is replaced.

## Usage

The VPC and subnets must already exist. Copy `terraform.tfvars.example` to `terraform.tfvars`, set the IDs, then:

```sh
tofu init
tofu plan
tofu apply
```
