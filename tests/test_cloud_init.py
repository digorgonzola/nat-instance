import gzip
import os
import pathlib
import re
import subprocess

import pytest
import yaml

TEMPLATE = pathlib.Path(__file__).parent.parent / 'templates' / 'cloud-init.tpl'
# The values main.tf passes to templatefile().
TEMPLATE_VALUES = {
    'architecture': 'arm64',
    'aws_region': 'ap-southeast-2',
    'lifecycle_hook_name': 'nat-hook',
    's3_bucket': 'nat-config',
    'vpc_cidr_block': '10.0.0.0/16',
}
# EC2 rejects user data larger than 16 KB before base64 encoding. main.tf gzips it first.
USER_DATA_LIMIT_BYTES = 16 * 1024
INTERPOLATION = re.compile(r'(?<!\$)\$\{([^}]+)\}')
INSTANCE_LOG = '/var/log/nat-instance.log'


def render_template():
    """Render like templatefile(): ${name} is replaced by a value and $${ becomes a literal ${."""
    template = TEMPLATE.read_text()
    return INTERPOLATION.sub(lambda match: TEMPLATE_VALUES[match.group(1)], template).replace('$${', '${')


def rendered_files():
    return {entry['path']: entry['content'] for entry in yaml.safe_load(render_template())['write_files']}


SCRIPTS = [path for path in rendered_files() if path.startswith('/usr/local/bin/') or path == '/root/startup.sh']


def test_user_data_fits_ec2_limit():
    assert len(gzip.compress(render_template().encode())) < USER_DATA_LIMIT_BYTES


@pytest.mark.parametrize('path', SCRIPTS)
def test_script_is_valid_bash(path, tmp_path):
    script = tmp_path / 'script'
    script.write_text(rendered_files()[path])

    subprocess.run(['bash', '-n', str(script)], check=True)


@pytest.mark.parametrize('unit, timer_interval_seconds', [
    ('nat-health-check', 30),
    ('squid-config-sync', 60),
])
def test_units_log_where_cloudwatch_collects_and_finish_before_the_next_run(unit, timer_interval_seconds):
    files = rendered_files()
    service = files[f'/etc/systemd/system/{unit}.service']
    timer = files[f'/etc/systemd/system/{unit}.timer']

    assert f'StandardOutput=append:{INSTANCE_LOG}' in service
    assert f'StandardError=append:{INSTANCE_LOG}' in service
    assert f'OnUnitActiveSec={timer_interval_seconds}s' in timer
    timeout = int(re.search(r'TimeoutStartSec=(\d+)s', service).group(1))
    assert timeout < timer_interval_seconds
    assert f'"file_path": "{INSTANCE_LOG}"' in files['/root/startup.sh']


class Instance:
    """Runs the instance scripts against stub commands, with their paths moved under root.

    Files in root stand for instance state: `squid-running`, `healthy` (the nat-healthy stub),
    and the faults `forwarding-off`, `masquerade-missing`, `closed-<port>`, `s3-down` and
    `terminate-on-sleep`.
    """

    def __init__(self, root):
        self.root = root
        self.bin = root / 'bin'
        self.etc_squid = root / 'etc' / 'squid'
        self.bucket = root / 'bucket'
        self.failures_file = root / 'run' / 'failures'
        self.rejected_file = root / 'lib.rejected'
        self.calls_log = root / 'calls.log'
        for directory in (self.bin, self.etc_squid, self.bucket, self.failures_file.parent, root / 'lib'):
            directory.mkdir(parents=True)
        self.calls_log.touch()

        running = root / 'squid-running'
        conf = self.etc_squid / 'squid.conf'
        stubs = {
            'nat-healthy': f'[ -f {root}/healthy ]',
            'systemctl': f'case "$1" in is-active) [ -f {running} ];; restart) touch {running};; esac',
            'squid': (
                f'case "$2" in parse) ! grep -q INVALID {conf};; '
                f'reconfigure) if grep -q CRASH {conf}; then rm -f {running}; fi;; '
                f'check) [ -f {running} ];; esac'
            ),
            # macOS has no timeout command, so run the wrapped command directly.
            'timeout': 'shift; exec "$@"',
            # Stands in for systemd stopping the unit at TimeoutStartSec.
            'sleep': f'if [ -f {root}/terminate-on-sleep ]; then kill -TERM $PPID; fi',
            'sysctl': f'if [ -f {root}/forwarding-off ]; then echo 0; else echo 1; fi',
            'ip': 'echo "default via 10.0.0.1 dev ens5"',
            'iptables': f'[ ! -f {root}/masquerade-missing ]',
            'ss': f'port=${{2##*:}}; [ -f {root}/closed-$port ] || echo "LISTEN 0 4096 *:$port *:*"',
            'curl': 'if [[ "$*" == *instance-id* ]]; then echo i-test; else echo token; fi',
            # --checksum: tests rewrite files with the same size within the same second.
            'aws': f'[ ! -f {root}/s3-down ] || exit 1; if [ "$1" = s3 ]; then rsync -a --checksum --delete {self.bucket}/ "$4"/; fi',
        }
        for name, body in stubs.items():
            self._write_executable(self.bin / name, f'#!/bin/bash\necho "{name} $*" >> {self.calls_log}\n{body}\n')

        moved_paths = {
            '/usr/local/bin/nat-healthy': self.bin / 'nat-healthy',
            '/usr/sbin/squid': self.bin / 'squid',
            '/run/nat-health-failures': self.failures_file,
            '/var/lib/squid-config': root / 'lib',
            '/etc/squid': self.etc_squid,
        }
        files = rendered_files()
        for name in ('nat-healthy', 'nat-health-monitor', 'squid-config-sync'):
            content = files[f'/usr/local/bin/{name}']
            for original, moved in moved_paths.items():
                content = content.replace(original, str(moved))
            self._write_executable(root / name, content)

        self.set('squid-running', True)
        self.set('healthy', True)

    @staticmethod
    def _write_executable(path, content):
        path.write_text(content)
        path.chmod(0o755)

    def set(self, state, is_set):
        flag = self.root / state
        if is_set:
            flag.touch()
        else:
            flag.unlink(missing_ok=True)

    def is_set(self, state):
        return (self.root / state).exists()

    def run(self, name):
        env = {**os.environ, 'PATH': f'{self.bin}{os.pathsep}{os.environ["PATH"]}'}
        return subprocess.run([str(self.root / name)], env=env, capture_output=True, text=True)

    def calls(self, prefix):
        return [line for line in self.calls_log.read_text().splitlines() if line.startswith(prefix)]

    def clear_calls(self):
        self.calls_log.write_text('')

    def write_bucket(self, **files):
        for name, content in files.items():
            (self.bucket / name.replace('_', '.')).write_text(content)

    def squid_files(self):
        return {path.name: path.read_text() for path in self.etc_squid.iterdir()}


