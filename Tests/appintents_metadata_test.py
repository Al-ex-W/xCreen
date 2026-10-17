import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/check-appintents-metadata.py'
SEARCH_PROTOCOL = 'com.apple.link.systemProtocol.ShowInAppStringSearchResults'


def good_metadata():
    return {
        'actions': {'AskXCreenIntent': {'visibilityMetadata': {'isDiscoverable': True, 'assistantOnly': False}},
                    'OpenXCreenIntent': {'visibilityMetadata': {'isDiscoverable': True, 'assistantOnly': False}},
                    'SearchXCreenIntent': {
                        'visibilityMetadata': {'isDiscoverable': True, 'assistantOnly': False},
                        'systemProtocols': [SEARCH_PROTOCOL],
                        'systemProtocolMetadata': [SEARCH_PROTOCOL,
                                                   {'showInAppStringSearchResults': {'searchScopes': ['general']}}],
                        'parameters': [{'name': 'criteria',
                                        'valueType': {'searchCriteria': {'wrapper': {'typeIdentifier': 0}}}}],
                    }},
        'autoShortcutProviderMangledName': '9XCreenApp0A9ShortcutsV',
        'autoShortcuts': [
            {'actionIdentifier': 'AskXCreenIntent', 'phraseTemplates': [{'key': 'Ask ${applicationName}'}]},
            {'actionIdentifier': 'OpenXCreenIntent', 'phraseTemplates': [{'key': 'Open ${applicationName}'}]},
        ],
    }


class AppIntentsMetadataCheckTests(unittest.TestCase):
    def run_check(self, metadata, version=True):
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
            root = pathlib.Path(tmp) / 'Metadata.appintents'
            root.mkdir()
            if metadata is not None:
                (root / 'extract.actionsdata').write_text(json.dumps(metadata))
            if version:
                (root / 'version.json').write_text('{"version": "3.0"}')
            return subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)

    def test_accepts_complete_metadata_and_prints_phrases(self):
        result = self.run_check(good_metadata())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Ask ${applicationName}', result.stdout)

    def test_rejects_missing_auto_shortcuts(self):
        metadata = good_metadata()
        metadata['autoShortcuts'] = []
        result = self.run_check(metadata)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('autoShortcuts', result.stderr)

    def test_rejects_missing_provider_name(self):
        metadata = good_metadata()
        del metadata['autoShortcutProviderMangledName']
        self.assertNotEqual(self.run_check(metadata).returncode, 0)

    def test_rejects_missing_or_hidden_ask_action(self):
        metadata = good_metadata()
        del metadata['actions']['AskXCreenIntent']
        self.assertNotEqual(self.run_check(metadata).returncode, 0)
        metadata = good_metadata()
        metadata['actions']['AskXCreenIntent']['visibilityMetadata']['isDiscoverable'] = False
        self.assertNotEqual(self.run_check(metadata).returncode, 0)

    def test_rejects_shortcut_without_ask_action(self):
        metadata = good_metadata()
        metadata['autoShortcuts'] = metadata['autoShortcuts'][1:]
        self.assertNotEqual(self.run_check(metadata).returncode, 0)

    def test_rejects_missing_or_hidden_search_action(self):
        metadata = good_metadata()
        del metadata['actions']['SearchXCreenIntent']
        result = self.run_check(metadata)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SearchXCreenIntent', result.stderr)
        metadata = good_metadata()
        metadata['actions']['SearchXCreenIntent']['visibilityMetadata']['isDiscoverable'] = False
        self.assertNotEqual(self.run_check(metadata).returncode, 0)

    def test_rejects_search_action_without_system_protocol(self):
        metadata = good_metadata()
        metadata['actions']['SearchXCreenIntent']['systemProtocols'] = []
        result = self.run_check(metadata)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ShowInAppStringSearchResults', result.stderr)

    def test_rejects_search_action_without_general_scope(self):
        for scopes in ([], ['movies'], None):
            metadata = good_metadata()
            action = metadata['actions']['SearchXCreenIntent']
            if scopes is None:
                action['systemProtocolMetadata'] = [SEARCH_PROTOCOL]
            else:
                action['systemProtocolMetadata'][1]['showInAppStringSearchResults']['searchScopes'] = scopes
            result = self.run_check(metadata)
            self.assertNotEqual(result.returncode, 0, scopes)
            self.assertIn('general', result.stderr)

    def test_rejects_search_action_without_criteria_parameter(self):
        metadata = good_metadata()
        metadata['actions']['SearchXCreenIntent']['parameters'] = []
        result = self.run_check(metadata)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('criteria', result.stderr)

    def test_reports_search_row(self):
        result = self.run_check(good_metadata())
        self.assertIn('SearchXCreenIntent', result.stdout)

    def test_rejects_missing_files(self):
        self.assertNotEqual(self.run_check(None).returncode, 0)
        self.assertNotEqual(self.run_check(good_metadata(), version=False).returncode, 0)


if __name__ == '__main__':
    unittest.main()
