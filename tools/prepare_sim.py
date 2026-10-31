"""Restore the frozen synthetic OSD pixel oracle, without requiring system fonts."""
from pathlib import Path
import zipfile

ROOT=Path(__file__).resolve().parents[1]
destination=ROOT/'tmp/osd_validation';destination.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(ROOT/'testdata/osd_validation.zip') as archive:
    for name in archive.namelist():
        if Path(name).name!=name or not name.endswith('.hex'):raise ValueError('Unsafe oracle archive member')
        (destination/name).write_bytes(archive.read(name))
print('PASS frozen OSD oracle prepared: '+str(destination))
