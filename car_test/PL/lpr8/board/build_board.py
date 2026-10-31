"""Isolated teacher diagnostic implementation; no hardware access by default."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[4]
BASE=ROOT/'car_test/PL/lpr8'
TD=Path('E:/Anlogic/TD_5.6.5_SP3_151.449/bin/td_commands_prompt.exe')


def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def sources():
    return sorted((BASE/'rtl').glob('*.v'))+sorted((BASE/'board').glob('*.v'))+[
        ROOT/'car_test/PL/src/cnn/requantize.v',ROOT/'car_test/PL/src/comm/uart_rx.v',
        ROOT/'car_test/PL/src/comm/uart_tx.v',ROOT/'car_test/PL/src/video/video_reset.v',
        ROOT/'car_test/PL/src/video/video_clocks.v',ROOT/'car_test/PL/src/video/sdram_burst.v']


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--stage',choices=['map','pnr','bit'],default='map',help='Download uses download_gui.py; console return is not programming proof')
    p.add_argument('--output',type=Path,default=BASE/'td/board_20261028_memdiag')
    p.add_argument('--bit-name',default='lpr8_board_memdiag.bit')
    p.add_argument('--seed',type=int,default=0)
    a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
    if not re.fullmatch(r'[A-Za-z0-9_.-]+\.bit',a.bit_name):raise ValueError('Unsafe bit filename')
    config=BASE/'data/lpr8_config.vh'
    identity=BASE/'data/lpr8_model_identity.vh'
    manifest={x.relative_to(ROOT).as_posix():sha(x) for x in sources()+[config,identity,BASE/'data/model_identity.json']}
    if a.stage=='map':
        if (out/'lpr8_native.al').exists():raise FileExistsError('Preserve previous build; choose a fresh --output')
        text='\n'.join('// '+x.relative_to(ROOT).as_posix()+'\n'+x.read_text(encoding='utf-8').replace(
            '`include "lpr8_config.vh"',config.read_text(encoding='utf-8')).replace(
            '`include "lpr8_model_identity.vh"',identity.read_text(encoding='utf-8')) for x in sources())
        (out/'lpr8.v').write_text(text,encoding='utf-8')
        (out/'inputs.json').write_text(json.dumps(manifest,indent=2)+'\n',encoding='utf-8')
        pins={'clk_50m':'R7','rst_n':'E3','uart_rxd':'F12','uart_txd':'D12',
              'status_led[0]':'B14','status_led[1]':'B15','status_led[2]':'B16','status_led[3]':'C15'}
        (out/'teacher.adc').write_text('\n'.join('set_pin_assignment {'+name+'} { LOCATION = '+pin+
            '; IOSTANDARD = LVCMOS33;'+(' PULLTYPE = PULLUP;' if name in ['rst_n','uart_rxd'] else '')+' }'
            for name,pin in pins.items())+'\n')
        (out/'teacher.sdc').write_text('create_clock -name board_clk -period 20.000 [get_ports clk_50m]\n'
            'derive_pll_clocks\nset_false_path -from [get_ports rst_n]\n'
            'set_false_path -from [get_ports uart_rxd] -through [get_nets {receiver/rx_meta*}]\n')
        body='''create_project -family EG4 -device EG4S20BG256 lpr8_native [pwd]
add_files -analyze lpr8.v
add_files teacher.sdc
add_files teacher.adc
import_device eagle_s20.db -package EG4S20BG256
elaborate -top teacher_board_top
optimize_rtl
report_area -file rtl.area
read_sdc teacher.sdc
read_adc teacher.adc
optimize_gate -maparea gate.area
legalize_phy_inst
report_area -file mapped.area
write_verilog mapped.v
export_db mapped.db
'''
    else:
        if json.loads((out/'inputs.json').read_text())!=manifest: raise ValueError('Source changed; map again')
        body='open_project lpr8_native.al\nimport_device eagle_s20.db -package EG4S20BG256\n'
        if a.stage=='pnr':
            body+=f'''import_db mapped.db
set_param flow seed {a.seed}
set_param place effort high
set_param place opt_timing high
set_param place fix_hold on
set_param route effort high
set_param route fix_hold on
place
route
report_area -file routed.area
report_timing -file routed.timing
export_db routed.db
'''
        else:
            timing=(out/'routed.timing').read_text()
            counts=[int(x) for x in re.findall(r'(\d+) errors detected\s*:',timing)]
            if not counts or sum(counts): raise ValueError('Require routed zero setup/hold errors')
            verified=json.loads((BASE/'board/simulation_report.json').read_text())
            if verified['status']!='PASS' or any(sha(ROOT/k)!=v for k,v in verified['inputs'].items()):
                raise ValueError('Board simulation missing or source changed')
            body+='import_db routed.db\nbitgen -bit '+a.bit_name+' -version 00\n'
    script='if {[catch {\n'+body+'\nputs "TEACHER_'+a.stage.upper()+'_PASS"\n} message]} {\nputs stderr "TEACHER_FAIL: $message"\nexit 1\n}\nexit 0\n'
    (out/(a.stage+'.tcl')).write_text(script)
    with (out/(a.stage+'.log')).open('w') as stream:
        process=subprocess.run([str(TD),a.stage+'.tcl'],cwd=out,
            env={**os.environ,'QT_QPA_PLATFORM':'offscreen'},stdin=subprocess.DEVNULL,
            stdout=stream,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
    log=(out/(a.stage+'.log')).read_text(errors='replace')
    if process.returncode or 'TEACHER_'+a.stage.upper()+'_PASS' not in log or 'TEACHER_FAIL' in log or re.search(r'\bERROR\s*:',log):
        raise RuntimeError(log[-7000:])
    if a.stage in ['map','pnr']:
        area=(out/('mapped.area' if a.stage=='map' else 'routed.area')).read_text()
        resources={}
        for name in ['lut','reg','dsp','bram','bram32k','pll']:
            m=re.search(r'^#'+name+r'\s+(\d+)\s+out of\s+(\d+)',area,re.M)
            if not m or int(m[1])>int(m[2]):raise RuntimeError('Missing/exceeded resource '+name+'\n'+area)
            resources[name]={'used':int(m[1]),'available':int(m[2])}
        if not re.search(r'^\s*#LATCH\s+0\b',(out/'rtl.area').read_text(),re.M):raise ValueError('Inferred latch')
        summary=dict(stage=a.stage,resources=resources,critical_warnings=[x for x in log.splitlines() if 'CRITICAL-WARNING' in x])
        if a.stage=='pnr':
            timing=(out/'routed.timing').read_text()
            counts=[int(x) for x in re.findall(r'(\d+) errors detected\s*:',timing)]
            if not counts:raise ValueError('No timing constraints analyzed')
            summary['timing_errors']=sum(counts)
        (out/(a.stage+'_summary.json')).write_text(json.dumps(summary,indent=2)+'\n')
        print(json.dumps(summary,indent=2))
        if summary.get('timing_errors',0):raise ValueError('Routed timing failed')
    if a.stage=='bit':
        (out/'bitstream.json').write_text(json.dumps(dict(bit=a.bit_name,sha256=sha(out/a.bit_name),
            inputs_sha256=sha(out/'inputs.json'),routed_db_sha256=sha(out/'routed.db'),programmed=False),indent=2)+'\n')
    print('PASS teacher',a.stage,'logs:',out)


if __name__=='__main__':main()
