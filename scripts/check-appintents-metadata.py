#!/usr/bin/env python3
"""Fail loudly when a built Metadata.appintents bundle cannot surface Ask xCreen in Spotlight.

Usage: check-appintents-metadata.py <path/to/Metadata.appintents>
       check-appintents-metadata.py --allow-missing-constvalues <xcode-version>
The second form exits 0 (with a warning) only when CI=true and Xcode is older than
REQUIRED_XCODE_MAJOR, whose swift build cannot emit XCreenApp const values; locally it always fails.
Prints the App Shortcut phrases on success. Exit 1 with a reason on stderr otherwise.
"""
import json
import os
import pathlib
import sys

REQUIRED_ACTION = 'AskXCreenIntent'
SEARCH_ACTION = 'SearchXCreenIntent'
SEARCH_PROTOCOL = 'com.apple.link.systemProtocol.ShowInAppStringSearchResults'


def fail(message):
    print(f'App Intents metadata check failed: {message}', file=sys.stderr)
    return 1


REQUIRED_XCODE_MAJOR = 27


def allow_missing_constvalues(version):
    try:
        major = int(version.split('.')[0])
    except ValueError:
        return fail(f'unparseable Xcode version {version!r}')
    if os.environ.get('CI') == 'true' and major < REQUIRED_XCODE_MAJOR:
        print(f'warning: CI Xcode {version} < {REQUIRED_XCODE_MAJOR} emits no XCreenApp .swiftconstvalues; '
              'skipping App Intents metadata (Spotlight actions NOT verified on this runner).', file=sys.stderr)
        return 0
    return fail(f'swift build emitted no XCreenApp .swiftconstvalues with Xcode {version}; Spotlight actions would be missing')


def main(argv):
    if len(argv) == 3 and argv[1] == '--allow-missing-constvalues':
        return allow_missing_constvalues(argv[2])
    if len(argv) != 2:
        return fail('usage: check-appintents-metadata.py <Metadata.appintents>')
    root = pathlib.Path(argv[1])
    data_path = root / 'extract.actionsdata'
    if not data_path.is_file():
        return fail(f'{data_path} is missing')
    if not (root / 'version.json').is_file():
        return fail(f'{root / "version.json"} is missing')
    try:
        data = json.loads(data_path.read_text())
    except (OSError, ValueError) as error:
        return fail(f'{data_path} is not readable JSON ({error})')

    actions = data.get('actions') or {}
    action = actions.get(REQUIRED_ACTION)
    if not isinstance(action, dict):
        return fail(f'action {REQUIRED_ACTION} is missing')
    visibility = action.get('visibilityMetadata') or {}
    if visibility.get('isDiscoverable') is False or visibility.get('assistantOnly') is True:
        return fail(f'action {REQUIRED_ACTION} is hidden from Spotlight/Shortcuts')
    if not data.get('autoShortcutProviderMangledName'):
        return fail('autoShortcutProviderMangledName is missing (no AppShortcutsProvider const values?)')
    shortcuts = data.get('autoShortcuts') or []
    if not shortcuts:
        return fail('autoShortcuts is empty (AppShortcutsProvider not extracted)')
    if not any(s.get('actionIdentifier') == REQUIRED_ACTION for s in shortcuts):
        return fail(f'no App Shortcut exposes {REQUIRED_ACTION}')

    for shortcut in shortcuts:
        phrases = [p.get('key', '') for p in shortcut.get('phraseTemplates') or []]
        title = (shortcut.get('shortTitle') or {}).get('key', '')
        print(f"{shortcut.get('actionIdentifier')} ({title}): " + ' | '.join(phrases))

    error = check_search_action(actions)
    if error:
        return fail(error)
    print(f'{SEARCH_ACTION}: {SEARCH_PROTOCOL} scopes=[general] '
          '(Spotlight "Search in Apps" row for any query)')
    return 0


def check_search_action(actions):
    """The Notes-style 'Search xCreen' row needs ShowInAppStringSearchResults with the general scope."""
    action = actions.get(SEARCH_ACTION)
    if not isinstance(action, dict):
        return f'action {SEARCH_ACTION} is missing'
    visibility = action.get('visibilityMetadata') or {}
    if visibility.get('isDiscoverable') is False or visibility.get('assistantOnly') is True:
        return f'action {SEARCH_ACTION} is hidden from Spotlight'
    if SEARCH_PROTOCOL not in (action.get('systemProtocols') or []):
        return f'action {SEARCH_ACTION} lacks system protocol {SEARCH_PROTOCOL}'
    scopes = []
    for key in ('systemProtocolMetadata', 'systemProtocolMetadataV2'):
        meta = action.get(key) or []
        # Encoded as a flat [protocol, payload, protocol, payload, ...] list.
        for name, payload in zip(meta[::2], meta[1::2]):
            if name == SEARCH_PROTOCOL and isinstance(payload, dict):
                scopes += (payload.get('showInAppStringSearchResults') or {}).get('searchScopes') or []
    if 'general' not in scopes:
        return f'action {SEARCH_ACTION} {SEARCH_PROTOCOL} metadata lacks the general search scope'
    criteria = [p for p in action.get('parameters') or [] if p.get('name') == 'criteria']
    if not criteria or 'searchCriteria' not in (criteria[0].get('valueType') or {}):
        return f'action {SEARCH_ACTION} lacks a searchCriteria criteria parameter'
    return None


if __name__ == '__main__':
    sys.exit(main(sys.argv))
