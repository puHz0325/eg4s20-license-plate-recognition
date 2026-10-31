"""Verify frozen artifact hashes, HDL source identity, assets and model references."""
from pathlib import Path
import argparse
import hashlib
import json
import re

ROOT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--skip-package-manifests',action='store_true',help='Check source/model identity while preparing fresh package manifests')
args=parser.parse_args()
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
release=json.loads((ROOT/'release.json').read_text(encoding='utf-8'))
original=json.loads((ROOT/'verification/original_build_inputs.json').read_text(encoding='utf-8'))
migration=json.loads((ROOT/'verification/filename_migration.json').read_text(encoding='utf-8'))
def original_bytes(data):
    text=data.decode('utf-8')
    for old,new in reversed(migration['text_replacements']):text=text.replace(new,old)
    return text.encode('utf-8')
changed=[]
for path,digest in original.items():
    current=ROOT/migration['renamed_paths'].get(path,path)
    if not current.is_file():changed.append(path);continue
    data=current.read_bytes()
    if hashlib.sha256(data).hexdigest()!=digest and hashlib.sha256(original_bytes(data)).hexdigest()!=digest:changed.append(path)
if changed:raise ValueError('Frozen HDL/assets changed: '+repr(changed))
assert sha(ROOT/release['bit'])==release['bit_sha256']
identity=release['model'];model=ROOT/'minimal/model/model_init.bin'
assert sha(model)==identity['model_sha256']
assert sha(ROOT/identity['package']/'model_init.bin')==identity['model_sha256']
assert sha(ROOT/identity['float_run']/'model_state.pth')==identity['float_sha256']
assert (ROOT/'minimal/model/model_identity.json').read_bytes()==(ROOT/'car_test/PL/lpr8/data/model_identity.json').read_bytes()
assert not list((ROOT/'car_test/PL/lpr8/video').glob('parking*'))
minimal=(ROOT/'minimal/fpga/video.v').read_text(encoding='utf-8')
assert not re.search(r'[A-Z]:[/\\]',minimal)
for name in ['ov5640_vga_rgb888.hex',*[f'osd_font{i}.hex' for i in range(4)]]:
    assert 'assets/'+name in minimal
    assert sha(ROOT/'minimal/fpga/assets'/name)==sha(ROOT/'car_test/PL/data'/name)
for manifest_path,prefix in [(ROOT/'SHA256SUMS.json',ROOT),(ROOT/'minimal/SHA256SUMS.json',ROOT/'minimal')]:
    if manifest_path.exists() and not args.skip_package_manifests:
        for path,digest in json.loads(manifest_path.read_text()).items():
            if sha(prefix/path)!=digest:raise ValueError('Package checksum mismatch: '+path)
print('PASS: '+str(len(original))+' original build inputs after reversible filename normalization, unchanged bit/model/ROMs, release manifests')
