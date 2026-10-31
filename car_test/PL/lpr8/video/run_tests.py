"""Compile exact integrated RTL, run independent pixel/CDC/system scoreboards."""
import argparse
import json
import os
from pathlib import Path
import subprocess
from build_video import ROOT,BASE,PL,sources,data_files,sha


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tests',nargs='+',default=['teacher_live_clocks_tb','teacher_roi_tb','teacher_resize_equiv_tb','teacher_cdc_tb',
        'teacher_live_memory_tb','teacher_live_bridge_tb','teacher_vote_slow_tb','lpr_vote_tb','lpr_health_tb',
        'lpr_osd_tb','lpr_vote_osd_tb','teacher_live_system_tb'])
    args=parser.parse_args()
    out=ROOT/'tmp/modelsim_teacher_video';out.mkdir(parents=True,exist_ok=True)
    (BASE/'video/simulation_report.json').write_text('{"status":"IN_PROGRESS"}\n')
    lib=(out/'work').as_posix()
    def run(exe,arguments,name):
        log=out/(name+'.log')
        with log.open('w',encoding='utf-8') as stream:
            result=subprocess.run([str(Path(os.environ.get('MODELSIM_BIN','E:/modelsim/win64'))/(exe+'.exe')),*arguments],cwd=ROOT,
                stdout=stream,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,creationflags=subprocess.CREATE_NO_WINDOW)
        text=log.read_text(encoding='utf-8',errors='replace')
        if result.returncode or '** Error' in text or '** Fatal' in text:raise RuntimeError(str(log)+'\n'+text[-5500:])
        return text
    vendor=Path(os.environ.get('ANLOGIC_TD_HOME','E:/Anlogic/TD_5.6.5_SP3_151.449'))/'sim_release'
    model_files=sorted(p for p in (vendor/'common').glob('*.v') if p.name!='al_phy_glbl.v')+sorted((vendor/'eg').glob('*.v'))
    benches=sorted((BASE/'video').glob('*_tb.sv'))+[PL/'sim'/(n+'.sv') for n in
        ['video_sdram_model','lpr_vote_tb','lpr_health_tb','lpr_osd_tb','lpr_vote_osd_tb']]
    inputs=sources()+data_files()+benches+sorted((BASE/'data').glob('*.hex'))
    manifest={x.relative_to(ROOT).as_posix():sha(x) for x in inputs}
    if not Path(lib).exists():run('vlib',[lib],'vlib')
    run('vlog',['-work',lib,*map(str,model_files)],'models_compile')
    includes=['+incdir+'+str(PL/'data'),'+incdir+'+str(BASE/'data'),'+incdir+'+str(BASE/'board')]
    legacy=[p for p in sources() if PL/'src' in p.parents]
    modern=[p for p in sources() if p not in legacy]
    run('vlog',['-work',lib,*includes,*map(str,legacy)],'legacy_compile')
    run('vlog',['-sv','-work',lib,*includes,*map(str,modern)],'rtl_compile')
    run('vlog',['-sv','-work',lib,*includes,*map(str,benches)],'bench_compile')
    results={}
    for test in args.tests:
        text=run('vsim',['-c','-onfinish','exit','-lib',lib,'-wlf',str(out/(test+'.wlf')),test,'glbl',
            '-do','do {'+(BASE/'sim/run_batch.do').as_posix()+'}'],test)
        passes=[x for x in text.splitlines() if x.startswith('# PASS ')]
        if not passes:raise ValueError('Missing PASS '+test)
        results[test]=passes
        for line in passes:print(line,flush=True)
        if test=='teacher_live_bridge_tb':
            text=run('vsim',['-c','-onfinish','exit','-lib',lib,'-wlf',str(out/'teacher_live_bridge_wrong_model.wlf'),
                test,'glbl','+WRONG_MODEL','-do','do {'+(BASE/'sim/run_batch.do').as_posix()+'}'],
                'teacher_live_bridge_wrong_model')
            passes=[x for x in text.splitlines() if x.startswith('# PASS ')]
            if not passes:raise ValueError('Missing wrong-model rejection PASS')
            results['teacher_live_bridge_wrong_model']=passes
            for line in passes:print(line,flush=True)
    if any(sha(ROOT/k)!=v for k,v in manifest.items()):raise ValueError('Sources changed during tests')
    required={'teacher_live_clocks_tb','teacher_roi_tb','teacher_resize_equiv_tb','teacher_cdc_tb','teacher_live_memory_tb','teacher_live_bridge_tb','teacher_live_system_tb','teacher_vote_slow_tb'}
    record=dict(status='PASS' if required<=results.keys() else 'PARTIAL_PASS',inputs=manifest,tests=results)
    (BASE/'video/simulation_report.json').write_text(json.dumps(record,indent=2)+'\n')
    print('PASS teacher video checks:',record['status'])


if __name__=='__main__':main()
