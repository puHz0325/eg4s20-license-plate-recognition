"""One generated identity for RTL integrity gates and host model references."""
import hashlib
import json
from pathlib import Path
import zlib

BASE = Path(__file__).resolve().parent
ROOT = BASE.parents[2]


def load_release():
    identity = json.loads((BASE/'data/model_identity.json').read_text(encoding='utf-8'))
    if identity['format'] != 'teacher-model-identity-v1': raise ValueError('Unknown model identity')
    package = ROOT/identity['package']
    blob = (package/'model_init.bin').read_bytes()
    if len(blob) != identity['model_bytes'] or hashlib.sha256(blob).hexdigest() != identity['model_sha256']:
        raise ValueError('Model binary differs from generated identity')
    if f'{zlib.crc32(blob)&0xffffffff:08X}' != identity['crc32'].upper(): raise ValueError('Model CRC mismatch')
    if hashlib.sha256((ROOT/identity['float_run']/'model_state.pth').read_bytes()).hexdigest() != identity['float_sha256']:
        raise ValueError('Floating source differs from generated identity')
    return identity
