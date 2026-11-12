import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

as_client = boto3.client('autoscaling')
ec2_client = boto3.client('ec2')
cw_client = boto3.client('cloudwatch')

# Read once at cold start so a misconfigured function fails immediately rather than mid-failover.
ASG_NAME = os.environ['ASG_NAME']
TERMINATION_HOOK_NAME = os.environ['TERMINATION_HOOK_NAME']
EIP_ALLOCATION_ID = os.environ.get('EIP_ALLOCATION_ID') or None

DEFAULT_ROUTE = '0.0.0.0/0'


class AsgNotFoundError(Exception):
    def __init__(self, asg_name):
        super().__init__(f"Auto Scaling group not found: {asg_name}")
        self.asg_name = asg_name


class RouteTableTagMissingError(Exception):
    def __init__(self, asg_name):
        super().__init__(f"Auto Scaling group {asg_name} has no RouteTableIds tag")
        self.asg_name = asg_name


def get_asg(asg_name):
    groups = as_client.describe_auto_scaling_groups(AutoScalingGroupNames=[asg_name])['AutoScalingGroups']
    if not groups:
        raise AsgNotFoundError(asg_name)
    return groups[0]


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


def point_eip(instance_id):
    address = ec2_client.describe_addresses(AllocationIds=[EIP_ALLOCATION_ID])['Addresses'][0]
    if address.get('InstanceId') == instance_id:
        return

    ec2_client.associate_address(
        AllocationId=EIP_ALLOCATION_ID,
        InstanceId=instance_id,
        AllowReassociation=True,
    )
    logger.info(f"Associated EIP {EIP_ALLOCATION_ID} with {instance_id}")


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


def release_terminating_instances(asg, target_instance_id):
    """Let instances held by the termination hook terminate once traffic has moved off them."""
    for inst in asg['Instances']:
        if inst['LifecycleState'] != 'Terminating:Wait' or inst['InstanceId'] == target_instance_id:
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
    """Point the EIP and private default routes at the newest healthy instance.

    Idempotent; runs on every lifecycle hook notification and on a schedule. While no
    healthy instance exists, routes are left alone so a terminating instance that is
    still forwarding keeps serving traffic until its replacement is InService.
    """
    asg = get_asg(ASG_NAME)
    target_instance_id = select_target_instance(asg)
    if target_instance_id is None:
        logger.warning(f"No InService healthy instance in {ASG_NAME}; leaving routes unchanged")
        return

    # Move the EIP before the routes so forwarded traffic never leaves from the new
    # instance's temporary public IP, which third-party allowlists would reject.
    if EIP_ALLOCATION_ID:
        point_eip(target_instance_id)
    point_default_routes(get_route_table_ids(asg), target_instance_id)
    release_terminating_instances(asg, target_instance_id)


def start_instance_refresh(asg_name):
    try:
        as_client.start_instance_refresh(
            AutoScalingGroupName=asg_name,
            Strategy='Rolling',
            Preferences={
                'MinHealthyPercentage': 100,
                'InstanceWarmup': 60
            }
        )

        logger.info(f"Starting instance refresh for ASG {asg_name}")
    except Exception as e:
        logger.error(f"Error starting instance refresh: {e}")


def terminate_instance(asg_name):
    asg = get_asg(asg_name)
    instance_id = select_target_instance(asg)
    if not instance_id:
        return

    try:
        logger.info(f"Marking instance {instance_id} as Unhealthy")
        as_client.set_instance_health(
            InstanceId=instance_id,
            HealthStatus='Unhealthy',
            ShouldRespectGracePeriod=False
        )

        logger.info(f"Terminating instance {instance_id}")
        as_client.terminate_instance_in_auto_scaling_group(
            InstanceId=instance_id,
            ShouldDecrementDesiredCapacity=False
        )
    except Exception as e:
        logger.error(f"Error terminating instance: {e}")


def handle_alarm_event(message):
    if message.get('NewStateValue') != 'ALARM':
        logger.info(f"Ignoring non-alarm state: {message.get('NewStateValue')}")
        return

    alarm_name = message.get("AlarmName")
    if not alarm_name:
        logger.warning("Alarm message missing AlarmName")
        return

    logger.info(f"Handling alarm {alarm_name}")

    try:
        alarm = cw_client.describe_alarms(AlarmNames=[alarm_name])['MetricAlarms'][0]
        dimensions = alarm.get('Dimensions', [])
        asg_name = next((d['Value'] for d in dimensions if d['Name'] == 'AutoScalingGroupName'), None)
    except Exception as e:
        logger.error(f"Failed to retrieve ASG from alarm: {e}")
        return

    if not asg_name:
        logger.warning("ASG not found in alarm dimensions")
        return

    terminate_instance(asg_name)


def handle_s3_event(record):
    """Handle S3 bucket events"""
    try:
        # Get S3 bucket name and object key from the event
        bucket_name = record['s3']['bucket']['name']
        key = record['s3']['object']['key']
        event_name = record['eventName']

        logger.info(f"Processing S3 event: {event_name} for {bucket_name}/{key}")

        # Get the bucket tags
        s3_client = boto3.client('s3')
        response = s3_client.get_bucket_tagging(Bucket=bucket_name)

        # Find the AutoScalingGroupName tag
        asg_name = next((tag['Value'] for tag in response.get('TagSet', [])
                         if tag['Key'] == 'AutoScalingGroupName'), None)
    except Exception as e:
        logger.error(f"Failed to retrieve ASG from S3 bucket tags: {e}")
        return

    if not asg_name:
        logger.warning("AutoScalingGroupName tag not found in S3 bucket tags")
        return

    start_instance_refresh(asg_name)


def lambda_handler(event, context):
    # Errors propagate so async invocation retries, then the DLQ, see failed route updates.
    if event.get('source') == 'aws.events':
        reconcile_nat_target()
        return {"statusCode": 200, "body": "Reconciled"}

    for record in event.get('Records', []):
        if record.get('eventSource') == 'aws:s3':
            handle_s3_event(record)
        elif 'Sns' in record:
            message = json.loads(record['Sns']['Message'])
            if "LifecycleHookName" in message:
                logger.info(
                    f"Lifecycle {message.get('LifecycleTransition')} for {message.get('EC2InstanceId')}"
                )
                reconcile_nat_target()
            elif "AlarmName" in message:
                handle_alarm_event(message)
            else:
                logger.warning(f"Unhandled message type: {json.dumps(message)}")
        else:
            logger.warning(f"Unknown record type: {json.dumps(record)}")

    return {"statusCode": 200, "body": "Processed notification"}
