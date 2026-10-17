#!/usr/bin/env python3
"""Fail loudly when a built Metadata.appintents bundle cannot surface Ask xCreen in Spotlight.

Usage: check-appintents-metadata.py <path/to/Metadata.appintents>
Prints the App Shortcut phrases on success. Exit 1 with a reason on stderr otherwise.
"""
import json
import pathlib
import sys

REQUIRED_ACTION = 'AskXCreenIntent'


def fail(message):
    print(f'App Intents metadata check failed: {message}', file=sys.stderr)
    return 1


def main(argv):
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
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
