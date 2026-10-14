#!/usr/bin/env python3
"""Package a fresh Release payload; no credentials, test bundles or provisioning profiles."""
import pathlib, re, sys, zipfile, subprocess
root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])
app = root / 'Payload/SonicReader.app'
assert app.is_dir(), 'Release App is missing'
assert (app / 'PlugIns/SonicShare.appex/SonicShare').is_file(), 'Share extension is missing'
assert not list(app.rglob('*.xctest')), 'Test bundles must not ship'
assert not list(app.rglob('*.mobileprovision')), 'Unsigned payload must not contain profiles'
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for path in sorted(root.rglob('*')):
        if path.is_file():
            assert not re.search(rb'sk_car_[A-Za-z0-9_-]{12,}', path.read_bytes()), f'Credential marker found in {path.name}'
            archive.write(path, path.relative_to(root))
print(f'{output.name}: {output.stat().st_size:,} bytes; extension present; credential scan passed')

subprocess.run([sys.executable, str(pathlib.Path(__file__).resolve().parent / "deliver-ipa.py"), str(output)], check=True)
