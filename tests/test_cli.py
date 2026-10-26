"""CLI contract regression tests. All Keychain calls are mocked."""
import argparse
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('keychain_secrets', Path(__file__).resolve().parents[1] / 'scripts/keychain_secrets.py')
cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(cli)


class CLIContracts(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.index = Path(self.folder.name) / 'index.json'
        self.patch = patch.multiple(cli, INDEX_PATH=self.index, LEGACY_INDEX_PATHS=[])
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def entry(self):
        return {'TOKEN': {'env': 'API_TOKEN', 'service': 'svc', 'account': 'test', 'keychain': '/test/private.keychain-db', 'note': 'Example'}}

    def test_metadata_update_keeps_identity_and_never_reads_secret(self):
        cli.save_index(self.entry())
        with patch.object(cli, 'run_security') as security:
            args = cli.build_parser().parse_args(['update', 'TOKEN', '--env', 'NEW_TOKEN', '--note', 'Updated'])
            args.func(args)
        security.assert_not_called()
        saved = cli.load_index()['TOKEN']
        self.assertEqual(saved['env'], 'NEW_TOKEN')
        self.assertEqual(saved['keychain'], '/test/private.keychain-db')
        self.assertEqual(self.index.stat().st_mode & 0o777, 0o600)

    def test_put_stdin_uses_explicit_keychain(self):
        args = cli.build_parser().parse_args(['put', 'TOKEN', '--stdin', '--keychain', '/test/private.keychain-db'])
        with patch('sys.stdin', __import__('io').StringIO('synthetic-test-value\n')), patch.object(cli, 'run_security') as security:
            args.func(args)
        self.assertEqual(security.call_args.args[0][-1], '/test/private.keychain-db')
        self.assertEqual(cli.load_index()['TOKEN']['keychain'], '/test/private.keychain-db')
        self.assertNotIn('synthetic-test-value', self.index.read_text())

    def test_run_injects_env_and_preserves_child_exit(self):
        cli.save_index(self.entry())
        args = cli.build_parser().parse_args(['run', 'TOKEN', '--', 'example', '--flag'])
        with patch.object(cli, 'get_secret', return_value='synthetic-test-value'), patch.object(cli.subprocess, 'run', return_value=subprocess.CompletedProcess([], 7)) as run:
            with self.assertRaises(SystemExit) as result:
                args.func(args)
        self.assertEqual(result.exception.code, 7)
        self.assertEqual(run.call_args.args[0], ['example', '--flag'])
        self.assertEqual(run.call_args.kwargs['env']['API_TOKEN'], 'synthetic-test-value')

    def test_get_refuses_without_show(self):
        args = cli.build_parser().parse_args(['get', 'TOKEN'])
        with patch.object(cli, 'get_secret') as read:
            with self.assertRaises(SystemExit):
                args.func(args)
        read.assert_not_called()

    def test_identity_change_requires_value(self):
        cli.save_index(self.entry())
        args = cli.build_parser().parse_args(['update', 'TOKEN', '--service', 'other'])
        with self.assertRaises(ValueError):
            args.func(args)
        self.assertEqual(cli.load_index(), self.entry())

    def test_existing_subcommands_remain_available(self):
        commands = ['put', 'get', 'export', 'run', 'list', 'info', 'names', 'field', 'update', 'delete', 'app', 'install-app', 'serve', 'open', 'launch', 'stop']
        subparser = next(action for action in cli.build_parser()._actions if isinstance(action, argparse._SubParsersAction))
        self.assertTrue(set(commands).issubset(subparser.choices))


if __name__ == '__main__':
    unittest.main()
