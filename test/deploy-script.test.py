#!/usr/bin/env python3
"""Exercise deployment scripts with isolated Git repos and simulated SSH/npm/HTTP."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

APP = 'sfn'
SCRIPT = Path(__file__).resolve().parents[1] / f'deploy/deploy-{APP}.sh'

STUB = r"""
import io, json, os, pathlib, subprocess, sys, tarfile
root = pathlib.Path(os.environ['DEPLOY_TEST_ROOT'])
app = os.environ['DEPLOY_TEST_APP']
fail = os.environ.get('DEPLOY_TEST_FAIL', '')
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
def event(kind, **fields):
	with (root / 'events.jsonl').open('a') as output:
		output.write(json.dumps(dict(kind=kind, **fields)) + '\n')
def finish(code=0): sys.exit(code)
if name == 'sleep': finish()
if name == 'npm':
	action = args[-1]
	event('npm', action=action)
	if action == 'test': finish(1 if fail == 'tests' else 0)
	if action == 'build':
		event('build', code=pathlib.Path('source.txt').read_text(), base=os.environ.get('APP_BASE'))
		if fail == 'build': finish(1)
		pathlib.Path('dist').mkdir()
		pathlib.Path('dist/index.html').write_text('fixture assets')
		pathlib.Path('dist/sw.js').write_text('fixture worker')
		finish()
	finish(97)
if name == 'curl':
	url = args[-1]
	event('https', url=url)
	if '-w' in args:
		print('500' if fail == 'https' else '200', end=''); finish()
	if url.endswith('/api/v1/health'):
		print(json.dumps({'feeds': [{'id': 'fixture', 'timestamp': 1, 'age': 1}], 'stationCount': 1, 'status': 'healthy'}))
	elif app == 'sfn':
		print('<html></html>' if fail == 'assets' else '<script src="/subwaysForNerds/assets/app.js"></script>')
	else:
		print('<script src="app.js?v=123"></script>')
	finish()
if name != 'ssh': finish(98)
command = args[-1]
event('ssh', command=command)
if 'cat ' in command and 'cat >' not in command and 'DEPLOYED_SHA' in command:
	print(os.environ['DEPLOY_TEST_OLD_SHA']); finish()
if 'cat ' in command and 'config/display.json' in command:
	print('{}'); finish()
if 'grep -oP' in command:
	print('/subwaysForNerds/'); finish()
if 'tar --exclude=' in command and '-czf -' in command:
	event('backup')
	if fail == 'backup': finish(1)
	with tarfile.open(fileobj=sys.stdout.buffer, mode='w|gz') as archive:
		body = b'private fixture configuration'
		entry = tarfile.TarInfo('fixture/config'); entry.size = len(body)
		archive.addfile(entry, io.BytesIO(body))
	finish()
if 'tar -x ' in command or 'tar -xf -' in command:
	data = sys.stdin.buffer.read()
	with tarfile.open(fileobj=io.BytesIO(data)) as archive:
		event('sync', code=archive.extractfile('source.txt').read().decode(), members=archive.getnames(), command=command)
	finish()
if 'dist.incoming' in command:
	data = sys.stdin.buffer.read()
	with tarfile.open(fileobj=io.BytesIO(data)) as archive:
		event('dist', members=archive.getnames())
	finish()
if 'npm ci' in command:
	event('dependencies'); finish(1 if fail == 'dependencies' else 0)
if 'systemctl restart' in command:
	event('restart'); finish()
if 'systemctl is-active' in command:
	print('failed' if fail == 'start' else 'active'); finish()
if 'journalctl' in command:
	print('fixture service log'); finish()
if command.startswith('test -d ') or command.startswith('test -f '): finish()
if 'cat >' in command:
	sha = sys.stdin.read().strip()
	event('marker', sha=sha)
	(root / 'DEPLOYED_SHA').write_text(sha)
	finish()
