#!/usr/bin/env python3
"""Validate static app translations, source coverage and native bundle metadata.

Uses only the Python standard library. The native test suite additionally loads
these files with Foundation, and the packaged CLI checks language selection.
"""
from __future__ import annotations
from collections import Counter
import json
from pathlib import Path
import re
import sys
import plistlib

ROOT=Path(__file__).resolve().parent.parent
sys.path.insert(0,str(ROOT/'Development'))
from localization_source import explicit_keys

LANGUAGES=('en','it','es','de','fr','zh-Hans','zh-Hant','ja')
ENTRY=re.compile(r'^\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*")\s*;\s*$')
SLOTS=re.compile(r'\$?\{(?:[0-9]+|[A-Za-z][A-Za-z0-9_]*)\}')
FORMATS=re.compile(r'%(?:[0-9]+\$)?[-+ #0]*(?:[0-9]+|\*)?(?:\.(?:[0-9]+|\*))?(?:hh|ll|[hljztL])?[diuoxXfFeEgGaAcCsSp@%]')
# These two keys are consumed by String(format:). Other percent signs are
# literal units or PDF syntax: "% simili" must not be mistaken for "% s".
FORMAT_KEYS={'MediaBox %.2f × %.2f pt; CropBox %.2f × %.2f pt.',
             'Risoluzione minima nella matrice di posizionamento: %.1f dpi.'}


def read_strings(path:Path)->dict[str,str]:
    values={}
    for number,line in enumerate(path.read_text(encoding='utf-8').splitlines(),1):
        stripped=line.strip()
        if not stripped or stripped.startswith('//') or (stripped.startswith('/*') and stripped.endswith('*/')):continue
        match=ENTRY.fullmatch(line)
        if not match:raise ValueError(f'{path.relative_to(ROOT)}:{number}: malformed strings entry')
        key,value=(json.loads(item) for item in match.groups())
        if key in values:raise ValueError(f'{path.relative_to(ROOT)}:{number}: duplicate key')
        if not value:raise ValueError(f'{path.relative_to(ROOT)}:{number}: empty translation')
        values[key]=value
    return values


def edges(value:str)->tuple[str,str]:
    return value[:len(value)-len(value.lstrip())],value[len(value.rstrip()):]


def check(root:Path=ROOT)->dict:
    directory=root/'Sources/CartaPDF/Resources/Localization'
    tables={code:read_strings(directory/(code+'.lproj')/'Localizable.strings') for code in LANGUAGES}
    english=tables['en']
    if not english:raise ValueError('English fallback catalogue is empty')
    inventory=json.loads((root/'Development/LocalizationInventory.json').read_text())
    expected={entry['key'] for entry in inventory['keys'] if entry['key']}
    if set(english)!=expected:raise ValueError('Catalogue and explicit localization inventory differ')
    missing={key:locations for key,locations in explicit_keys(root).items() if key and key not in english}
    if missing:
        locations=[place for places in missing.values() for place in places]
        raise ValueError('Source keys missing from English fallback: '+', '.join(locations[:8]))
    for code,table in tables.items():
        if set(table)!=set(english):raise ValueError('Incomplete key inventory for '+code)
        for key,value in table.items():
            if Counter(SLOTS.findall(key))!=Counter(SLOTS.findall(value)):
                raise ValueError(f'{code}: changed interpolation placeholders for {key!r}')
            if key in FORMAT_KEYS and Counter(FORMATS.findall(key))!=Counter(FORMATS.findall(value)):
                raise ValueError(f'{code}: changed printf formats for {key!r}')
            if edges(key)!=edges(value):raise ValueError(f'{code}: changed fragment whitespace for {key!r}')
    if any(key!=value for key,value in tables['it'].items()):raise ValueError('Italian source catalogue changed')
    info=plistlib.loads((root/'Resources/Info.plist').read_bytes())
    if info.get('CFBundleDevelopmentRegion')!='en':raise ValueError('English development fallback missing')
    if set(info.get('CFBundleLocalizations',[]))!=set(LANGUAGES):raise ValueError('App language declarations differ')
    package=(root/'Package.swift').read_text()
    if 'defaultLocalization: "en"' not in package or '.process("Resources/Localization")' not in package:
        raise ValueError('SwiftPM localization resources/fallback missing')
    for code in LANGUAGES:
        shortcut=read_strings(directory/(code+'.lproj')/'AppShortcuts.strings')
        key='Unisci documenti con ${applicationName}'
        if set(shortcut)!={key} or '${applicationName}' not in shortcut[key]:
            raise ValueError('Native shortcut phrase missing for '+code)
        native=read_strings(directory/(code+'.lproj')/'InfoPlist.strings')
        if not native.get('PDF Document'):raise ValueError('Native document-type localization missing for '+code)
    return {'languages':list(LANGUAGES),'keys_per_language':len(english),
            'source_keys_checked':len([key for key in explicit_keys(root) if key]),
            'placeholders_formats_and_fragment_whitespace':'passed',
            'native_shortcut_and_document_type_tables':'passed',
            'English_fallback':'en','system_preferences_modified':False}

if __name__=='__main__':
    try:print(json.dumps(check(),ensure_ascii=False))
    except (ValueError,OSError,KeyError,json.JSONDecodeError) as error:
        print('Localization check failed: '+str(error),file=sys.stderr)
        raise SystemExit(1)
