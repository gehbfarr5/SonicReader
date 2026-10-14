#!/usr/bin/env python3
"""Publish this project's IPA atomically to the user's fixed iCloud Inbox; verify local bytes.
Local verification does not claim iCloud upload or iPhone download completion.
"""
import hashlib, json, os, pathlib, shutil, sys, uuid
source = pathlib.Path(sys.argv[1]).resolve()
assert source.suffix == '.ipa' and source.is_file(), 'Expected an existing IPA'
config_path = pathlib.Path(__file__).resolve().parent.parent / 'release-local.json'
if not config_path.exists():
    print(json.dumps({'status': 'not_configured', 'source': str(source), 'note': 'Optional extra delivery is not configured; IPA stays at its build output.'}))
    sys.exit(0)
config = json.loads(config_path.read_text())
destination_dir = pathlib.Path(config['deliveryDirectory']).expanduser()
assert destination_dir.is_absolute(), 'Delivery directory must be absolute'
assert destination_dir.is_dir(), 'Configured iCloud Inbox is unavailable; delivery must not silently redirect'
destination = destination_dir / source.name
staging = destination_dir / ('.sonic-delivery-' + str(uuid.uuid4()) + '.ipa')
shutil.copyfile(source, staging)
source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
assert hashlib.sha256(staging.read_bytes()).hexdigest() == source_hash, 'Copied IPA hash mismatch'
os.replace(staging, destination)
assert hashlib.sha256(destination.read_bytes()).hexdigest() == source_hash
manifest = {'status': 'PASS', 'scope': 'local iCloud Inbox file bytes verified; cloud upload and phone download not verified',
            'source': str(source), 'destination': str(destination), 'sha256': source_hash, 'bytes': destination.stat().st_size}
(source.parent / (source.stem + '-delivery.json')).write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(manifest, ensure_ascii=False))
