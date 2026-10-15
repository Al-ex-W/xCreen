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
