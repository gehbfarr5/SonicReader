#!/usr/bin/env python3
"""Build a separate unsigned iPhone IPA whose runtime group is authorized by a given profile.
Does not import certificates, access private keys, change the source default or register capabilities.
"""
import sys
import argparse, datetime, hashlib, json, pathlib, plistlib, re, shutil, subprocess, tempfile, zipfile

parser = argparse.ArgumentParser()
parser.add_argument('profile', type=pathlib.Path)
parser.add_argument('--group')
parser.add_argument('--version', default='0.1.9')
parser.add_argument('--build', default='10')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parent.parent
profile_path = args.profile.expanduser().resolve()
raw = subprocess.run(['/usr/bin/security', 'cms', '-D', '-i', str(profile_path)], capture_output=True, check=True).stdout
profile = plistlib.loads(raw)
authorized = profile.get('Entitlements', {}).get('com.apple.security.application-groups', [])
assert authorized, 'Profile does not authorize an App Group'
group = args.group or authorized[0]
assert group in authorized and group.startswith('group.'), 'Selected group is not authorized by this profile'
assert profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc) > datetime.datetime.now(datetime.timezone.utc), 'Profile expired'
assert len(profile.get('TeamIdentifier', [])) == 1, 'Expected one signing team'
artifacts = root / 'Artifacts'
artifacts.mkdir(exist_ok=True)
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.version), 'Invalid version'
assert args.build.isdigit(), 'Invalid build'
local_config_path = root / 'release-local.json'
local_config = json.loads(local_config_path.read_text()) if local_config_path.exists() else {}
ipa_suffix = local_config.get('profileIPASuffix', 'profile-matched')
assert re.fullmatch(r'[A-Za-z0-9-]+', ipa_suffix), 'Invalid IPA filename suffix'
output = artifacts / f'SonicReader-{args.version}-{ipa_suffix}-unsigned.ipa'
log = artifacts / f'build-profile-matched-{args.version}.log'
subprocess.run(['xcodegen', 'generate'], cwd=root, check=True, stdout=subprocess.DEVNULL)
with log.open('w') as stream:
    subprocess.run(['xcodebuild', '-project', 'SonicReader.xcodeproj', '-scheme', 'SonicReader',
                    '-configuration', 'Release', '-sdk', 'iphoneos', '-destination', 'generic/platform=iOS',
                    '-derivedDataPath', '.build/ProfileMatched', 'CODE_SIGNING_ALLOWED=NO',
                    'APP_GROUP_ID=' + group, 'MARKETING_VERSION=' + args.version, 'CURRENT_PROJECT_VERSION=' + args.build, 'build'],
                   cwd=root, stdout=stream, stderr=subprocess.STDOUT, check=True)
with tempfile.TemporaryDirectory(prefix='sonic-matched-') as temporary:
    staging = pathlib.Path(temporary)
    app = staging / 'Payload/SonicReader.app'
    shutil.copytree(root / '.build/ProfileMatched/Build/Products/Release-iphoneos/SonicReader.app', app)
    extension = app / 'PlugIns/SonicShare.appex'
    assert not list(app.rglob('*.xctest')), 'Test bundles must not ship'
    bundles = []
    for bundle in [app, extension]:
        info = plistlib.loads((bundle / 'Info.plist').read_bytes())
        assert info['SonicAppGroup'] == group, 'Runtime group differs between targets'
        assert info['CFBundleShortVersionString'] == args.version and info['CFBundleVersion'] == args.build
        bundles.append({'bundleID': info['CFBundleIdentifier'], 'runtimeAppGroup': info['SonicAppGroup']})
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(staging.rglob('*')):
            if not path.is_file():
                continue
            assert not re.search(rb'sk_car_[A-Za-z0-9_-]{12,}', path.read_bytes()), 'Credential detected in release payload'
            archive.write(path, path.relative_to(staging))
manifest = {
    'status': 'PASS', 'scope': 'unsigned runtime configuration matches supplied profile; signing and device checks remain',
    'version': args.version, 'build': args.build, 'team': profile['TeamIdentifier'][0], 'selectedAppGroup': group,
    'profileSHA256': hashlib.sha256(profile_path.read_bytes()).hexdigest(),
    'profileApplicationIdentifier': profile['Entitlements'].get('application-identifier'),
    'deviceCount': len(profile.get('ProvisionedDevices', [])), 'bundles': bundles,
    'ipaSHA256': hashlib.sha256(output.read_bytes()).hexdigest(), 'bytes': output.stat().st_size,
    'privateKeyAccessed': False, 'signed': False,
    'bundleIDProfileMatch': all(profile['Entitlements'].get('application-identifier', '').endswith('.' + b['bundleID']) for b in bundles),
    'note': 'FullSign certificate-specific application identifier remapping still requires signing and device validation. Standard strict signature checks must not be bypassed.'
}
(artifacts / f'profile-matched-check-{args.version}.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
(artifacts / f'SonicReader-{args.version}-signing-groups.plist').write_bytes(plistlib.dumps({'com.apple.security.application-groups': [group]}))
print(json.dumps({'output': str(output), 'runtimeGroup': group, 'signed': False, 'sha256': manifest['ipaSHA256']}, ensure_ascii=False))

subprocess.run([sys.executable, str(root / "Scripts/deliver-ipa.py"), str(output)], check=True)
