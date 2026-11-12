import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

as_client = boto3.client('autoscaling')
ec2_client = boto3.client('ec2')

# Read once at cold start so a misconfigured function fails immediately rather than mid-failover.
TERMINATION_HOOK_NAME = os.environ['TERMINATION_HOOK_NAME']
# Maps each NAT ASG name to the allocation ID of the EIP it owns, or "" when EIPs are disabled.
NAT_GROUPS = json.loads(os.environ['NAT_GROUPS'])

DEFAULT_ROUTE = '0.0.0.0/0'


class ReconcileError(Exception):
    """One or more groups could not be reconciled; the other groups were."""

    def __init__(self, failures):
        details = '; '.join(f"{asg_name}: {error!r}" for asg_name, error in failures.items())
        super().__init__(f"Reconcile failed for {details}")
        self.failures = failures


class RouteTableTagMissingError(Exception):
    def __init__(self, asg_name):
        super().__init__(f"Auto Scaling group {asg_name} has no RouteTableIds tag")
        self.asg_name = asg_name


def get_asgs(asg_names):
    """Return the ASGs that exist, in the order given.

    A missing ASG is skipped, not an error: during an apply that adds or removes an AZ, the
    Lambda can be told about an ASG before Terraform has created it, or after it is gone.
    """
    groups = as_client.describe_auto_scaling_groups(AutoScalingGroupNames=asg_names)['AutoScalingGroups']
    groups_by_name = {group['AutoScalingGroupName']: group for group in groups}
    for asg_name in asg_names:
        if asg_name not in groups_by_name:
            logger.warning(f"Auto Scaling group {asg_name} not found; skipping it")
    return [groups_by_name[asg_name] for asg_name in asg_names if asg_name in groups_by_name]


def get_route_table_ids(asg):
    for tag in asg.get('Tags', []):
        if tag['Key'] == 'RouteTableIds':
            route_table_ids = [rt.strip() for rt in tag['Value'].split(',') if rt.strip()]
            if route_table_ids:
                return route_table_ids

    # An empty list would make DescribeRouteTables return every route table in the account.
    raise RouteTableTagMissingError(asg['AutoScalingGroupName'])


def select_target_instance(asg):
    """Return the newest InService, Healthy instance in the ASG, or None.

    Pending instances are never selected: they are still bootstrapping and cannot forward
    traffic until they complete their launch lifecycle action.
    """
    for inst in asg['Instances']:
        logger.info(f"Instance {inst['InstanceId']} - State: {inst['LifecycleState']}, Health: {inst['HealthStatus']}")

    healthy_ids = [
        i['InstanceId'] for i in asg['Instances']
        if i['LifecycleState'] == 'InService' and i['HealthStatus'] == 'Healthy'
    ]
    if not healthy_ids:
        return None

    # The ASG instance list has no launch time, so ask EC2. Preferring the newest instance
    # lets a replacement take over as soon as it is InService.
    reservations = ec2_client.describe_instances(InstanceIds=healthy_ids)['Reservations']
    instances = [inst for reservation in reservations for inst in reservation['Instances']]
    return max(instances, key=lambda inst: inst['LaunchTime'])['InstanceId']


def point_eip(allocation_id, instance_id):
    address = ec2_client.describe_addresses(AllocationIds=[allocation_id])['Addresses'][0]
    if address.get('InstanceId') == instance_id:
        return

    ec2_client.associate_address(
        AllocationId=allocation_id,
        InstanceId=instance_id,
        AllowReassociation=True,
    )
    logger.info(f"Associated EIP {allocation_id} with {instance_id}")


def point_default_routes(route_table_ids, instance_id):
    route_tables = ec2_client.describe_route_tables(RouteTableIds=route_table_ids)['RouteTables']
    for route_table in route_tables:
        route_table_id = route_table['RouteTableId']
        default_route = next(
            (r for r in route_table['Routes'] if r.get('DestinationCidrBlock') == DEFAULT_ROUTE),
            None,
        )

        if default_route is None:
            ec2_client.create_route(
                DestinationCidrBlock=DEFAULT_ROUTE,
                RouteTableId=route_table_id,
                InstanceId=instance_id,
            )
            logger.info(f"Created route in {route_table_id} to point to {instance_id}")
        elif default_route.get('InstanceId') != instance_id or default_route.get('State') != 'active':
            ec2_client.replace_route(
                DestinationCidrBlock=DEFAULT_ROUTE,
                RouteTableId=route_table_id,
                InstanceId=instance_id,
            )
            logger.info(f"Replaced route in {route_table_id} to point to {instance_id}")


