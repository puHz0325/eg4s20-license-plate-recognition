"""Verify the exact diagnostic build sources against command-level SDRAM."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import os

from build_board import sources,ROOT,BASE


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--unit-only',action='store_true')
    parser.add_argument('--skew',type=int,default=None,help='One skew profile; default verifies -4/0/+4 ns')
    args=parser.parse_args()
    out=ROOT/'tmp/modelsim_teacher_board';out.mkdir(parents=True,exist_ok=True)
    output=BASE/'board/simulation_report.json'
    output.write_text('{"status":"IN_PROGRESS"}\n')
    lib=(out/'work').as_posix()
    def run(exe,arguments,name):
        log=out/(name+'.log')
        with log.open('w',encoding='utf-8') as stream:
            r=subprocess.run([f'E:/modelsim/win64/{exe}.exe',*arguments],cwd=ROOT,
                stdout=stream,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
        text=log.read_text(encoding='utf-8',errors='replace')
        if r.returncode or '** Error' in text or '** Fatal' in text:raise RuntimeError(str(log)+'\n'+text[-5000:])
        return text
    models=Path('E:/Anlogic/TD_5.6.5_SP3_151.449/sim_release')
    vendor=sorted(p for p in (models/'common').glob('*.v') if p.name!='al_phy_glbl.v')+sorted((models/'eg').glob('*.v'))
    benches=sorted((BASE/'board').glob('*_tb.sv'))+[ROOT/'car_test/PL/sim/video_sdram_model.sv',ROOT/'car_test/PL/sim/video_sdram_tb.sv']
    inputs=sources()+benches+[BASE/'data/teacher_config.vh',BASE/'data/teacher_model_identity.vh',
        BASE/'data/model_identity.json',BASE/'board/expected.vh']+sorted((BASE/'data').glob('*.hex'))
    manifest={x.relative_to(ROOT).as_posix():sha(x) for x in inputs}
    if not Path(lib).exists():run('vlib',[lib],'vlib')
    run('vlog',['-work',lib,*map(str,vendor)],'models')
    run('vlog',['-sv','-work',lib,'+incdir+'+str(BASE/'data'),'+incdir+'+str(BASE/'board'),*map(str,sources()+benches)],'compile')
    verified={}
    profiles=[args.skew] if args.skew is not None else [-4,0,4]
    tests=[('teacher_clocks_tb',0),('teacher_adapter_tb',0),('video_sdram_tb',0)]
    if not args.unit_only:tests += [('teacher_service_tb',skew) for skew in profiles]
    for name,skew in tests:
        log_name=name+('_skew_'+str(skew).replace('-','m') if name=='teacher_service_tb' else '')
        log=run('vsim',['-c','-onfinish','exit','-lib',lib,'-wlf',str(out/(log_name+'.wlf')),name,'glbl',*(['+SKEW_NS='+str(skew)] if name=='teacher_service_tb' else []),
            '-do','do {'+(BASE/'sim/run_batch.do').as_posix()+'}'],log_name)
        passes=[x for x in log.splitlines() if x.startswith('# PASS ')];
        if not passes:raise RuntimeError('Missing PASS '+name)
        verified[log_name]=passes
        for line in passes:print(line,flush=True)
        if name=='teacher_service_tb':
            from verify_hardware import decode_packet
            packet=(out/'response.bin').read_bytes();response=decode_packet(packet)
            reference=json.loads((BASE/'board/expected.json').read_text(encoding='utf-8'))[0]
            if response['flags']!=0x63 or response['clock_hz']!=25000000 or response['layer_crc32']!=reference['layer_crc32']:
                raise ValueError('Host parser rejected RTL response')
            corrupt=bytearray(packet);corrupt[59]^=1
            try:decode_packet(bytes(corrupt))
            except ValueError:pass
            else:raise ValueError('Host parser accepted corrupted packet')
            (out/f'response_skew_{skew}.bin').write_bytes(packet)
            print(f'PASS host parser and complete physical inference at skew {skew}ns',flush=True)
    if any(sha(ROOT/k)!=v for k,v in manifest.items()):raise RuntimeError('Sources changed during simulation; rerun')
    result=dict(status='UNIT_PASS' if args.unit_only else 'PASS',inputs=manifest,tests=verified,skew_ns=profiles,
                scope='25MHz native PLL plus command-level SDRAM, RMW, upload/model CRC and 8-layer CRC/CTC')
    output.write_text(json.dumps(result,indent=2)+'\n')
    print('PASS teacher board simulation:',output)


if __name__=='__main__':main()
