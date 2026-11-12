import datetime
import json
from unittest import mock

import pytest
from botocore.exceptions import ClientError

import main

T0 = datetime.datetime(2026, 1, 1, tzinfo=datetime.timezone.utc)
LAUNCH_TIMES = {'i-old': T0, 'i-new': T0 + datetime.timedelta(hours=1)}


def asg_response(instances, route_table_ids='rtb-a,rtb-b'):
    return {'AutoScalingGroups': [{
        'AutoScalingGroupName': 'nat-asg',
        'Tags': [{'Key': 'RouteTableIds', 'Value': route_table_ids}],
        'Instances': [
            {'InstanceId': instance_id, 'LifecycleState': state, 'HealthStatus': health}
            for instance_id, state, health in instances
        ],
    }]}


def route_tables_response(target_instance_id, state='active'):
    return {'RouteTables': [
        {'RouteTableId': 'rtb-a', 'Routes': [
            {'DestinationCidrBlock': '0.0.0.0/0', 'InstanceId': target_instance_id, 'State': state},
        ]},
        {'RouteTableId': 'rtb-b', 'Routes': [
            {'DestinationCidrBlock': '10.0.0.0/16', 'GatewayId': 'local'},
        ]},
    ]}


def client_error(code):
    return ClientError({'Error': {'Code': code, 'Message': code}}, 'Operation')


@pytest.fixture
def aws():
    with mock.patch.object(main, 'as_client') as as_client, mock.patch.object(main, 'ec2_client') as ec2_client:
        ec2_client.describe_instances.side_effect = lambda InstanceIds: {'Reservations': [{'Instances': [
            {'InstanceId': i, 'LaunchTime': LAUNCH_TIMES[i]} for i in InstanceIds
        ]}]}
        ec2_client.describe_addresses.return_value = {'Addresses': [{'InstanceId': 'i-old'}]}
        yield mock.Mock(asg=as_client, ec2=ec2_client)


