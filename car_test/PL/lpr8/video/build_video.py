"""Build the integrated teacher camera/HDMI target in a fresh directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[4]
BASE=ROOT/'car_test/PL/lpr8'
PL=ROOT/'car_test/PL'
TD=Path(os.environ.get('ANLOGIC_TD_BIN','E:/Anlogic/TD_5.6.5_SP3_151.449/bin/td_commands_prompt.exe'))


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def sources():
    shared=['dvp_capture','video_async_fifo','video_frame_store','video_timing','video_display',
            'video_reset','video_clocks','tmds_encoder','tmds_serializer','ov5640_config','sccb_master',
            'lpr_vote','lpr_health','lpr_osd']
    return sorted((BASE/'rtl').glob('*.v'))+[
        BASE/'board/lpr8_board_service.v',BASE/'board/lpr8_sdram_adapter.v',BASE/'board/lpr8_sdram_controller.v'
    ]+sorted((BASE/'video').glob('*.v'))+[PL/f'src/video/{x}.v' for x in shared]+[
        PL/'src/cnn/requantize.v',PL/'src/comm/uart_rx.v',PL/'src/comm/uart_tx.v']


def data_files():
    return [BASE/'data/lpr8_config.vh',BASE/'data/lpr8_model_identity.vh',BASE/'data/model_identity.json',
        BASE/'data/lpr8_preprocess.vh',BASE/'video/preprocess.json',
        ROOT/'car_test/lpr8_preprocess.py']+[PL/'data'/name for name in ['ov5640_table.vh','osd_glyphs.vh',
        'ov5640_vga_rgb888.hex',*[f'osd_font{i}.hex' for i in range(4)]]]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--stage',choices=['map','pnr','bit'],default='map')
    p.add_argument('--output',type=Path,default=BASE/'td/video_20261029_align_v3')
    p.add_argument('--seed',type=int,default=0)
    p.add_argument('--resume-placement',action='store_true',help='Route a saved failed_place.db; final timing checks remain mandatory')
    a=p.parse_args();out=a.output.resolve();out.mkdir(parents=True,exist_ok=True)
    import sys
    sys.path.insert(0,str(ROOT/'car_test'))
    from lpr8_preprocess import header_text
    if (BASE/'data/lpr8_preprocess.vh').read_text()!=header_text():raise ValueError('Regenerate preprocessing header')
    manifest={x.relative_to(ROOT).as_posix():sha(x) for x in sources()+data_files()}
    if a.stage=='map':
        if (out/'lpr8_video.al').exists():raise FileExistsError('Preserve previous build; select a fresh --output')
        texts=[]
        for path in sources():
            text=path.read_text(encoding='utf-8')
            for config in data_files():
                if config.suffix=='.vh':text=text.replace('`include "'+config.name+'"',config.read_text(encoding='utf-8'))
                if config.suffix=='.hex':text=text.replace('car_test/PL/data/'+config.name,config.as_posix())
            texts.append('// '+path.relative_to(ROOT).as_posix()+'\n'+text)
        (out/'video.v').write_text('\n'.join(texts),encoding='utf-8')
        (out/'inputs.json').write_text(json.dumps(manifest,indent=2)+'\n')
        pins={'clk_50m':'R7','rst_n':'E3','uart_rxd':'F12','uart_txd':'D12',
              'cam_pclk':'L1','cam_vsync':'M5','cam_href':'D1','cam_xclk':'L5','cam_rst_n':'K1',
              'cam_pwdn':'K2','cam_scl':'M2','cam_sda':'M3','hdmi_clk_p':'P1','hdmi_d0_p':'N1',
              'hdmi_d1_p':'P4','hdmi_d2_p':'J3','status_led[0]':'B14','status_led[1]':'B15',
              'status_led[2]':'B16','status_led[3]':'C15'}
        for i,pin in enumerate(['H1','J1','G1','H2','F2','F1','E2','E1']):pins[f'cam_data[{i}]']=pin
        adc=[]
        for name,pin in pins.items():
            standard='LVDS33' if name.startswith('hdmi_') else 'LVCMOS33'
            pull=' PULLTYPE = PULLUP;' if name in ['rst_n','uart_rxd','cam_scl','cam_sda'] else ''
            adc.append(f'set_pin_assignment {{{name}}} {{ LOCATION = {pin}; IOSTANDARD = {standard};{pull} }}')
        (out/'video.adc').write_text('\n'.join(adc)+'\n')
        (out/'video.sdc').write_text('''create_clock -name board_clk -period 20.000 [get_ports clk_50m]
create_clock -name camera_pclk -period 41.667 [get_ports cam_pclk]
derive_pll_clocks
set_clock_groups -asynchronous -group [get_clocks {board_clk clocks/memory_pll/pll.*}] -group [get_clocks {clocks/display_pll/pll.*}] -group [get_clocks camera_pclk]
set_input_delay -max 5.000 -clock camera_pclk -clock_fall [get_ports {cam_data[*] cam_href cam_vsync}]
set_input_delay -min 0.500 -clock camera_pclk -clock_fall [get_ports {cam_data[*] cam_href cam_vsync}]
set_false_path -from [get_ports rst_n]
set_false_path -from [get_ports uart_rxd] -through [get_nets {receiver/rx_meta*}]
''')
        body='''create_project -family EG4 -device EG4S20BG256 lpr8_video [pwd]
add_files -analyze video.v
add_files video.sdc
add_files video.adc
import_device eagle_s20.db -package EG4S20BG256
elaborate -top teacher_video_top
optimize_rtl
report_area -file rtl.area
read_sdc video.sdc
read_adc video.adc
optimize_gate -maparea gate.area
legalize_phy_inst
report_area -file mapped.area
write_verilog mapped.v
export_db mapped.db
'''
    else:
        if json.loads((out/'inputs.json').read_text())!=manifest:raise ValueError('Source changed; map in a new output')
        body='open_project lpr8_video.al\nimport_device eagle_s20.db -package EG4S20BG256\n'
        if a.stage=='pnr':
            body+=f'''import_db mapped.db
set_param flow mixed_pack_place_flow on
set_param flow seed {a.seed}
set_param place effort high
set_param place opt_timing high
set_param place fix_hold on
set_param place post_clock_route_opt on
set_param route effort high
set_param route fix_hold on
create_bound camera_cluster -mode fixed -width 12 -height 16 -origin {{4 16}} -excluded {{bram dsp}}
add_cells_to_bound -bound camera_cluster -cells {{system/frontend/capture system/frontend/capture_fifo rc}}
if {{[catch {{place}} placement_message]}} {{
report_timing -file failed_place.timing
export_db failed_place.db
error "placement failed: $placement_message"
}}
route
report_area -file routed.area
report_timing -file routed.timing
export_db routed.db
'''
            if a.resume_placement:
                if not (out/'failed_place.db').exists():raise FileNotFoundError('No saved placement')
                body='''open_project lpr8_video.al
import_device eagle_s20.db -package EG4S20BG256
import_db failed_place.db
set_param route effort high
set_param route opt_timing high
set_param route fix_hold on
route
report_area -file routed.area
report_timing -file routed.timing
export_db routed.db
'''
        else:
            timing=(out/'routed.timing').read_text()
            counts=[int(x) for x in re.findall(r'(\d+) errors detected\s*:',timing)]
            if not counts or sum(counts):raise ValueError('Require zero routed setup/hold errors')
            verified=json.loads((BASE/'video/simulation_report.json').read_text())
            if verified['status']!='PASS' or any(sha(ROOT/k)!=v for k,v in verified['inputs'].items()):raise ValueError('Missing current video simulation')
            body+='import_db routed.db\nbitgen -bit lpr8_video_p1.bit -version 00\n'
    script='if {[catch {\n'+body+'\nputs "TEACHER_VIDEO_'+a.stage.upper()+'_PASS"\n} message]} {puts stderr "VIDEO_FAIL: $message";puts stderr $::errorInfo;exit 1}\nexit 0\n'
    (out/(a.stage+'.tcl')).write_text(script)
    with (out/(a.stage+'.log')).open('w') as stream:
        process=subprocess.run([str(TD),a.stage+'.tcl'],cwd=out,env={**os.environ,'QT_QPA_PLATFORM':'offscreen'},
            stdin=subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT,creationflags=subprocess.CREATE_NO_WINDOW)
    log=(out/(a.stage+'.log')).read_text(errors='replace')
    if process.returncode or 'TEACHER_VIDEO_'+a.stage.upper()+'_PASS' not in log or 'VIDEO_FAIL:' in log or re.search(r'\bERROR\s*:',log):raise RuntimeError(log[-8000:])
    if a.stage in ['map','pnr']:
        area=(out/('mapped.area' if a.stage=='map' else 'routed.area')).read_text();resources={}
        for name in ['lut','reg','dsp','bram','bram32k','pll']:
            match=re.search(r'^#'+name+r'\s+(\d+)\s+out of\s+(\d+)',area,re.M)
            if not match or int(match[1])>int(match[2]):raise ValueError('Missing/exceeded resource '+name+'\n'+area)
            resources[name]={'used':int(match[1]),'available':int(match[2])}
        if not re.search(r'^\s*#LATCH\s+0\b',(out/'rtl.area').read_text(),re.M):raise ValueError('Inferred latch')
        summary=dict(stage=a.stage,resources=resources,critical_warnings=[x for x in log.splitlines() if 'CRITICAL-WARNING' in x])
        if a.stage=='pnr':
            counts=[int(x) for x in re.findall(r'(\d+) errors detected\s*:',(out/'routed.timing').read_text())]
            if not counts:raise ValueError('No timing analysis')
            summary['timing_errors']=sum(counts)
        (out/(a.stage+'_summary.json')).write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
        if summary.get('timing_errors',0):raise ValueError('Routed timing failed')
    if a.stage=='bit':(out/'bitstream.json').write_text(json.dumps(dict(bit='lpr8_video_p1.bit',sha256=sha(out/'lpr8_video_p1.bit'),
        routed_db_sha256=sha(out/'routed.db'),inputs_sha256=sha(out/'inputs.json'),
        sdc_sha256=sha(out/'video.sdc'),adc_sha256=sha(out/'video.adc'),build_script_sha256=sha(Path(__file__)),
        simulation_report_sha256=sha(BASE/'video/simulation_report.json'),programmed=False,hardware_validated=False),indent=2)+'\n')
    print('PASS teacher video',a.stage,out)


if __name__=='__main__':main()
