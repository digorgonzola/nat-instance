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
            {'InstanceId': i, 'LaunchTime': LAUNCH_TIMES.get(i, T0)} for i in InstanceIds
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

    with mock.patch.object(main, 'NAT_GROUPS', {'nat-asg': ''}):
        main.reconcile_nat_target()

    aws.ec2.describe_addresses.assert_not_called()
    aws.ec2.associate_address.assert_not_called()


def test_missing_route_table_tag_raises(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response([('i-old', 'InService', 'Healthy')], '')

    with pytest.raises(main.ReconcileError) as raised:
        main.reconcile_nat_target()

    assert isinstance(raised.value.failures['nat-asg'], main.RouteTableTagMissingError)

    # An empty RouteTableIds filter would describe every route table in the account.
    aws.ec2.describe_route_tables.assert_not_called()


def test_missing_asg_is_skipped(aws):
    aws.asg.describe_auto_scaling_groups.return_value = {'AutoScalingGroups': []}

    main.reconcile_nat_target()

    aws.ec2.describe_route_tables.assert_not_called()


PER_AZ_GROUPS = {'nat-a-asg': 'eipalloc-a', 'nat-b-asg': 'eipalloc-b'}


@pytest.fixture
def per_az(aws):
    """Two groups, each owning one route table and one EIP.

    Set `instances` per group, and `routes` and `eips` to the instance each currently targets.
    """
    state = mock.Mock(
        instances={'nat-a-asg': [], 'nat-b-asg': []},
        routes={'rtb-a': None, 'rtb-b': None},
        eips={'eipalloc-a': None, 'eipalloc-b': None},
    )
    aws.asg.describe_auto_scaling_groups.side_effect = lambda AutoScalingGroupNames: {'AutoScalingGroups': [
        {
            'AutoScalingGroupName': name,
            'Tags': [{'Key': 'RouteTableIds', 'Value': 'rtb-' + name.split('-')[1]}],
            'Instances': [
                {'InstanceId': instance_id, 'LifecycleState': lifecycle_state, 'HealthStatus': health}
                for instance_id, lifecycle_state, health in state.instances[name]
            ],
        }
        for name in AutoScalingGroupNames
    ]}
    aws.ec2.describe_route_tables.side_effect = lambda RouteTableIds: {'RouteTables': [
        {'RouteTableId': rtb, 'Routes': [
            {'DestinationCidrBlock': '0.0.0.0/0', 'InstanceId': state.routes[rtb], 'State': 'active'},
        ]}
        for rtb in RouteTableIds
    ]}
    aws.ec2.describe_addresses.side_effect = lambda AllocationIds: {'Addresses': [
        {'InstanceId': state.eips[allocation_id]} for allocation_id in AllocationIds
    ]}
    with mock.patch.object(main, 'NAT_GROUPS', PER_AZ_GROUPS):
        yield state


def route_targets(aws):
    return {c.kwargs['RouteTableId']: c.kwargs['InstanceId'] for c in aws.ec2.replace_route.call_args_list}


def test_per_az_groups_each_use_their_own_instance(aws, per_az):
    per_az.instances = {'nat-a-asg': [('i-a', 'InService', 'Healthy')], 'nat-b-asg': [('i-b', 'InService', 'Healthy')]}
    per_az.routes = {'rtb-a': 'i-old', 'rtb-b': 'i-old'}

    main.reconcile_nat_target()

    assert route_targets(aws) == {'rtb-a': 'i-a', 'rtb-b': 'i-b'}
    assert {c.kwargs['AllocationId']: c.kwargs['InstanceId'] for c in aws.ec2.associate_address.call_args_list} == {
        'eipalloc-a': 'i-a', 'eipalloc-b': 'i-b'}


def test_group_without_healthy_instance_fails_over_and_releases(aws, per_az):
    per_az.instances = {
        'nat-a-asg': [('i-a', 'InService', 'Healthy')],
        'nat-b-asg': [('i-b', 'Terminating:Wait', 'Healthy')],
    }
    per_az.routes = {'rtb-a': 'i-a', 'rtb-b': 'i-b'}
    per_az.eips = {'eipalloc-a': 'i-a', 'eipalloc-b': 'i-b'}

    main.reconcile_nat_target()

    assert route_targets(aws) == {'rtb-b': 'i-a'}
    # The failed-over AZ's EIP stays put: its traffic now leaves through the other AZ's EIP.
    aws.ec2.associate_address.assert_not_called()
    aws.asg.complete_lifecycle_action.assert_called_once_with(
        LifecycleHookName='nat-termination-hook', AutoScalingGroupName='nat-b-asg',
        LifecycleActionResult='CONTINUE', InstanceId='i-b')


def test_unhealthy_instance_fails_over_before_its_replacement_is_ready(aws, per_az):
    per_az.instances = {
        'nat-a-asg': [('i-a', 'InService', 'Healthy')],
        'nat-b-asg': [('i-b', 'InService', 'Unhealthy'), ('i-new', 'Pending:Wait', 'Healthy')],
    }
    per_az.routes = {'rtb-a': 'i-a', 'rtb-b': 'i-b'}
    per_az.eips = {'eipalloc-a': 'i-a', 'eipalloc-b': 'i-b'}

    main.reconcile_nat_target()

    assert route_targets(aws) == {'rtb-b': 'i-a'}


def test_failed_over_routes_move_back_when_group_recovers(aws, per_az):
    per_az.instances = {'nat-a-asg': [('i-a', 'InService', 'Healthy')], 'nat-b-asg': [('i-new', 'InService', 'Healthy')]}
    per_az.routes = {'rtb-a': 'i-a', 'rtb-b': 'i-a'}
    per_az.eips = {'eipalloc-a': 'i-a', 'eipalloc-b': None}

    main.reconcile_nat_target()

    assert route_targets(aws) == {'rtb-b': 'i-new'}
    aws.ec2.associate_address.assert_called_once_with(
        AllocationId='eipalloc-b', InstanceId='i-new', AllowReassociation=True)


def test_every_eip_moves_before_any_route(aws, per_az):
    per_az.instances = {'nat-a-asg': [('i-a', 'InService', 'Healthy')], 'nat-b-asg': [('i-b', 'InService', 'Healthy')]}
    per_az.routes = {'rtb-a': 'i-old', 'rtb-b': 'i-old'}
    calls = mock.Mock()
    aws.ec2.associate_address.side_effect = lambda **kw: calls('eip', kw['InstanceId'])
    aws.ec2.replace_route.side_effect = lambda **kw: calls('route', kw['InstanceId'])

    main.reconcile_nat_target()

    assert [c.args[0] for c in calls.call_args_list] == ['eip', 'eip', 'route', 'route']


def test_no_healthy_instance_in_any_group_leaves_routes(aws, per_az):
    per_az.instances = {
        'nat-a-asg': [('i-a', 'Terminating:Wait', 'Healthy')],
        'nat-b-asg': [('i-b', 'InService', 'Unhealthy')],
    }

    main.reconcile_nat_target()

    aws.ec2.describe_route_tables.assert_not_called()
    aws.asg.complete_lifecycle_action.assert_not_called()


def test_group_not_created_yet_does_not_block_the_others(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response(
        [('i-old', 'Terminating:Wait', 'Healthy'), ('i-new', 'InService', 'Healthy')], 'rtb-a')
    aws.ec2.describe_route_tables.return_value = route_tables_response('i-old')

    with mock.patch.object(main, 'NAT_GROUPS', {'nat-asg': '', 'nat-b-asg': ''}):
        main.reconcile_nat_target()

    aws.ec2.replace_route.assert_called_once_with(
        DestinationCidrBlock='0.0.0.0/0', RouteTableId='rtb-a', InstanceId='i-new')
    aws.asg.complete_lifecycle_action.assert_called_once()


def test_failed_group_does_not_block_the_others_and_is_raised(aws, per_az):
    per_az.instances = {
        'nat-a-asg': [('i-a-old', 'Terminating:Wait', 'Healthy'), ('i-a', 'InService', 'Healthy')],
        'nat-b-asg': [('i-b-old', 'Terminating:Wait', 'Healthy'), ('i-b', 'InService', 'Healthy')],
    }
    per_az.routes = {'rtb-a': 'i-a-old', 'rtb-b': 'i-b-old'}

    def replace_route(**kw):
        if kw['RouteTableId'] == 'rtb-a':
            raise client_error('Throttling')
    aws.ec2.replace_route.side_effect = replace_route

    with pytest.raises(main.ReconcileError) as raised:
        main.reconcile_nat_target()

    assert list(raised.value.failures) == ['nat-a-asg']
    # Group a's old instance still carries its routes, so only group b's is released.
    aws.asg.complete_lifecycle_action.assert_called_once_with(
        LifecycleHookName='nat-termination-hook', AutoScalingGroupName='nat-b-asg',
        LifecycleActionResult='CONTINUE', InstanceId='i-b-old')


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

    with pytest.raises(main.ReconcileError):
        main.reconcile_nat_target()


def test_scheduled_event_failure_propagates_for_retry(aws):
    aws.asg.describe_auto_scaling_groups.return_value = asg_response([('i-new', 'InService', 'Healthy')])
    aws.ec2.describe_route_tables.return_value = route_tables_response('i-old')
    aws.ec2.replace_route.side_effect = client_error('Throttling')

    with pytest.raises(main.ReconcileError):
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
