"""Check complete ModelSim coverage and preserve a reproducible simulation report."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[4]
TEACHER = ROOT / 'car_test/PL/teacher'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def input_hashes():
    files = list((TEACHER / 'rtl').glob('*.v'))
    files += list((TEACHER / 'sim').glob('*.sv'))
    files += list((TEACHER / 'sim').glob('*.do'))
    files += list((TEACHER / 'data').glob('*'))
    files += [ROOT / 'car_test/PL/src/cnn/requantize.v']
    return {str(p.relative_to(ROOT)).replace('\\', '/'):digest(p) for p in sorted(files) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--logs', type=Path, default=ROOT / 'tmp/modelsim_teacher')
    parser.add_argument('--snapshot', action='store_true')
    args = parser.parse_args()
    manifest = json.loads((TEACHER / 'data/manifest.json').read_text(encoding='utf-8'))
    for name, sha in manifest['files'].items():
        if digest(TEACHER / 'data' / name) != sha:
            raise ValueError(f'Generated vector changed: {name}')
    snapshot = args.logs / 'inputs.json'
    if args.snapshot:
        snapshot.write_text(json.dumps(input_hashes(), indent=2)+'\n', encoding='utf-8')
        (args.logs / 'report.json').write_text(json.dumps(dict(status='IN_PROGRESS',
            scope='Full-suite report is valid only after verify_results.py completes'))+'\n', encoding='utf-8')
        print('PASS teacher simulation input snapshot')
        return
    if json.loads(snapshot.read_text(encoding='utf-8')) != input_hashes():
        raise ValueError('RTL, benches or vectors changed during simulation; rerun')
    logs = ['arithmetic', 'ctc', 'dma', 'inference_0', 'inference_1', 'inference_2']
    texts = {}
    for name in logs:
        text = (args.logs / (name+'.log')).read_text(encoding='utf-8', errors='replace')
        if '** Fatal' in text or '** Error' in text or '# PASS teacher_' not in text or 'Errors: 0' not in text:
            raise ValueError(f'Failed or incomplete simulation: {name}')
        texts[name] = text
    runs = []
    pattern = (r'PASS teacher_inference case=(\d+) layers=(\d+) elements=(\d+) chars=(\d+) '
               r'cycles=(\d+) prefetch_wait=(\d+) overlap=(\d+) both_full=(\d+) reads=(\d+) writes=(\d+)')
    keys = ['case', 'layers', 'elements', 'chars', 'cycles', 'prefetch_wait', 'overlap', 'both_full', 'reads', 'writes']
    for index in range(3):
        text = texts[f'inference_{index}']
        match = re.search(pattern, text)
        if match is None:
            raise ValueError(f'Missing full inference summary: {index}')
        run = dict(zip(keys, map(int, match.groups()), strict=True))
        if run['case'] != index or run['layers'] != 8 or run['elements'] != 118912:
            raise ValueError('Incomplete layer/element coverage')
        case = manifest['cases'][index]
        if run['chars'] != case['character_count'] or run['overlap'] == 0:
            raise ValueError('Missing character or prefetch coverage')
        checked_layers = list(map(int, re.findall(r'CHECK layer=(\d+)', text)))
        if checked_layers != list(range(8)) * (2 if index == 2 else 1):
            raise ValueError('Per-layer scoreboards did not complete in order')
        run.update(prediction=case['prediction'], expected_label=case['label'],
                   simulated_ms_at_50MHz=run['cycles']/50000., extra_response_latency=17 if index == 2 else 0)
        runs.append(run)
    restart = re.search(r'PASS teacher_restart case=(\d+) layers=(\d+) elements=(\d+) chars=(\d+) cycles=(\d+) prefetch_wait=(\d+)', texts['inference_2'])
    if restart is None or tuple(map(int, restart.groups()[:4])) != (0, 8, 118912, manifest['cases'][0]['character_count']):
        raise ValueError('Missing restart with a different input and no reset')
    report = dict(status='PASS', simulator='ModelSim SE-64 2020.4', synthesis_run=False, hardware_download=False,
                  model_sha256=manifest['model_sha256'], runs=runs,
                  restart=dict(case=0, layers=8, elements=118912, cycles=int(restart.group(5)),
                               prefetch_wait=int(restart.group(6))),
                  total_compared_elements=4*118912,
                  coverage=['INT32 overflow', 'rounding/saturation', 'CTC backpressure/blanks/repeats/32 symbols',
                            'all masked-store offsets and counts', 'read-cache hit and invalidate',
                            'concurrent read/store arbitration', 'MAC plus outstanding memory reset',
                            'model_ready and busy start', 'prefetch ownership', 'extra memory latency',
                            'all eight layers', 'restart with different ROI and output length'],
                  scope='Independent single-clock CNN transaction interface only; excludes SDRAM PHY, video arbitration and CDC.',
                  inputs_sha256=digest(snapshot), inputs=json.loads(snapshot.read_text(encoding='utf-8')),
                  logs_sha256={k:digest(args.logs/(k+'.log')) for k in logs})
    (args.logs / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    (TEACHER / 'simulation_report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    print('PASS teacher report: 4 inferences, 475648 layer elements, no synthesis/download')


if __name__ == '__main__':
    main()