@pytest.fixture
def instance(tmp_path):
    return Instance(tmp_path)


def test_nat_healthy_passes_when_everything_works(instance):
    assert instance.run('nat-healthy').returncode == 0


@pytest.mark.parametrize('fault', [
    pytest.param(('squid-running', False), id='squid-stopped'),
    pytest.param(('forwarding-off', True), id='ip-forwarding-off'),
    pytest.param(('masquerade-missing', True), id='masquerade-rule-missing'),
    pytest.param(('closed-3128', True), id='proxy-port-closed'),
])
def test_nat_healthy_fails_when_a_part_is_broken(instance, fault):
    instance.set(*fault)

    assert instance.run('nat-healthy').returncode != 0


def test_health_monitor_does_nothing_while_healthy(instance):
    result = instance.run('nat-health-monitor')

    assert result.stdout == '' and result.stderr == ''
    assert instance.failures_file.read_text().strip() == '0'
    assert instance.calls('aws') == []
    assert instance.calls('systemctl') == []


def test_health_monitor_restarts_stopped_squid_then_marks_instance_unhealthy(instance):
    instance.set('healthy', False)
    instance.set('squid-running', False)

    for _ in range(2):
        instance.run('nat-health-monitor')
    assert instance.calls('systemctl') == []

    instance.run('nat-health-monitor')
    assert instance.calls('systemctl') == ['systemctl restart squid']

    instance.run('nat-health-monitor')
    assert instance.calls('aws') == []

    instance.run('nat-health-monitor')
    assert instance.calls('aws') == [
        'aws autoscaling set-instance-health --instance-id i-test --health-status Unhealthy '
        '--no-should-respect-grace-period --region ap-southeast-2'
    ]
    assert instance.calls('systemctl') == ['systemctl restart squid']


def test_health_monitor_does_not_restart_squid_when_squid_is_not_the_problem(instance):
    instance.set('healthy', False)

    for _ in range(5):
        instance.run('nat-health-monitor')

    assert instance.calls('systemctl') == []
    assert len(instance.calls('aws autoscaling set-instance-health')) == 1


def test_health_monitor_resets_after_a_passing_check(instance):
    instance.set('healthy', False)
    instance.set('squid-running', False)
    for _ in range(2):
        instance.run('nat-health-monitor')

    instance.set('healthy', True)
    instance.run('nat-health-monitor')
    instance.set('healthy', False)
    for _ in range(2):
        instance.run('nat-health-monitor')

    assert instance.calls('systemctl') == []


def apply_good_config(instance):
    instance.write_bucket(squid_conf='http_port 3128\n', whitelist_txt='.example.com\n')
    result = instance.run('squid-config-sync')
    assert result.returncode == 0, result.stderr
    instance.clear_calls()


