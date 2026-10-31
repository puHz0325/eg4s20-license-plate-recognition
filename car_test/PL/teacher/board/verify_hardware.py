"""Upload exact teacher data and verify FPGA model/layer CRCs and CTC over UART."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import time
import zlib

import serial

BASE=Path(__file__).resolve().parents[1]
ROOT=BASE.parents[2]
sys.path.insert(0,str(BASE))
from model_release import load_release
RELEASE=load_release()
sys.path.insert(0,str(ROOT/'car_test'))
from lpr_common import CHARS


def hex_bytes(path,width=1):
    return b''.join(int(x,16).to_bytes(width,'little') for x in path.read_text().split())


def decode_packet(packet):
    if len(packet)!=128 or packet[:4]!=b'TCH1':raise ValueError('Invalid teacher response header/length')
    if zlib.crc32(packet[:124])&0xffffffff!=int.from_bytes(packet[124:],'little'):
        raise ValueError('Response CRC32 mismatch')
    count=packet[6]
    if count>32 or packet[7]!=1 or packet[5]>>6>1:raise ValueError('Unsupported count/version/clock')
    return dict(command=chr(packet[4]),flags=packet[5],length=count,clock_hz=25000000 if packet[5]>>6==1 else 50000000,
                model_crc32=int.from_bytes(packet[8:12],'little'),upload_crc32=int.from_bytes(packet[12:16],'little'),
                cycles=int.from_bytes(packet[16:20],'little'),prefetch_wait=int.from_bytes(packet[20:24],'little'),
                character_indices=list(packet[24:24+count]),layer_crc32=list(struct.unpack('<8I',packet[56:88])),
                layer_cycles=list(struct.unpack('<8I',packet[88:120])),build_id=f'{int.from_bytes(packet[120:124],"little"):08x}',
                read_delay=packet[24] if packet[4]==ord('T') else None,raw_burst_hex=packet[56:72].hex() if packet[4]==ord('R') else None,
                raw_hex=packet.hex())


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port',default='COM8')
    p.add_argument('--output',type=Path,default=ROOT/'tmp/teacher_hardware_20261028.json')
    p.add_argument('--only-ping',action='store_true')
    p.add_argument('--repeats',type=int,default=3)
    p.add_argument('--bit',type=Path)
    a=p.parse_args()
    if a.repeats<1:raise ValueError('Positive repeat count required')
    if a.output.exists():raise FileExistsError('Preserve previous hardware evidence; select a fresh --output')
    binary=(BASE/'data/model.hex');model=hex_bytes(binary)
    if hashlib.sha256(model).hexdigest()!=RELEASE['model_sha256']:
        raise ValueError('Frozen teacher model changed')
    expected=json.loads((BASE/'board/expected.json').read_text(encoding='utf-8'))
    report=dict(status='IN_PROGRESS',port=a.port,baud=115200,model_sha256=hashlib.sha256(model).hexdigest(),
                transactions=[],inferences=[],scope='UART-supplied frozen inputs, real FPGA inference and SDRAM CRCs; no camera/HDMI')
    if a.bit is not None:report.update(bit=str(a.bit.resolve()),bit_sha256=hashlib.sha256(a.bit.read_bytes()).hexdigest())
    def save():a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    save()
    begin=time.monotonic()
    try:
        with serial.Serial(a.port,115200,timeout=.2,write_timeout=10) as port:
            port.reset_input_buffer()
            def request(data,timeout=20.,allow_error=False):
                n=port.write(data)
                if n!=len(data):raise IOError('Incomplete serial write')
                port.flush();payload=bytearray();deadline=time.monotonic()+timeout
                while len(payload)<128 and time.monotonic()<deadline:payload.extend(port.read(128-len(payload)))
                response=decode_packet(bytes(payload));report['transactions'].append(response)
                if response['command']!=chr(data[0]):raise ValueError('Command/response mismatch')
                if response['build_id']!=RELEASE['build_id']:raise ValueError('Wrong firmware build ID')
                if response['flags']&0x1c and not allow_error:raise ValueError('Board error flags: '+hex(response['flags']))
                return response
            ping=request(b'P')
            if not ping['flags']&1:raise ValueError('SDRAM is not initialized')
            print(json.dumps(ping,ensure_ascii=False),flush=True)
            if a.only_ping:
                report['status']='PING_ONLY_PASS';save();return
            def upload(address,data):
                if len(data)%16:raise ValueError('Aligned upload required')
                for offset in range(0,len(data),4096):
                    block=data[offset:offset+4096];crc=zlib.crc32(block)&0xffffffff
                    packet=b'W'+(address+offset).to_bytes(3,'little')+struct.pack('<H',len(block)//16)+block+struct.pack('<I',crc)
                    reply=request(packet)
                    if reply['upload_crc32']!=crc:raise ValueError('FPGA upload CRC mismatch')
                print(f'Uploaded {len(data)} bytes at {address:#x}',flush=True)
            upload(0x100000,model)
            report['read_calibration']=[]
            verified=None
            for delay in [3,2,4]:
                setting=request(b'T'+bytes([delay]))
                if setting['read_delay']!=delay:raise ValueError('Read-wait setting acknowledgement mismatch')
                probe=request(b'R'+(0x100000).to_bytes(3,'little'))
                attempt=request(b'V',allow_error=True)
                report['read_calibration'].append(dict(delay=delay,first_burst_hex=probe['raw_burst_hex'],
                    expected_first_burst_hex=model[:16].hex(),model_crc32=attempt['model_crc32'],flags=attempt['flags']))
                save();print(json.dumps(report['read_calibration'][-1]),flush=True)
                if attempt['model_crc32']==zlib.crc32(model)&0xffffffff and attempt['flags']&0x1f==3:
                    if probe['raw_burst_hex']!=model[:16].hex():raise ValueError('Model CRC passed but first burst did not')
                    verified=attempt;report['selected_read_delay']=delay;break
            if verified is None:raise ValueError('FPGA SDRAM model readback CRC failed for all read-wait settings')
            report['model_verification']=verified;save()
            for repeat in range(a.repeats):
                for case in range(3):
                    upload(0x140000,hex_bytes(BASE/f'data/input_{case}.hex'))
                    unchanged=request(b'V')
                    if unchanged['model_crc32']!=zlib.crc32(model)&0xffffffff or unchanged['flags']&3!=3:
                        raise ValueError('ROI upload altered model storage or readback stability')
                    result=request(b'I')
                    golden=list(hex_bytes(BASE/f'data/chars_{case}.hex'))
                    count=len(expected[case]['prediction'])
                    if result['character_indices']!=golden[:count]:raise ValueError(f'CTC mismatch repeat={repeat} case={case}')
                    if result['layer_crc32']!=expected[case]['layer_crc32']:raise ValueError(f'Layer CRC mismatch repeat={repeat} case={case}')
                    if result['flags']&0x3f!=0x23:raise ValueError('Inference did not complete normally')
                    if result['cycles']<=0 or result['layer_cycles']!=sorted(result['layer_cycles']):raise ValueError('Invalid cycle report')
                    result.update(case=case,repeat=repeat,prediction=''.join(CHARS[i] for i in result['character_indices']),
                                  milliseconds=result['cycles']/(result['clock_hz']/1000.))
                    report['inferences'].append(result);save()
                    print(json.dumps({k:result[k] for k in ['case','repeat','prediction','cycles','milliseconds','layer_crc32']},ensure_ascii=False),flush=True)
            report['status']='PASS';report['elapsed_seconds']=time.monotonic()-begin;save()
    except Exception as exc:
        report.update(status='FAIL',error=repr(exc),elapsed_seconds=time.monotonic()-begin);save();raise
    print('PASS FPGA teacher inference:',a.output)


if __name__=='__main__':main()
