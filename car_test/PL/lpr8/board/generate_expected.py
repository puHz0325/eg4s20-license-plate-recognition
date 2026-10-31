import json
from pathlib import Path
import zlib

BASE=Path(__file__).resolve().parents[1]
manifest=json.loads((BASE/'data/manifest.json').read_text(encoding='utf-8'))
lines=['// CRCs of complete HWC integer-reference layer bytes, not predictions.']
results=[]
for case in range(3):
    crcs=[]
    for layer in range(8):
        values=[int(v,16) for v in (BASE/f'data/layer_{case}_{layer}.hex').read_text().split()]
        blob=b''.join(v.to_bytes(2 if layer==7 else 1,'little') for v in values)
        crc=zlib.crc32(blob)&0xffffffff;crcs.append(crc)
        lines.append(f"`define BOARD_CRC_{case}_{layer} 32'h{crc:08x}")
    results.append(dict(case=case,prediction=manifest['cases'][case]['prediction'],layer_crc32=crcs))
(BASE/'board/expected.vh').write_text('\n'.join(lines)+'\n')
(BASE/'board/expected.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('PASS board reference CRCs generated')
