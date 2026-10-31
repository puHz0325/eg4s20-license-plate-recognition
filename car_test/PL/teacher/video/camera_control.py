"""Load/start the teacher camera pipeline, or verify its actual ROI and all layers.

The FPGA crops and infers autonomously. The PC only loads weights after power-up
and optionally reads diagnostic copies for an independent comparison.
"""
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
sys.path.insert(0,str(BASE/'board'))
from verify_hardware import decode_packet,hex_bytes
from model_release import load_release
RELEASE=load_release()
MODEL_CRC=int(RELEASE['crc32'],16)
sys.path.insert(0,str(ROOT/'car_test'))
from lpr_common import CHARS


def reference_roi(roi):
    import numpy as np
    sys.path.insert(0,str(ROOT/'car_test/train'))
    from integer_reference import IntegerNetwork
    network=IntegerNetwork.load(ROOT/RELEASE['package'])
    features,traces=network.forward(np.frombuffer(roi,dtype=np.uint8).reshape(1,32,128),trace=True)
    indices=features[0,:,0,:].argmax(axis=0).tolist()
    decoded=[];previous=None
    for i in indices:
        if i!=previous and i!=67:decoded.append(i)
        previous=i
    crcs=[]
    for layer in range(1,9):
        array=traces[f'layer{layer}_output'].transpose(0,2,3,1)
        payload=array.astype('<i2').tobytes() if layer==8 else array.astype('uint8').tobytes()
        crcs.append(zlib.crc32(payload)&0xffffffff)
    return decoded,crcs


