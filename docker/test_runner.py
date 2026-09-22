#!/usr/bin/env python3
"""Customer CLI regressions; no daemon, downloads or simulator build required."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
FAKE_DOCKER = r'''
import json
import os
import sys

args = sys.argv[1:]
with open(os.environ['SS_TEST_CALLS'], 'a') as stream:
    stream.write(json.dumps(args) + '\n')
if args[:2] == ['compose', 'version']:
    print('Docker Compose version v2.test')
    sys.exit(int(os.environ.get('SS_TEST_COMPOSE_EXIT', '0')))
if args[:1] == ['info']:
    print(os.environ.get('SS_TEST_ENGINE', 'linux/x86_64'))
    sys.exit(int(os.environ.get('SS_TEST_DAEMON_EXIT', '0')))
if args[:2] == ['image', 'inspect']:
    sys.exit(int(os.environ.get('SS_TEST_IMAGE_EXIT', '0')))
if args[:1] == ['compose'] and 'build' in args:
    sys.exit(int(os.environ.get('SS_TEST_BUILD_EXIT', '0')))
if args[:2] == ['compose', 'run']:
    sys.exit(int(os.environ.get('SS_TEST_RUN_EXIT', '0')))
print('Unexpected Docker invocation: ' + repr(args), file=sys.stderr)
sys.exit(99)
'''


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ss-runner-test-')
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.bin = self.directory / 'bin'
        self.bin.mkdir()
        for name in ('bash', 'dirname', 'cat'):
            (self.bin / name).symlink_to(shutil.which(name))
        self.docker = self.bin / 'docker'
        self.docker.write_text('#!' + sys.executable + '\n' + FAKE_DOCKER)
        self.docker.chmod(0o755)
        self.calls_file = self.directory / 'calls.jsonl'

    def run_cli(self, *args, **overrides):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(('SS_', 'COMPOSE_'))}
        env.update(PATH=str(self.bin), SS_TEST_CALLS=str(self.calls_file))
        env.update(overrides)
        self.result = subprocess.run([str(ROOT / 'run.sh')] + list(args),
                                     cwd=str(self.directory), env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                     text=True, timeout=10)
        self.calls = ([json.loads(line) for line in self.calls_file.read_text().splitlines()]
                      if self.calls_file.exists() else [])
        return self.result

    def builds(self):
        return [call for call in self.calls if 'build' in call]

    def runs(self):
        return [call for call in self.calls if call[:2] == ['compose', 'run']]

    def test_help_works_without_docker(self):
        self.docker.unlink()
        self.assertEqual(self.run_cli('--help').returncode, 0)
        self.assertIn('./run.sh setup', self.result.stdout)
        self.assertEqual(self.calls, [])

    def test_missing_docker_is_actionable(self):
        self.docker.unlink()
        self.assertEqual(self.run_cli('setup').returncode, 2)
        self.assertIn('未安装 Docker', self.result.stdout)

    def test_missing_compose_stops_before_build(self):
        self.assertEqual(self.run_cli('setup', SS_TEST_COMPOSE_EXIT='1').returncode, 2)
        self.assertIn('Compose', self.result.stdout)
        self.assertEqual(self.builds(), [])

    def test_unavailable_daemon_stops_before_build(self):
        self.assertEqual(self.run_cli('setup', SS_TEST_DAEMON_EXIT='1').returncode, 2)
        self.assertIn('Docker 服务不可用', self.result.stdout)
        self.assertEqual(self.builds(), [])

    def test_unsupported_architecture_is_rejected(self):
        self.assertEqual(self.run_cli('setup', SS_TEST_ENGINE='linux/aarch64').returncode, 2)
        self.assertIn('x86-64', self.result.stdout)
        self.assertEqual(self.builds(), [])

    def test_setup_failure_does_not_run_or_claim_success(self):
        self.assertEqual(self.run_cli('setup', SS_TEST_BUILD_EXIT='31').returncode, 31)
        self.assertEqual(self.runs(), [])
        self.assertNotIn('初始化成功', self.result.stdout)

    def test_acceptance_failure_does_not_claim_success(self):
        self.assertEqual(self.run_cli('setup', SS_TEST_RUN_EXIT='32').returncode, 32)
        self.assertEqual(len(self.builds()), 1)
        self.assertNotIn('初始化成功', self.result.stdout)

    def test_setup_builds_then_runs_acceptance(self):
        self.assertEqual(self.run_cli('setup').returncode, 0)
        self.assertLess(self.calls.index(self.builds()[0]), self.calls.index(self.runs()[0]))
        self.assertEqual(self.runs()[0][-2:], ['storagestacked', 'setup'])
        self.assertIn('初始化成功', self.result.stdout)

    def test_loaded_image_does_not_build_or_pull(self):
        self.assertEqual(self.run_cli('memsim', SS_IMAGE='delivery:test').returncode, 0)
        self.assertIn(['image', 'inspect', 'delivery:test'], self.calls)
        self.assertEqual(self.builds(), [])
        self.assertEqual(self.runs()[0][self.runs()[0].index('--pull') + 1], 'never')

    def test_missing_image_builds_before_running(self):
        self.assertEqual(self.run_cli('xpu', SS_TEST_IMAGE_EXIT='1').returncode, 0)
        self.assertEqual(len(self.builds()), 1)
        self.assertLess(self.calls.index(self.builds()[0]), self.calls.index(self.runs()[0]))

    def test_trace_options_preserve_argument_boundaries(self):
        self.assertEqual(self.run_cli('llm', '/results/a b', '--hidden-size', '16').returncode, 0)
        self.assertEqual(self.runs()[0][-4:], ['llm', '/results/a b', '--hidden-size', '16'])

    def test_view_binds_only_loopback(self):
        self.assertEqual(self.run_cli('view', SS_VIEW_PORT='18080').returncode, 0)
        self.assertIn('127.0.0.1:18080:8000', self.runs()[0])

    def test_invalid_view_port_does_not_start_container(self):
        for port in ('0', '65536', 'bad', '1:8000'):
            with self.subTest(port=port):
                self.assertEqual(self.run_cli('view', SS_VIEW_PORT=port).returncode, 2)
                self.assertEqual(self.runs(), [])

    def test_bad_command_and_extra_setup_arguments_fail_early(self):
        for args in (('bogus',), ('setup', '--typo'), ('memsim', '--typo'),
                     ('check', '/results/one', '/results/two'), ('shell', '--typo')):
            with self.subTest(args=args):
                self.assertEqual(self.run_cli(*args).returncode, 2)
                self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main(verbosity=2)
