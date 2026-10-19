#!/usr/bin/env python3
"""Validate release metadata and publish a verified, signed Sparkle feed."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
REPO = 'iOSDeveloperGuy/DiscShift'
NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def config():
    data = json.loads((ROOT / 'release.json').read_text())
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', data['version']):
        raise ValueError('Use a numeric semantic version')
    if type(data['build']) is not int or not 0 < data['build'] < 2147483647:
        raise ValueError('Use a positive, increasing build number')
    if type(data['prerelease']) is not bool:
        raise ValueError('prerelease must be true or false')
    if data['feedURL'] != f'https://raw.githubusercontent.com/{REPO}/updates/appcast.xml':
        raise ValueError('Unexpected update feed location')
    if len(base64.b64decode(data['publicEDKey'], validate=True)) != 32:
        raise ValueError('Invalid Ed25519 public key')
    if not (ROOT / 'release-notes' / (data['version'] + '.md')).is_file():
        raise ValueError('Add release notes for this version')
    return data


def read_feed(path):
    root = ET.parse(path).getroot()
    return [int(e.text) for e in root.findall(f'./channel/item/{NS}version')]


def get_previous_feed(directory):
    # A missing updates branch is valid for the first release. Other API errors
    # must fail closed rather than silently discarding published update history.
    refs = json.loads(run('gh', 'api', f'repos/{REPO}/git/matching-refs/heads/updates'))
    if not any(r['ref'] == 'refs/heads/updates' for r in refs):
        return None
    data = json.loads(run('gh', 'api', f'repos/{REPO}/contents/appcast.xml?ref=updates'))
    path = directory / 'appcast.xml'
    path.write_bytes(base64.b64decode(data['content']))
    return data['sha']


def prepare(directory, tools, archive):
    data = config()
    directory.mkdir(parents=True, exist_ok=True)
    previous_sha = get_previous_feed(directory)
    feed = directory / 'appcast.xml'
    if feed.exists():
        if max(read_feed(feed), default=0) > data['build']:
            raise ValueError('Refusing to roll the update feed back to an older build')
        for item in ET.parse(feed).findall('./channel/item'):
            if item.findtext(NS + 'version') == str(data['build']) and item.findtext(NS + 'shortVersionString') != data['version']:
                raise ValueError('Build number already belongs to another version; increment it')
    expected = f"DiscShift-{data['version']}-macOS.zip"
    if archive.name != expected:
        raise ValueError(f'Expected {expected}')
    import shutil
    staged = directory / expected
    if archive.resolve() != staged.resolve():
        shutil.copyfile(archive, staged)
    # Verify the exact final downloadable archive, including its stapled ticket.
    with tempfile.TemporaryDirectory(prefix='discshift-publish-check-') as tmp:
        subprocess.run(['ditto', '-x', '-k', str(staged), tmp], check=True)
        app = Path(tmp) / 'DiscShift.app'
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        for key, value in {'CFBundleIdentifier': 'com.iosdeveloperguy.discshift',
                           'CFBundleVersion': str(data['build']),
                           'CFBundleShortVersionString': data['version'],
                           'SUPublicEDKey': data['publicEDKey'],
                           'SUFeedURL': data['feedURL'],
                           'SURequireSignedFeed': True,
                           'SUVerifyUpdateBeforeExtraction': True}.items():
            if info.get(key) != value:
                raise ValueError(f'Archive metadata differs from release.json: {key}')
        for command in [['codesign', '--verify', '--deep', '--strict', str(app)],
                        ['xcrun', 'stapler', 'validate', str(app)],
                        ['spctl', '--assess', '--type', 'execute', str(app)]]:
            attempts = 1 if command[0] == 'codesign' else 5
            for attempt in range(attempts):
                result = subprocess.run(command)
                if result.returncode == 0:
                    break
                if attempt + 1 == attempts:
                    result.check_returncode()
                time.sleep(5)
        signature = run('codesign', '-dv', '--verbose=4', str(app), stderr=subprocess.STDOUT)
        if 'TeamIdentifier=UJ27S8B847' not in signature or 'Authority=Developer ID Application:' not in signature:
            raise ValueError('Unexpected Developer ID signing team')
    # HTML-escape plain release notes before embedding, never execute Markdown HTML.
    import html
    notes = (ROOT / 'release-notes' / (data['version'] + '.md')).read_text()
    (directory / expected.replace('.zip', '.html')).write_text('<pre>' + html.escape(notes) + '</pre>')
    args = [str(tools / 'generate_appcast'), '--download-url-prefix',
            f"https://github.com/{REPO}/releases/download/v{data['version']}/",
            '--link', f'https://github.com/{REPO}', '--maximum-deltas', '0',
            '--maximum-versions', '5', '--embed-release-notes']
    key = os.environ.get('SPARKLE_ED_PRIVATE_KEY')
    if key:
        args += ['--ed-key-file', '-']
    else:
        args += ['--account', 'com.iosdeveloperguy.discshift']
    subprocess.run(args + [str(directory)], input=key, text=True, check=True)
    # Verify both the feed and the enclosure with the same signing tool.
    verify = [str(tools / 'sign_update'), '--verify']
    verify += ['--ed-key-file', '-'] if key else ['--account', 'com.iosdeveloperguy.discshift']
    subprocess.run(verify + [str(feed)], input=key, text=True, check=True)
    item = next(i for i in ET.parse(feed).findall('./channel/item') if i.findtext(NS + 'version') == str(data['build']))
    enclosure = item.find('enclosure')
    if enclosure is None or enclosure.get('url') != f"https://github.com/{REPO}/releases/download/v{data['version']}/{expected}":
        raise ValueError('Unexpected archive URL in generated feed')
    subprocess.run(verify + [str(staged), enclosure.get(NS + 'edSignature', '')], input=key, text=True, check=True)
    (directory / 'previous-sha.json').write_text(json.dumps(previous_sha))
    (directory / 'SHA256SUMS.txt').write_text(hashlib.sha256(staged.read_bytes()).hexdigest() + '  ' + expected + '\n')


def publish(directory, commit):
    data = config()
    tag = 'v' + data['version']
    archive = directory / f"DiscShift-{data['version']}-macOS.zip"
    feed = directory / 'appcast.xml'
    # Publication only consumes output from prepare(). No arbitrary unsigned feed.
    if not (directory / 'previous-sha.json').is_file() or not feed.exists():
        raise ValueError('Run prepare first')
    tags = json.loads(run('gh', 'api', f'repos/{REPO}/releases?per_page=100'))
    existing = next((r for r in tags if r['tag_name'] == tag), None)
    if existing is None:
        subprocess.run(['gh', 'release', 'create', tag, '--repo', REPO, '--target', commit,
                        '--draft', '--title', f"DiscShift {data['version']}",
                        '--notes-file', str(ROOT / 'release-notes' / (data['version'] + '.md'))], check=True)
    if existing is None or existing['draft']:
        subprocess.run(['gh', 'release', 'upload', tag, str(archive), str(directory / 'SHA256SUMS.txt'),
                        '--repo', REPO, '--clobber'], check=True)
        subprocess.run(['gh', 'release', 'edit', tag, '--repo', REPO, '--draft=false',
                        '--prerelease=' + str(data['prerelease']).lower()], check=True)
    # Compare a fresh public download before offering this version to installed apps.
    with tempfile.TemporaryDirectory(prefix='discshift-public-check-') as tmp:
        subprocess.run(['gh', 'release', 'download', tag, '--repo', REPO,
                        '--pattern', archive.name, '--dir', tmp], check=True)
        if hashlib.sha256((Path(tmp) / archive.name).read_bytes()).digest() != hashlib.sha256(archive.read_bytes()).digest():
            raise ValueError('Published archive differs; refusing to change the update feed')
    sha = json.loads((directory / 'previous-sha.json').read_text())
    if sha is None:
        run('gh', 'api', '--method', 'POST', f'repos/{REPO}/git/refs',
            '-f', 'ref=refs/heads/updates', '-f', 'sha=' + commit)
    payload = {'message': f"Publish signed update feed for {tag}", 'branch': 'updates',
               'content': base64.b64encode(feed.read_bytes()).decode()}
    if sha:
        payload['sha'] = sha
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json') as handle:
        json.dump(payload, handle); handle.flush()
        run('gh', 'api', '--method', 'PUT', f'repos/{REPO}/contents/appcast.xml', '--input', handle.name)
    remote = json.loads(run('gh', 'api', f'repos/{REPO}/contents/appcast.xml?ref=updates'))
    if base64.b64decode(remote['content']) != feed.read_bytes():
        raise ValueError('Published update feed does not match')
    print(f'Published and verified {tag} and its signed update feed.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['check', 'prepare', 'publish'])
    parser.add_argument('--directory', type=Path, default=ROOT / 'dist/updates')
    parser.add_argument('--tools', type=Path)
    parser.add_argument('--archive', type=Path)
    parser.add_argument('--commit', default='HEAD')
    args = parser.parse_args()
    if args.command == 'check':
        data = config()
        print(f"DiscShift {data['version']} (build {data['build']})")
        return
    if args.command == 'prepare':
        if not args.tools or not args.archive:
            parser.error('prepare needs --tools and --archive')
        prepare(args.directory.resolve(), args.tools.resolve(), args.archive.resolve())
    else:
        publish(args.directory.resolve(), run('git', 'rev-parse', args.commit))


if __name__ == '__main__':
    main()