class CameraLink:
    def __init__(self,port,report):
        self.port=port;self.report=report;self.buffer=bytearray()

    def receive(self,timeout=20):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            index=self.buffer.find(b'TCH1')
            if index<0:
                self.buffer=self.buffer[-3:]
            else:
                del self.buffer[:index]
                if len(self.buffer)>=128:
                    raw=bytes(self.buffer[:128])
                    try:result=decode_packet(raw)
                    except ValueError:
                        self.report['invalid_packets']+=1;del self.buffer[0];continue
                    del self.buffer[:128]
                    self.report['transactions'].append(result)
                    if result['command']=='I':
                        result['prediction']=''.join(CHARS[i] if i<len(CHARS) else '?' for i in result['character_indices'])
                        result['milliseconds']=result['cycles']/(result['clock_hz']/1000)
                        self.report['camera_results'].append(result)
                    return result
            self.buffer.extend(self.port.read(max(1,self.port.in_waiting)))
        raise TimeoutError('No complete teacher packet received')

    def request(self,data,timeout=20,allow_error=False):
        if self.port.write(data)!=len(data):raise IOError('Incomplete serial write')
        self.port.flush();deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            reply=self.receive(max(.1,deadline-time.monotonic()))
            if reply['command']!=chr(data[0]):
                if reply['command']=='I':continue  # Finish an already active camera transaction before B.
                raise ValueError('Unexpected response '+reply['command'])
            if reply['build_id']!=RELEASE['build_id']:raise ValueError('Wrong firmware build')
            if reply['flags']&0x1c and not allow_error:raise ValueError('FPGA reported error '+hex(reply['flags']))
            return reply
        raise TimeoutError('Command acknowledgement timeout')

    def status(self):
        reply=self.request(b'S')
        flags,frames,underflows,inferences=struct.unpack('<4I',bytes.fromhex(reply['raw_hex'])[56:72])
        return dict(flags=flags,configured=bool(flags&1),camera_fault=bool(flags&2),
                    memory_ready=bool(flags&4),model_ready=bool(flags&8),camera_mode=bool(flags&16),
                    busy=bool(flags&32),bridge_fault=bool(flags&64),service_error=bool(flags&128),
                    fault_code=(flags>>8)&15,retries=(flags>>12)&3,
                    published_frames=frames,underflows=underflows,inferences=inferences)

    def upload_model(self):
        model=hex_bytes(BASE/'data/model.hex')
        if hashlib.sha256(model).hexdigest()!=RELEASE['model_sha256']:raise ValueError('Frozen model changed')
        for offset in range(0,len(model),4096):
            block=model[offset:offset+4096];crc=zlib.crc32(block)&0xffffffff
            reply=self.request(b'W'+(0x100000+offset).to_bytes(3,'little')+struct.pack('<H',len(block)//16)+block+struct.pack('<I',crc))
            if reply['upload_crc32']!=crc:raise ValueError('Model upload CRC mismatch')
        attempts=[]
        for delay in [3,2,4]:
            self.request(b'T'+bytes([delay]))
            reply=self.request(b'V',allow_error=True)
            attempts.append(dict(delay=delay,crc32=f"{reply['model_crc32']:08x}",flags=reply['flags']))
            if reply['model_crc32']==MODEL_CRC and reply['flags']&31==3:
                self.report.update(calibration=attempts,selected_read_delay=delay);return
        self.report['calibration']=attempts
        raise ValueError('No valid SDRAM read window')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port',default='COM8')
    p.add_argument('--action',choices=['verify','start','stop','status'],default='verify')
    p.add_argument('--load-model',action='store_true')
    p.add_argument('--seconds',type=float,default=20)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--bit',type=Path)
    a=p.parse_args()
    if a.output.exists():raise FileExistsError('Preserve evidence: choose a fresh output')
    report=dict(status='IN_PROGRESS',port=a.port,action=a.action,transactions=[],camera_results=[],invalid_packets=0)
    if a.bit:report.update(bit=str(a.bit.resolve()),bit_sha256=hashlib.sha256(a.bit.read_bytes()).hexdigest())
    def save():
        a.output.parent.mkdir(parents=True,exist_ok=True)
        a.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    save()
    try:
        with serial.Serial(a.port,115200,timeout=.1,write_timeout=10) as port:
            port.reset_input_buffer();link=CameraLink(port,report)
            if a.action!='status':link.request(b'B',timeout=30,allow_error=True)
            initial=link.status();report['initial_status']=initial;print(json.dumps(initial),flush=True)
            if a.action in ['stop','status']:
                report['status']='PASS';save();return
            if a.load_model or not initial['model_ready']:link.upload_model()
            if link.request(b'V')['model_crc32']!=MODEL_CRC:raise ValueError('Model CRC not valid')
            report['camera_results']=[]
            link.request(b'A');report['enabled']=True
            if a.action=='start':report['status']='STARTED';save();return
            deadline=time.monotonic()+a.seconds
            while time.monotonic()<deadline:
                result=link.receive(timeout=15)
                if result['command']!='I':raise ValueError('Expected autonomous camera I response')
                if result['flags']&63!=0x23 or result['model_crc32']!=MODEL_CRC:raise ValueError('Camera inference error')
                print(json.dumps({k:result[k] for k in ['prediction','length','milliseconds','upload_crc32']},ensure_ascii=False),flush=True);save()
            link.request(b'B',timeout=30)
            stopped=link.status();report['stopped_status']=stopped
            if len(report['camera_results'])<3 or not stopped['configured'] or stopped['camera_fault'] or stopped['bridge_fault'] or stopped['service_error']:
                raise ValueError('Camera pipeline is not healthy')
            if stopped['published_frames']<=initial['published_frames']:raise ValueError('No new physical camera frames')
            roi=bytearray()
            for offset in range(0,4096,16):
                reply=link.request(b'R'+(0x140000+offset).to_bytes(3,'little'))
                roi.extend(bytes.fromhex(reply['raw_burst_hex']))
            last=report['camera_results'][-1]
            crc=zlib.crc32(roi)&0xffffffff
            if crc!=last['upload_crc32']:raise ValueError('Readback is not the image used by the last inference')
            roi_path=a.output.with_suffix('.roi.bin');roi_path.write_bytes(roi)
            decoded,crcs=reference_roi(roi)
            if decoded!=last['character_indices'] or crcs!=last['layer_crc32']:raise ValueError('FPGA differs from independent integer reference on actual camera ROI')
            if link.request(b'V')['model_crc32']!=MODEL_CRC:raise ValueError('Model changed during camera run')
            report.update(roi_file=str(roi_path.resolve()),roi_crc32=f'{crc:08x}',roi_sha256=hashlib.sha256(roi).hexdigest(),
                          reference_prediction=''.join(CHARS[i] for i in decoded),reference_layer_crc32=crcs,
                          exact_camera_roi_match=True,underflow_increase=stopped['underflows']-initial['underflows'])
            if report['underflow_increase']:raise ValueError('HDMI underflow occurred during camera inference')
            if report['invalid_packets']:raise ValueError('UART packet CRC/format errors occurred')
            link.request(b'A');report.update(status='PASS',camera_left_running=True);save()
    except Exception as exc:
        report.update(status='FAIL',error=repr(exc));save();raise
    print('PASS physical camera, SDRAM, teacher inference and preview counters:',a.output,flush=True)


if __name__=='__main__':main()