print('Unhandled fixture command: ' + command, file=sys.stderr)
finish(99)
"""


class DeploymentTests(unittest.TestCase):
	def setUp(self):
		self.temp = tempfile.TemporaryDirectory(prefix=f'{APP}-deploy-test-')
		self.addCleanup(self.temp.cleanup)
		self.root = Path(self.temp.name)
		self.repo = self.root / 'repo'
		self.repo.mkdir()
		self.backups = self.root / 'backups with spaces'
		for name, body in {
			'source.txt': 'previous source',
			'package.json': '{"version":"1"}',
			'package-lock.json': '{}',
			'config/display.json': '{}',
			'public/data/display-data.json': '{}',
			'vite.config.ts': "export default { base: process.env.APP_BASE || '/subwaysForNerds/' }",
			'test/unit.test.ts': 'fixture test',
			'.gitignore': '.env\nnode_modules/\n',
		}.items():
			file = self.repo / name
			file.parent.mkdir(parents=True, exist_ok=True)
			file.write_text(body)
		(self.repo / 'node_modules').mkdir()
		self.git('init', '-q', '-b', 'mobile' if APP == 'did' else 'main')
		self.git('add', '.')
		self.git('-c', 'user.name=Deploy Test', '-c', 'user.email=deploy@example.invalid', 'commit', '-qm', 'previous')
		self.previous = self.git('rev-parse', 'HEAD').stdout.strip()
		(self.repo / 'source.txt').write_text('committed release')
		(self.repo / 'package.json').write_text('{"version":"2"}')
		self.git('add', '.')
		self.git('-c', 'user.name=Deploy Test', '-c', 'user.email=deploy@example.invalid', 'commit', '-qm', 'release')
		self.sha = self.git('rev-parse', 'HEAD').stdout.strip()
		(self.repo / 'source.txt').write_text('unfinished local work')
		(self.repo / '.env').write_text('LOCAL_SECRET=must-not-ship')
		self.bin = self.root / 'bin'
		self.bin.mkdir()
		stub = self.bin / 'stub'
		stub.write_text(f'#!{sys.executable}\n' + STUB)
		stub.chmod(0o700)
		for name in ('ssh', 'npm', 'curl', 'sleep'):
			(self.bin / name).symlink_to(stub)

	def git(self, *args):
		return subprocess.run(['git', '-C', str(self.repo), *args], check=True, text=True, capture_output=True)

	def run_script(self, *args, fail=''):
		env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'],
				   BACKUP_DIR=str(self.backups), DEPLOY_TEST_ROOT=str(self.root),
				   DEPLOY_TEST_APP=APP, DEPLOY_TEST_FAIL=fail, DEPLOY_TEST_OLD_SHA=self.previous)
		env[APP.upper() + '_REPO'] = str(self.repo)
		env.pop(APP.upper() + '_BRANCH', None)
		return subprocess.run(['/bin/bash', str(SCRIPT), '--branch', self.sha, *args],
							  env=env, stdin=subprocess.DEVNULL, text=True, capture_output=True, timeout=20)

	def events(self):
		file = self.root / 'events.jsonl'
		return [json.loads(line) for line in file.read_text().splitlines()] if file.exists() else []

	def test_dry_run_does_not_test_build_back_up_or_write(self):
		result = self.run_script('--dry-run')
		self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
		self.assertTrue(all(event['kind'] == 'ssh' for event in self.events()))
		self.assertFalse(self.backups.exists())

	def test_success_ships_selected_commit_and_records_it_after_verification(self):
		result = self.run_script()
		self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
		self.assertEqual((self.root / 'DEPLOYED_SHA').read_text(), self.sha)
		events = self.events()
		sync = next(event for event in events if event['kind'] == 'sync')
		self.assertEqual(sync['code'], 'committed release')
		self.assertNotIn('.env', sync['members'])
		if APP == 'did':
			self.assertIn('--exclude=config/display.json', sync['command'])
			self.assertIn('--exclude=public/data/display-data.json', sync['command'])
		else:
			build = next(event for event in events if event['kind'] == 'build')
			self.assertEqual(build['code'], 'committed release')
			self.assertEqual(build['base'], '/subwaysForNerds/')
			self.assertTrue(any(event.get('url', '').endswith('/assets/app.js') for event in events))
		kinds = [event['kind'] for event in events]
		self.assertLess(kinds.index('backup'), kinds.index('sync'))
		self.assertLess(max(i for i, kind in enumerate(kinds) if kind == 'https'), kinds.index('marker'))
		archives = list(self.backups.glob('*.tgz'))
		self.assertEqual(len(archives), 1)
		self.assertEqual(archives[0].stat().st_mode & 0o777, 0o600)
		self.assertFalse(list(self.backups.glob('*.partial.*')))
		with tarfile.open(archives[0]) as archive:
			self.assertEqual(archive.extractfile('fixture/config').read(), b'private fixture configuration')

	def test_git_worktree_is_accepted(self):
		linked = self.root / 'linked'
		self.git('worktree', 'add', '-q', '--detach', str(linked), self.sha)
		self.repo = linked
		result = self.run_script('--dry-run')
		self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

	def test_test_failure_prevents_backup_and_deployment(self):
		result = self.run_script(fail='tests')
		self.assertNotEqual(result.returncode, 0)
		self.assertFalse(any(event['kind'] in ('backup', 'sync', 'marker') for event in self.events()))

	def test_backup_failure_prevents_sync_and_leaves_no_partial_archive(self):
		result = self.run_script(fail='backup')
		self.assertNotEqual(result.returncode, 0)
		self.assertFalse(any(event['kind'] in ('sync', 'marker') for event in self.events()))
		self.assertEqual(list(self.backups.iterdir()), [])

	def test_runtime_dependency_failure_never_records_success(self):
		result = self.run_script(fail='dependencies')
		self.assertNotEqual(result.returncode, 0)
		self.assertIn('dependencies', [event['kind'] for event in self.events()])
		self.assertFalse((self.root / 'DEPLOYED_SHA').exists())
		self.assertFalse(any(event['kind'] == 'restart' for event in self.events()))

	def test_service_or_https_failure_never_records_success(self):
		for fail in ('start', 'https'):
			with self.subTest(fail=fail):
				result = self.run_script(fail=fail)
				self.assertNotEqual(result.returncode, 0)
				self.assertFalse((self.root / 'DEPLOYED_SHA').exists())
				self.assertTrue(list(self.backups.glob('*.tgz')))

	def test_build_failure_prevents_backup_and_sync(self):
		result = self.run_script(fail='build')
		self.assertNotEqual(result.returncode, 0)
		self.assertFalse(any(event['kind'] in ('backup', 'sync', 'marker') for event in self.events()))

	def test_missing_assets_prevent_success_marker(self):
		result = self.run_script(fail='assets')
		self.assertNotEqual(result.returncode, 0)
		self.assertIn('references nothing under assets/', result.stdout)
		self.assertFalse((self.root / 'DEPLOYED_SHA').exists())


if __name__ == '__main__':
	unittest.main(verbosity=2)
