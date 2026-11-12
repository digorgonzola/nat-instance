# Tests

This directory has two test suites:

- `test_*.py`: pytest unit tests for the Lambda function. See [Development](../README.md#development).
- `*_test.go` and `*.tftest.hcl`: Terratest tests for the Terraform module. This file describes them.

## Requirements

- Go (the version in `go.mod`)
- OpenTofu or Terraform. Terratest uses `terraform` if it is on `PATH`, otherwise `tofu`. To choose, set `TERRATEST_TERRAFORM_BINARY=tofu` or `TERRATEST_TERRAFORM_BINARY=terraform`.

## Unit tests

The unit tests do not need AWS credentials:

| Test | What it checks |
| ---- | -------------- |
| `TestRootModuleStructure` | The module files, and the files it reads with `file()` and `templatefile()`, exist. |
| `TestExampleStructure` | Each example has `main.tf`, `variables.tf` and `outputs.tf`. |
| `TestValidateExamples` | `init` and `validate` pass for each example, and so for the root module. |
| `TestNativeTerraformTests` | Runs `nat_instance.tftest.hcl`. It applies the module with mocked providers and checks the instance replacement settings: launch before terminate, the termination hook, the reconcile schedule and the EIP permissions. |

To run them:

```sh
cd tests
go test -v -short -timeout 15m -parallel 4 ./...
```

Each test copies the module to a temporary directory, so no `.terraform` directories or lock files are written to the repository.

## Integration tests

`TestIntegrationPlanExamples` runs `plan` on each example against a real AWS account. It creates nothing. It needs AWS credentials and an existing VPC, because the module reads the VPC, subnets and route tables with data sources:

```sh
export AWS_REGION=ap-southeast-2
export NAT_TEST_VPC_ID=vpc-0123456789abcdef0
export NAT_TEST_PUBLIC_SUBNET_IDS=subnet-0123456789abcdef0,subnet-0123456789abcdef1
export NAT_TEST_PRIVATE_SUBNET_IDS=subnet-0123456789abcdef2,subnet-0123456789abcdef3

cd tests
go test -v -timeout 30m -run TestIntegration ./...
```

If the `NAT_TEST_*` variables are not set, the test is skipped. CI runs with `-short`, which skips it.
