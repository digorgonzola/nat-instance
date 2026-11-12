import os

# The Lambda module reads its configuration and creates boto3 clients at import time, so
# these must be set before any test imports it. Dummy credentials make sure an unmocked
# call fails instead of reaching a real AWS account.
os.environ.update(
    AWS_DEFAULT_REGION='ap-southeast-2',
    AWS_ACCESS_KEY_ID='testing',
    AWS_SECRET_ACCESS_KEY='testing',
    AWS_SESSION_TOKEN='testing',
    ASG_NAME='nat-asg',
    TERMINATION_HOOK_NAME='nat-termination-hook',
    EIP_ALLOCATION_ID='eipalloc-1',
)
