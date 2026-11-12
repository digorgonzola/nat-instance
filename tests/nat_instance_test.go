package test

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/gruntwork-io/terratest/modules/files"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

var examples = []string{"minimal", "complete"}

// Terratest prefers terraform over tofu when both are on PATH; this lets CI choose.
func init() {
	if binary := os.Getenv("TERRATEST_TERRAFORM_BINARY"); binary != "" {
		terraform.DefaultExecutable = binary
	}
}

// The provider plugin cache (TF_PLUGIN_CACHE_DIR) is not safe for concurrent init, so
// parallel tests take turns to init and then run in parallel.
var initLock sync.Mutex

func initTerraform(t *testing.T, terraformOptions *terraform.Options) {
	initLock.Lock()
	defer initLock.Unlock()

	terraform.InitContext(t, t.Context(), terraformOptions)
}

// copyModuleToTemp copies the repository to a temporary directory and returns the path of
// moduleDir inside it, so init does not write .terraform or lock files to the repository.
// It uses the files package instead of test-structure, which pulls in the Kubernetes and AWS
// SDKs and triples the compile time.
func copyModuleToTemp(t *testing.T, moduleDir string) string {
	tempRoot, err := files.CopyTerraformFolderToDest("..", t.TempDir(), "nat-instance")
	require.NoError(t, err)

	return filepath.Join(tempRoot, moduleDir)
}

// TestRootModuleStructure validates the root module files exist, including the files the
// module reads with file() and templatefile().
func TestRootModuleStructure(t *testing.T) {
	t.Parallel()

	for _, file := range []string{
		"main.tf",
		"variables.tf",
		"outputs.tf",
		"versions.tf",
		"src/main.py",
		"templates/cloud-init.tpl",
		"config_files/squid.conf",
	} {
		assert.True(t, files.FileExists(filepath.Join("..", file)), file+" should exist")
	}
}

// TestExampleStructure validates example directories exist with required files
func TestExampleStructure(t *testing.T) {
	t.Parallel()

	for _, example := range examples {
		for _, file := range []string{"main.tf", "variables.tf", "outputs.tf"} {
			assert.True(t, files.FileExists(filepath.Join("..", "examples", example, file)),
				example+" example should have "+file)
		}
	}
}

// TestValidateExamples runs init and validate on each example, which also validates the
// root module. It needs no AWS credentials.
func TestValidateExamples(t *testing.T) {
	t.Parallel()

	for _, example := range examples {
		t.Run(example, func(t *testing.T) {
			t.Parallel()

			exampleDir := copyModuleToTemp(t, filepath.Join("examples", example))

			terraformOptions := &terraform.Options{TerraformDir: exampleDir, NoColor: true}

			initTerraform(t, terraformOptions)
			terraform.ValidateContext(t, t.Context(), terraformOptions)
		})
	}
}

// TestNativeTerraformTests runs tests/*.tftest.hcl. They use mocked providers, so they need
// no AWS credentials.
func TestNativeTerraformTests(t *testing.T) {
	t.Parallel()

	moduleDir := copyModuleToTemp(t, ".")
	terraformOptions := &terraform.Options{TerraformDir: moduleDir, NoColor: true}

	initTerraform(t, terraformOptions)
	terraform.RunTerraformCommandContext(t, t.Context(), terraformOptions, "test", "-no-color")
}

// Integration test - requires AWS credentials and an existing VPC. Plan only: nothing is
// created, so there is nothing to destroy.
func TestIntegrationPlanExamples(t *testing.T) {
	if testing.Short() {
		t.Skip("Skipping integration test in short mode")
	}

	vars := integrationVars(t)
	t.Parallel()

	expectedResources := map[string][]string{
		"minimal": {
			"module.nat_instance.aws_autoscaling_group.nat",
			"module.nat_instance.aws_autoscaling_lifecycle_hook.terminating",
			"module.nat_instance.aws_cloudwatch_event_rule.reconcile",
		},
		"complete": {
			"module.nat_instance.aws_autoscaling_group.nat",
			"module.nat_instance.aws_autoscaling_lifecycle_hook.terminating",
			"module.nat_instance.aws_cloudwatch_event_rule.reconcile",
			"module.nat_instance.aws_eip.nat[0]",
		},
	}

	for _, example := range examples {
		t.Run(example, func(t *testing.T) {
			t.Parallel()

			exampleDir := copyModuleToTemp(t, filepath.Join("examples", example))
			terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
				TerraformDir: exampleDir,
				Vars:         vars,
				NoColor:      true,
				PlanFilePath: filepath.Join(exampleDir, "tfplan"),
			})

			initTerraform(t, terraformOptions)
			terraform.PlanContext(t, t.Context(), terraformOptions)
			plan := terraform.ShowWithStructContext(t, t.Context(), terraformOptions)

			for _, address := range expectedResources[example] {
				terraform.RequirePlannedValuesMapKeyExists(t, plan, address)
			}
		})
	}
}

// integrationVars reads the existing VPC to plan against, and skips the test when it is not
// set. The data sources in the module need real IDs, so placeholder values cannot be used.
func integrationVars(t *testing.T) map[string]interface{} {
	vpcID := os.Getenv("NAT_TEST_VPC_ID")
	publicSubnetIDs := os.Getenv("NAT_TEST_PUBLIC_SUBNET_IDS")
	privateSubnetIDs := os.Getenv("NAT_TEST_PRIVATE_SUBNET_IDS")
	if vpcID == "" || publicSubnetIDs == "" || privateSubnetIDs == "" {
		t.Skip("Set NAT_TEST_VPC_ID, NAT_TEST_PUBLIC_SUBNET_IDS and NAT_TEST_PRIVATE_SUBNET_IDS to run integration tests")
	}

	vars := map[string]interface{}{
		"vpc_id":             vpcID,
		"public_subnet_ids":  strings.Split(publicSubnetIDs, ","),
		"private_subnet_ids": strings.Split(privateSubnetIDs, ","),
	}
	if region := os.Getenv("AWS_REGION"); region != "" {
		vars["aws_region"] = region
	}
	return vars
}
