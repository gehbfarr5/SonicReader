#!/usr/bin/env python3
"""Read-only macOS check of an IPA exported after re-signing. Prints no secrets."""
import datetime, fnmatch, json, pathlib, plistlib, subprocess, sys, tempfile, zipfile

def run(*args):
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise ValueError(f'{args[0]} failed: {result.stderr.decode(errors="replace")[-500:]}')
    return result.stdout

try:
    source = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='sonic-sign-check-') as temporary:
        root = pathlib.Path(temporary).resolve()
        with zipfile.ZipFile(source) as archive:
            for name in archive.namelist():
                target = (root / name).resolve()
                if root not in target.parents:
                    raise ValueError('Unsafe archive path')
            archive.extractall(root)
        apps = list((root / 'Payload').glob('*.app'))
        if len(apps) != 1:
            raise ValueError('Expected one main App')
        app = apps[0]
        extensions = list((app / 'PlugIns').glob('*.appex'))
        if len(extensions) != 1:
            raise ValueError('Missing or unexpected share extension')
        results = []
        for bundle in [app, extensions[0]]:
            info = plistlib.loads((bundle / 'Info.plist').read_bytes())
            profile_path = bundle / 'embedded.mobileprovision'
            if not profile_path.exists():
                raise ValueError(f'{bundle.name}: provisioning profile missing; package is not install-ready')
            profile = plistlib.loads(run('/usr/bin/security', 'cms', '-D', '-i', str(profile_path)))
            entitlement_data = run('/usr/bin/codesign', '-d', '--entitlements', ':-', str(bundle))
            entitlements = plistlib.loads(entitlement_data)
            run('/usr/bin/codesign', '--verify', '--strict', '--all-architectures', str(bundle))
            group = info.get('SonicAppGroup')
            if not isinstance(group, str) or not group.startswith('group.'):
                raise ValueError(f'{bundle.name}: runtime App Group missing')
            if group not in entitlements.get('com.apple.security.application-groups', []):
                raise ValueError(f'{bundle.name}: signed entitlement does not include runtime App Group')
            if group not in profile.get('Entitlements', {}).get('com.apple.security.application-groups', []):
                raise ValueError(f'{bundle.name}: profile does not authorize App Group')
            signed_team = entitlements.get('com.apple.developer.team-identifier')
            if signed_team not in profile.get('TeamIdentifier', []):
                raise ValueError(f'{bundle.name}: signing team not authorized by profile')
            certificate_prefix = str(root / (bundle.name + '-certificate-'))
            run('/usr/bin/codesign', '-d', '--extract-certificates', certificate_prefix, str(bundle))
            leaf = pathlib.Path(certificate_prefix + '0')
            if not leaf.exists() or leaf.read_bytes() not in profile.get('DeveloperCertificates', []):
                raise ValueError(f'{bundle.name}: signing certificate not authorized by profile')
            expiration = profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc)
            if expiration <= datetime.datetime.now(datetime.timezone.utc):
                raise ValueError(f'{bundle.name}: profile expired')
            app_identifier = entitlements.get('application-identifier', '')
            profile_id = profile.get('Entitlements', {}).get('application-identifier', '')
            if not fnmatch.fnmatchcase(app_identifier, profile_id):
                raise ValueError(f'{bundle.name}: application identifier not permitted by profile')
            if not app_identifier.endswith('.' + info['CFBundleIdentifier']):
                raise ValueError(f'{bundle.name}: signature and bundle identifier disagree')
            results.append({'bundle': info['CFBundleIdentifier'], 'appGroup': group,
                            'team': entitlements.get('com.apple.developer.team-identifier'),
                            'profileExpires': expiration.date().isoformat(),
                            'distribution': 'enterprise' if profile.get('ProvisionsAllDevices') else 'device-specific'})
        if not results[0]['team'] or results[0]['team'] != results[1]['team']:
            raise ValueError('Main App and extension must be signed by the same team')
        if results[0]['appGroup'] != results[1]['appGroup']:
            raise ValueError('Main App and extension must use the same App Group')
        if not results[1]['bundle'].startswith(results[0]['bundle'] + '.'):
            raise ValueError('Extension bundle ID must be prefixed by the main App bundle ID')
        extension_info = plistlib.loads((extensions[0] / 'Info.plist').read_bytes())
        if extension_info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.share-services':
            raise ValueError('Share extension entry point missing')
        print(json.dumps({'status': 'PASS', 'scope': 'signature/profile structure; device installation still required', 'bundles': results}, ensure_ascii=False, indent=2))
except (IndexError, ValueError, KeyError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
    print(json.dumps({'status': 'BLOCKED', 'reason': str(error)}, ensure_ascii=False, indent=2))
    sys.exit(1)