def test_pending_instance_is_never_a_target(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response(
        [('i-old', 'InService', 'Healthy'), ('i-new', 'Pending:Wait', 'Healthy')])
    aws.ec2.describe_route_tables.return_value = route_tables_response('i-old')

    main.reconcile_nat_target()

    aws.ec2.replace_route.assert_not_called()
    aws.ec2.associate_address.assert_not_called()
    aws.ec2.create_route.assert_called_once_with(
        DestinationCidrBlock='0.0.0.0/0', RouteTableId='rtb-b', InstanceId='i-old')


def test_cutover_moves_eip_then_routes_then_releases_old_instance(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response(
        [('i-old', 'Terminating:Wait', 'Healthy'), ('i-new', 'InService', 'Healthy')])
    aws.ec2.describe_route_tables.return_value = route_tables_response('i-old')
    calls = mock.Mock()
    aws.ec2.associate_address.side_effect = lambda **kw: calls('eip', kw['InstanceId'])
    aws.ec2.replace_route.side_effect = lambda **kw: calls('route', kw['InstanceId'])
    aws.ec2.create_route.side_effect = lambda **kw: calls('route', kw['InstanceId'])
    aws.asg.complete_lifecycle_action.side_effect = lambda **kw: calls('release', kw['InstanceId'])

    main.reconcile_nat_target()

    assert calls.call_args_list == [
        mock.call('eip', 'i-new'),
        mock.call('route', 'i-new'),
        mock.call('route', 'i-new'),
        mock.call('release', 'i-old'),
    ]
    aws.asg.complete_lifecycle_action.assert_called_once_with(
        LifecycleHookName='nat-termination-hook', AutoScalingGroupName='nat-asg',
        LifecycleActionResult='CONTINUE', InstanceId='i-old')


def test_newest_inservice_instance_is_preferred(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response(
        [('i-new', 'InService', 'Healthy'), ('i-old', 'InService', 'Healthy')], 'rtb-a')
    aws.ec2.describe_route_tables.return_value = route_tables_response('i-old')

    main.reconcile_nat_target()

    aws.ec2.replace_route.assert_called_once_with(
        DestinationCidrBlock='0.0.0.0/0', RouteTableId='rtb-a', InstanceId='i-new')


@pytest.mark.parametrize('instances', [
    pytest.param([('i-old', 'Terminating:Wait', 'Healthy'), ('i-new', 'Pending:Wait', 'Healthy')],
                 id='replacement-still-pending'),
    pytest.param([('i-new', 'InService', 'Unhealthy')], id='only-unhealthy'),
    pytest.param([], id='empty'),
])
def test_routes_left_unchanged_without_healthy_instance(aws, instances):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response(instances)

    main.reconcile_nat_target()

    aws.ec2.describe_route_tables.assert_not_called()
    aws.ec2.associate_address.assert_not_called()
    aws.asg.complete_lifecycle_action.assert_not_called()


def test_blackhole_route_to_same_instance_is_replaced(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response([('i-new', 'InService', 'Healthy')], 'rtb-a')
    aws.ec2.describe_route_tables.return_value = route_tables_response('i-new', state='blackhole')

    main.reconcile_nat_target()

    aws.ec2.replace_route.assert_called_once()


def test_already_in_sync_makes_no_changes(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response([('i-old', 'InService', 'Healthy')], 'rtb-a')
    aws.ec2.describe_route_tables.return_value = {'RouteTables': route_tables_response('i-old')['RouteTables'][:1]}

    main.reconcile_nat_target()

    aws.ec2.replace_route.assert_not_called()
    aws.ec2.create_route.assert_not_called()
    aws.ec2.associate_address.assert_not_called()


def test_eip_skipped_when_disabled(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response([('i-new', 'InService', 'Healthy')])
    aws.ec2.describe_route_tables.return_value = route_tables_response('i-old')

    with mock.patch.object(main, 'EIP_ALLOCATION_ID', None):
        main.reconcile_nat_target()

    aws.ec2.describe_addresses.assert_not_called()
    aws.ec2.associate_address.assert_not_called()


def test_missing_route_table_tag_raises(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response([('i-old', 'InService', 'Healthy')], '')

    with pytest.raises(main.RouteTableTagMissingError):
        main.reconcile_nat_target()

    # An empty RouteTableIds filter would describe every route table in the account.
    aws.ec2.describe_route_tables.assert_not_called()


def test_missing_asg_raises(aws):
    aws.asg.describe_auto_scaling_groups.return_value = {'AutoScalingGroups': []}

    with pytest.raises(main.AsgNotFoundError):
        main.reconcile_nat_target()


def test_already_completed_lifecycle_action_is_tolerated(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response(
        [('i-old', 'Terminating:Wait', 'Healthy'), ('i-new', 'InService', 'Healthy')])
    aws.ec2.describe_route_tables.return_value = route_tables_response('i-new')
    aws.asg.complete_lifecycle_action.side_effect = client_error('ValidationError')

    main.reconcile_nat_target()


def test_other_lifecycle_action_errors_propagate(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response(
        [('i-old', 'Terminating:Wait', 'Healthy'), ('i-new', 'InService', 'Healthy')])
    aws.ec2.describe_route_tables.return_value = route_tables_response('i-new')
    aws.asg.complete_lifecycle_action.side_effect = client_error('Throttling')

    with pytest.raises(ClientError):
        main.reconcile_nat_target()


def test_scheduled_event_failure_propagates_for_retry(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response([('i-new', 'InService', 'Healthy')])
    aws.ec2.describe_route_tables.return_value = route_tables_response('i-old')
    aws.ec2.replace_route.side_effect = client_error('Throttling')

    with pytest.raises(ClientError):
        main.lambda_handler({'source': 'aws.events', 'detail-type': 'Scheduled Event'}, None)


@pytest.mark.parametrize('transition', [
    'autoscaling:EC2_INSTANCE_LAUNCHING',
    'autoscaling:EC2_INSTANCE_TERMINATING',
])
def test_lifecycle_notification_triggers_reconcile(transition):
    message = {'LifecycleHookName': 'nat-hook', 'LifecycleTransition': transition,
               'EC2InstanceId': 'i-old', 'AutoScalingGroupName': 'nat-asg'}

    with mock.patch.object(main, 'reconcile_nat_target') as reconcile:
        main.lambda_handler({'Records': [{'Sns': {'Message': json.dumps(message)}}]}, None)

    reconcile.assert_called_once_with()


@pytest.mark.parametrize('record', [
    pytest.param({'Sns': {'Message': json.dumps({'Event': 'autoscaling:TEST_NOTIFICATION'})}},
                 id='hook-test-notification'),
    pytest.param({'eventSource': 'aws:s3'}, id='unknown-record'),
])
def test_other_records_do_not_reconcile(record):
    with mock.patch.object(main, 'reconcile_nat_target') as reconcile:
        main.lambda_handler({'Records': [record]}, None)

    reconcile.assert_not_called()


def test_hook_test_notification_is_not_a_warning(caplog):
    message = {'Event': 'autoscaling:TEST_NOTIFICATION'}

    main.lambda_handler({'Records': [{'Sns': {'Message': json.dumps(message)}}]}, None)

    assert not [r for r in caplog.records if r.levelname == 'WARNING']