def release_terminating_instances(asg):
    """Let instances held by the termination hook terminate once traffic has moved off them.

    Only call this after the routes point at InService instances: a Terminating:Wait
    instance is then never a route target.
    """
    for inst in asg['Instances']:
        if inst['LifecycleState'] != 'Terminating:Wait':
            continue

        try:
            as_client.complete_lifecycle_action(
                LifecycleHookName=TERMINATION_HOOK_NAME,
                AutoScalingGroupName=asg['AutoScalingGroupName'],
                LifecycleActionResult='CONTINUE',
                InstanceId=inst['InstanceId'],
            )
            logger.info(f"Released terminating instance {inst['InstanceId']}")
        except ClientError as e:
            # A concurrent invocation, or the heartbeat timeout, may already have completed it.
            if e.response['Error']['Code'] != 'ValidationError':
                raise
            logger.info(f"Lifecycle action for {inst['InstanceId']} already completed: {e}")


def reconcile_nat_target():
    """Point each group's EIP and private default routes at a healthy instance.

    Each group's route tables use the newest healthy instance in that group. While a group
    has none, its route tables fail over to another group's instance and move back when
    the group has a healthy instance again. While no group has one, routes are left alone
    so a terminating instance that is still forwarding keeps serving traffic until its
    replacement is InService.

    A failure in one group does not stop the others; it is raised as a ReconcileError once
    the others are done. Idempotent; runs on every lifecycle hook notification and on a
    schedule.
    """
    asgs = get_asgs(list(NAT_GROUPS))
    failures = {}
    route_table_ids = {}
    targets = {}

    def for_each_group(action):
        for asg in asgs:
            asg_name = asg['AutoScalingGroupName']
            if asg_name in failures:
                continue
            try:
                action(asg_name, asg)
            except Exception as error:  # noqa: BLE001 - raised after the other groups are done
                logger.exception(f"Reconcile failed for {asg_name}")
                failures[asg_name] = error

    def read_group(asg_name, asg):
        route_table_ids[asg_name] = get_route_table_ids(asg)
        targets[asg_name] = select_target_instance(asg)

    for_each_group(read_group)
    fallback_instance_id = next((target for target in targets.values() if target), None)
    if fallback_instance_id is None:
        logger.warning(f"No InService healthy instance in {', '.join(NAT_GROUPS)}; leaving routes unchanged")
    else:
        # Move every EIP before any route so forwarded traffic, including another AZ's
        # failover traffic, never leaves from a new instance's temporary public IP, which
        # third-party allowlists would reject.
        def move_eip(asg_name, asg):
            if targets[asg_name] and NAT_GROUPS[asg_name]:
                point_eip(NAT_GROUPS[asg_name], targets[asg_name])

        def move_routes(asg_name, asg):
            if targets[asg_name] is None:
                logger.warning(f"No InService healthy instance in {asg_name}; failing over to {fallback_instance_id}")
            point_default_routes(route_table_ids[asg_name], targets[asg_name] or fallback_instance_id)

        for_each_group(move_eip)
        for_each_group(move_routes)
        # Skips groups whose routes failed to move, so their old instance keeps forwarding.
        for_each_group(lambda asg_name, asg: release_terminating_instances(asg))

    if failures:
        raise ReconcileError(failures)


def lambda_handler(event, context):
    # Errors propagate so async invocation retries, then the DLQ, see failed route updates.
    if event.get('source') == 'aws.events':
        reconcile_nat_target()
        return {"statusCode": 200, "body": "Reconciled"}

    for record in event.get('Records', []):
        message = json.loads(record['Sns']['Message']) if 'Sns' in record else {}
        if "LifecycleHookName" in message:
            logger.info(
                f"Lifecycle {message.get('LifecycleTransition')} for {message.get('EC2InstanceId')}"
            )
            reconcile_nat_target()
        elif message.get("Event") == "autoscaling:TEST_NOTIFICATION":
            # Sent once when a lifecycle hook is created.
            logger.info("Ignoring Auto Scaling test notification")
        else:
            logger.warning(f"Unhandled record: {json.dumps(record)}")

    return {"statusCode": 200, "body": "Processed notification"}
