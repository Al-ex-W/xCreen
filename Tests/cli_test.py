import importlib.machinery
import importlib.util
import pathlib
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / 'bin/xcreen'
loader = importlib.machinery.SourceFileLoader('xcreen_cli', str(path))

class CLITests(unittest.TestCase):
    def test_literal_json_arguments_are_not_global_options(self):
        from unittest.mock import patch
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None
        cli = importlib.util.module_from_spec(spec)
        loader.exec_module(cli)
        for args, expected in [(['ask', '--json'], {'command': 'ask', 'question': '--json', 'wait_ms': 0}),
                               (['ask', '--wait-ms'], {'command': 'ask', 'question': '--wait-ms', 'wait_ms': 0}),
                               (['settings', 'set', 'vault', '--json'], {'command': 'settings', 'value': 'vault=--json'})]:
            with patch.object(cli, 'request', return_value={'ok': True}) as request, patch('builtins.print'):
                cli.main(args)
                request.assert_called_once_with(expected)

    def test_session_visibility_parser(self):
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None
        cli = importlib.util.module_from_spec(spec)
        loader.exec_module(cli)
        for value in ('get', 'on', 'off'):
            expected = {'command': 'visibility'}
            if value != 'get': expected['value'] = value
            self.assertEqual(cli.parse_command(['session', 'visibility', value]), expected)
        for args in (['session', 'visibility', 'maybe'], ['session', 'visibility', 'on', 'off']):
            self.assertRaises(ValueError, cli.parse_command, args)

    def test_bounded_history_and_batch_page_parser(self):
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None
        cli = importlib.util.module_from_spec(spec)
        loader.exec_module(cli)
        for name in ('history', 'batches'):
            self.assertEqual(cli.parse_command([name]), {'command': name})
            self.assertEqual(cli.parse_command([name, '--after', 'stable-cursor']), {'command': name, 'value': 'stable-cursor'})
            self.assertRaises(ValueError, cli.parse_command, [name, '--after'])

    def test_model_default_and_batch_retry_parser(self):
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None
        cli = importlib.util.module_from_spec(spec)
        loader.exec_module(cli)
        self.assertEqual(cli.parse_command(['model', 'default']), {'command': 'modeldefault'})
        self.assertEqual(cli.parse_command(['model', 'default', 'get']), {'command': 'modeldefault'})
        self.assertEqual(cli.parse_command(['model', 'default', 'openrouter', 'anthropic/claude-haiku-5.5']),
                         {'command': 'modeldefault', 'provider': 'openrouter', 'model': 'anthropic/claude-haiku-5.5'})
        self.assertEqual(cli.parse_command(['model', 'select', 'copilot', 'claude-haiku-5.5']),
                         {'command': 'model', 'provider': 'copilot', 'model': 'claude-haiku-5.5'})
        self.assertEqual(cli.parse_command(['batches', 'retry']), {'command': 'retrybatches'})
        for args in (['model', 'default', 'openrouter'], ['batches', 'retry', '--all']):
            self.assertRaises(ValueError, cli.parse_command, args)

    def test_verify_is_one_readonly_control_request(self):
        from unittest.mock import patch
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None
        cli = importlib.util.module_from_spec(spec)
        loader.exec_module(cli)
        with patch.object(cli, 'request', return_value={'ok': True, 'reply': 'verified'}) as request, patch('builtins.print'):
            self.assertEqual(cli.main(['verify']), 0)
            request.assert_called_once_with({'command': 'verify'})
        self.assertRaises(ValueError, cli.parse_command, ['verify', '--write'])

    def test_integrity_get_and_off_consent(self):
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None
        cli = importlib.util.module_from_spec(spec)
        loader.exec_module(cli)
        self.assertEqual(cli.parse_command(['integrity', 'get']), {'command': 'integrity'})
        self.assertEqual(cli.parse_command(['integrity', 'off']), {'command': 'integrity', 'value': 'off'})
        self.assertEqual(cli.parse_command(['model', 'select', 'provider', 'exact/model']), {'command': 'model', 'provider': 'provider', 'model': 'exact/model'})
        self.assertEqual(cli.parse_command(['settings', 'set', 'vault', '']), {'command': 'settings', 'value': 'vault='})
        self.assertRaises(ValueError, cli.parse_command, ['integrity', 'maybe'])

if __name__ == '__main__':
    unittest.main()