def test_config_sync_installs_changed_files_and_reconfigures(instance):
    (instance.etc_squid / 'squid.conf').write_text('http_port 3128 default\n')
    instance.write_bucket(squid_conf='http_port 3128\n', whitelist_txt='.example.com\n')

    result = instance.run('squid-config-sync')

    assert result.returncode == 0, result.stderr
    assert instance.squid_files() == {'squid.conf': 'http_port 3128\n', 'whitelist.txt': '.example.com\n'}
    assert instance.calls('squid') == ['squid -k check', 'squid -k parse', 'squid -k reconfigure', 'squid -k check']


def test_config_sync_leaves_squid_alone_when_nothing_changed(instance):
    apply_good_config(instance)

    result = instance.run('squid-config-sync')

    assert result.returncode == 0, result.stderr
    assert instance.calls('squid') == []


def test_config_sync_rolls_back_a_config_that_fails_to_parse(instance):
    apply_good_config(instance)
    instance.write_bucket(squid_conf='http_port 3128\nINVALID\n', whitelist_txt='.example.com\n.github.com\n')

    result = instance.run('squid-config-sync')

    assert result.returncode != 0
    assert instance.squid_files() == {'squid.conf': 'http_port 3128\n', 'whitelist.txt': '.example.com\n'}
    assert 'squid -k reconfigure' not in instance.calls('squid')
    assert instance.calls('systemctl restart') == []


def test_config_sync_rolls_back_and_restarts_when_squid_dies_on_reload(instance):
    apply_good_config(instance)
    instance.write_bucket(squid_conf='http_port 3128\nCRASH\n')

    result = instance.run('squid-config-sync')

    assert result.returncode != 0
    assert instance.squid_files()['squid.conf'] == 'http_port 3128\n'
    assert instance.calls('systemctl restart') == ['systemctl restart squid']
    assert instance.is_set('squid-running')


def test_config_sync_removes_new_files_when_rolling_back(instance):
    apply_good_config(instance)
    instance.write_bucket(squid_conf='http_port 3128\nINVALID\n', extra_acl='10.0.0.0/8\n')

    instance.run('squid-config-sync')

    assert 'extra.acl' not in instance.squid_files()


def test_config_sync_does_not_retry_a_rejected_config_until_the_bucket_changes(instance):
    apply_good_config(instance)
    instance.write_bucket(squid_conf='http_port 3128\nCRASH\n')
    instance.run('squid-config-sync')
    instance.clear_calls()

    result = instance.run('squid-config-sync')
    assert result.returncode != 0
    assert instance.calls('squid') == []
    assert instance.calls('systemctl') == []

    instance.write_bucket(squid_conf='http_port 3129\n')
    result = instance.run('squid-config-sync')
    assert result.returncode == 0, result.stderr
    assert instance.squid_files()['squid.conf'] == 'http_port 3129\n'


def test_config_sync_waits_for_squid_instead_of_rejecting_a_valid_config(instance):
    apply_good_config(instance)
    instance.set('squid-running', False)
    instance.write_bucket(squid_conf='http_port 3129\n')

    result = instance.run('squid-config-sync')
    assert result.returncode != 0
    assert instance.squid_files()['squid.conf'] == 'http_port 3128\n'
    assert not instance.rejected_file.exists()

    instance.set('squid-running', True)
    result = instance.run('squid-config-sync')
    assert result.returncode == 0, result.stderr
    assert instance.squid_files()['squid.conf'] == 'http_port 3129\n'


def test_config_sync_rolls_back_without_rejecting_when_stopped_by_systemd(instance):
    apply_good_config(instance)
    instance.write_bucket(squid_conf='http_port 3129\n')
    instance.set('terminate-on-sleep', True)

    result = instance.run('squid-config-sync')
    assert result.returncode != 0
    assert instance.squid_files()['squid.conf'] == 'http_port 3128\n'
    assert not instance.rejected_file.exists()

    instance.set('terminate-on-sleep', False)
    result = instance.run('squid-config-sync')
    assert result.returncode == 0, result.stderr
    assert instance.squid_files()['squid.conf'] == 'http_port 3129\n'


def test_config_sync_ignores_folder_keys(instance):
    (instance.bucket / 'folder').mkdir()
    instance.write_bucket(squid_conf='http_port 3128\n')

    result = instance.run('squid-config-sync')

    assert result.returncode == 0, result.stderr
    assert instance.squid_files() == {'squid.conf': 'http_port 3128\n'}


def test_config_sync_fails_without_changes_when_the_bucket_is_empty(instance):
    (instance.etc_squid / 'squid.conf').write_text('http_port 3128\n')

    result = instance.run('squid-config-sync')

    assert result.returncode != 0
    assert instance.squid_files() == {'squid.conf': 'http_port 3128\n'}
    assert instance.calls('squid') == []


def test_config_sync_fails_without_changes_when_s3_is_unreachable(instance):
    apply_good_config(instance)
    instance.write_bucket(squid_conf='http_port 3129\n')
    instance.set('s3-down', True)

    result = instance.run('squid-config-sync')

    assert result.returncode != 0
    assert instance.squid_files()['squid.conf'] == 'http_port 3128\n'
    assert instance.calls('squid') == []
