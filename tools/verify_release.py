"""Verify frozen artifact hashes, HDL source identity, assets and model references."""
from pathlib import Path
import hashlib
import json
import re

ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
release=json.loads((ROOT/'release.json').read_text(encoding='utf-8'))
original=json.loads((ROOT/'verification/original_build_inputs.json').read_text(encoding='utf-8'))
changed=[]
for path,digest in original.items():
    if not (ROOT/path).is_file() or sha(ROOT/path)!=digest:changed.append(path)
if changed:raise ValueError('Frozen HDL/assets changed: '+repr(changed))
assert sha(ROOT/release['bit'])==release['bit_sha256']
identity=release['model'];model=ROOT/'minimal/model/model_init.bin'
assert sha(model)==identity['model_sha256']
assert sha(ROOT/identity['package']/'model_init.bin')==identity['model_sha256']
assert sha(ROOT/identity['float_run']/'model_state.pth')==identity['float_sha256']
assert (ROOT/'minimal/model/model_identity.json').read_bytes()==(ROOT/'car_test/PL/teacher/data/model_identity.json').read_bytes()
assert not list((ROOT/'car_test/PL/teacher/video').glob('parking*'))
minimal=(ROOT/'minimal/fpga/video.v').read_text(encoding='utf-8')
assert not re.search(r'[A-Z]:[/\\]',minimal)
for name in ['ov5640_vga_rgb888.hex',*[f'osd_font{i}.hex' for i in range(4)]]:
    assert 'assets/'+name in minimal
    assert sha(ROOT/'minimal/fpga/assets'/name)==sha(ROOT/'car_test/PL/data'/name)
for manifest_path,prefix in [(ROOT/'SHA256SUMS.json',ROOT),(ROOT/'minimal/SHA256SUMS.json',ROOT/'minimal')]:
    if manifest_path.exists():
        for path,digest in json.loads(manifest_path.read_text()).items():
            if sha(prefix/path)!=digest:raise ValueError('Package checksum mismatch: '+path)
print('PASS: '+str(len(original))+' original build inputs, bit/model/float source, minimal ROMs and release manifests')
