import json
import logging
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

as_client = boto3.client('autoscaling')
ec2_client = boto3.client('ec2')
cw_client = boto3.client('cloudwatch')


def update_route(route_table_id, instance_id):
    try:
        ec2_client.replace_route(
            DestinationCidrBlock='0.0.0.0/0',
            RouteTableId=route_table_id,
            InstanceId=instance_id
        )
        logger.info(f"Replaced route in {route_table_id} to point to {instance_id}")
    except ClientError as e:
        error_code = e.response['Error']['Code']
        message = e.response['Error']['Message']
        if error_code == 'InvalidRoute.NotFound' or (
                error_code == 'InvalidParameterValue' and "There is no route defined" in message
        ):
            try:
                ec2_client.create_route(
                    DestinationCidrBlock='0.0.0.0/0',
                    RouteTableId=route_table_id,
                    InstanceId=instance_id
                )
                logger.info(f"Created route in {route_table_id} to point to {instance_id}")
            except ClientError as create_error:
                logger.error(f"Failed to create route: {create_error}")
        else:
            logger.error(f"Failed to update route: {e}")


def find_healthy_instance(asg):
    for inst in asg['Instances']:
        logger.info(f"Instance {inst['InstanceId']} - State: {inst['LifecycleState']}, Health: {inst['HealthStatus']}")

    # First prioritize instances in Pending states
    pending_candidates = [
        i for i in asg['Instances']
        if i.get('HealthStatus') == 'Healthy' and i.get('LifecycleState') in [
            'Pending', 'Pending:Wait', 'Pending:Proceed'
        ]
    ]

    # If we find pending instances, return the newest one
    if pending_candidates:
        # Sort by launch time (newest first)
        pending_candidates.sort(key=lambda x: x.get('LaunchTime', 0), reverse=True)
        selected = pending_candidates[0]
        logger.info(f"Found healthy pending instance: {selected['InstanceId']} in state {selected['LifecycleState']}")
        return selected['InstanceId']

    # Otherwise fall back to InService instances
    inservice_candidates = [
        i for i in asg['Instances']
        if i.get('HealthStatus') == 'Healthy' and i.get('LifecycleState') == 'InService'
    ]

    if inservice_candidates:
        # Again, prefer newer instances
        inservice_candidates.sort(key=lambda x: x.get('LaunchTime', 0), reverse=True)
        selected = inservice_candidates[0]
        logger.info(f"Found healthy in-service instance: {selected['InstanceId']}")
        return selected['InstanceId']

    logger.warning("No healthy instance found in ASG")
    return None


def get_asg(asg_name):
    try:
        return as_client.describe_auto_scaling_groups(
            AutoScalingGroupNames=[asg_name]
        )['AutoScalingGroups'][0]
    except ClientError as e:
        logger.error(f"Failed to get ASG {asg_name}: {e}")
        return None


def get_route_table_ids(asg):
    for tag in asg.get('Tags', []):
        if tag['Key'] == 'RouteTableIds':
            return [rt.strip() for rt in tag['Value'].split(',') if rt.strip()]

    logger.warning(f"No RouteTableIds tag found for ASG {asg.get('AutoScalingGroupName')}")
    return []


def update_routes_for_asg(asg_name):
    asg = get_asg(asg_name)
    if not asg:
        return False

    instance_id = find_healthy_instance(asg)
    if not instance_id:
        logger.warning(f"No valid instances found in ASG {asg_name}")
        return False

    route_table_ids = get_route_table_ids(asg)
    if not route_table_ids:
        return False

    for rt_id in route_table_ids:
        update_route(rt_id, instance_id)

    return True


def start_instance_refresh(asg_name):
    asg = get_asg(asg_name)
    if not asg:
        return

    try:
        # logger.info(f"Marking instance {instance_id} as Unhealthy")
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
    if not asg:
        return

    instance_id = find_healthy_instance(asg)
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
    for record in event.get('Records', []):
        try:
            # Check if this is an S3 event
            if 'eventSource' in record and record['eventSource'] == 'aws:s3':
                handle_s3_event(record)
            # Check if this is an SNS notification
            elif 'Sns' in record:
                message = json.loads(record['Sns']['Message'])
                if "LifecycleHookName" in message:
                    asg_name = message.get("AutoScalingGroupName")
                    update_routes_for_asg(asg_name)
                    # handle_lifecycle_event(message)
                elif "AlarmName" in message:
                    handle_alarm_event(message)
                else:
                    logger.warning(f"Unhandled message type: {json.dumps(message)}")
            else:
                logger.warning(f"Unknown record type: {json.dumps(record)}")
        except Exception as e:
            logger.error(f"Failed to process record: {e}")
            logger.error(f"Record content: {json.dumps(record)}")

    return {"statusCode": 200, "body": "Processed notification"}
