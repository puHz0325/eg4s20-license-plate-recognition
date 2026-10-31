"""Independent OpenCV oracle frames for the RTL camera resizer."""
import hashlib
import json
from pathlib import Path
import sys

import numpy as np

ROOT=Path(__file__).resolve().parents[4]
sys.path.insert(0,str(ROOT/'car_test'))
from lpr8_preprocess import camera_input,CONTRACT


def main():
    output=ROOT/'car_test/PL/lpr8/data'
    rng=np.random.default_rng(2026102901)
    frame=rng.integers(0,256,(480,640),dtype=np.uint8)
    # Deterministically exercise odd sums and extremes, not only smooth ramps.
    frame[177:304:4,128:512:6]=0;frame[178:304:4,128:512:6]=255
    expected=camera_input(frame)
    hashes={}
    for name,array in [('preprocess_frame.hex',frame),('preprocess_expected.hex',expected)]:
        p=output/name;p.write_text(''.join(f'{int(x):02x}\n' for x in array.flat),encoding='ascii')
        hashes[name]=hashlib.sha256(p.read_bytes()).hexdigest()
    (output/'preprocess_vectors.json').write_text(json.dumps(dict(seed=2026102901,contract=CONTRACT,sha256=hashes),indent=2)+'\n')
    print('PASS independent OpenCV frame and 4096-pixel resize oracle exported')


if __name__=='__main__':main()
