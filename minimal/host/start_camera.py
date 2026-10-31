"""Load the frozen model into SDRAM and start autonomous FPGA recognition.

Only pyserial is required. This program performs no image recognition on the PC.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import struct
import sys
import time
import zlib

ROOT=Path(__file__).resolve().parents[1]
CHARS=list('京沪津渝冀晋蒙辽吉黑苏浙皖闽赣鲁豫鄂湘粤桂琼川贵云藏陕甘青宁新')+list('0123456789ABCDEFGHJKLMNPQRSTUVWXYZIO-')


def model_files():
    identity=json.loads((ROOT/'model/model_identity.json').read_text(encoding='utf-8'))
    data=(ROOT/'model/model_init.bin').read_bytes()
    if identity['format']!='teacher-model-identity-v1':raise ValueError('Unsupported model format')
    if len(data)!=identity['model_bytes'] or hashlib.sha256(data).hexdigest()!=identity['model_sha256']:
        raise ValueError('Model file length/SHA256 mismatch')
    if f'{zlib.crc32(data)&0xffffffff:08X}'!=identity['crc32'].upper():raise ValueError('Model file CRC mismatch')
    return identity,data


def decode(packet):
    if len(packet)!=128 or packet[:4]!=b'TCH1':raise ValueError('Invalid response header/length')
    if zlib.crc32(packet[:124])&0xffffffff!=int.from_bytes(packet[124:128],'little'):
        raise ValueError('Response CRC mismatch')
    count=packet[6];clock_code=packet[5]>>6
    if packet[7]!=1 or count>32 or clock_code>1:raise ValueError('Unsupported response version/count/clock')
    classes=list(packet[24:24+count])
    return dict(command=chr(packet[4]),flags=packet[5],length=count,
        model_crc=int.from_bytes(packet[8:12],'little'),upload_crc=int.from_bytes(packet[12:16],'little'),
        cycles=int.from_bytes(packet[16:20],'little'),clock_hz=25000000 if clock_code==1 else 50000000,
        build_id=f'{int.from_bytes(packet[120:124],"little"):08x}',classes=classes,
        prediction=''.join(CHARS[i] if i<len(CHARS) else '?' for i in classes),raw=packet.hex())


def video_status(reply):
    flags,frames,underflows,inferences=struct.unpack('<4I',bytes.fromhex(reply['raw'])[56:72])
    return dict(configured=bool(flags&1),camera_fault=bool(flags&2),memory_ready=bool(flags&4),
        model_ready=bool(flags&8),camera_mode=bool(flags&16),busy=bool(flags&32),
        bridge_fault=bool(flags&64),service_error=bool(flags&128),fault_code=(flags>>8)&15,
        retries=(flags>>12)&3,published_frames=frames,underflows=underflows,inferences=inferences)


class Link:
    def __init__(self,port,identity,report):
        self.port=port;self.identity=identity;self.report=report;self.buffer=bytearray()

    def receive(self,timeout=15):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            index=self.buffer.find(b'TCH1')
            if index<0:self.buffer=self.buffer[-3:]
            else:
                del self.buffer[:index]
                if len(self.buffer)>=128:
                    try:reply=decode(bytes(self.buffer[:128]))
                    except ValueError:
                        self.report['invalid_packets']+=1;del self.buffer[0];continue
                    del self.buffer[:128]
                    if reply['build_id']!=self.identity['build_id']:raise ValueError('Wrong FPGA build; download the supplied bit first')
                    self.report['transactions'].append(reply)
                    return reply
            self.buffer.extend(self.port.read(max(1,self.port.in_waiting)))
        raise TimeoutError('No FPGA response. Check the bit download, board power, and UART USB/port.')

    def request(self,data,allow_error=False,timeout=20):
        if self.port.write(data)!=len(data):raise IOError('Incomplete UART write')
        self.port.flush();deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            reply=self.receive(max(.1,deadline-time.monotonic()))
            if reply['command']!=chr(data[0]):
                if reply['command']=='I':continue
                raise ValueError('Unexpected FPGA reply '+reply['command'])
            if reply['flags']&0x1c and not allow_error:raise ValueError('FPGA error flags '+hex(reply['flags']))
            return reply
        raise TimeoutError('UART command acknowledgement timed out')

    def status(self):return video_status(self.request(b'S'))


def load_model(link,data,identity):
    for offset in range(0,len(data),4096):
        block=data[offset:offset+4096];checksum=zlib.crc32(block)&0xffffffff
        command=b'W'+(0x100000+offset).to_bytes(3,'little')+struct.pack('<H',len(block)//16)+block+struct.pack('<I',checksum)
        reply=link.request(command)
        if reply['upload_crc']!=checksum:raise ValueError('Model upload block CRC mismatch')
    attempts=[]
    for delay in [2,3,4]:
        link.request(b'T'+bytes([delay]))
        reply=link.request(b'V',allow_error=True)
        attempts.append(dict(delay=delay,crc32=f"{reply['model_crc']:08X}",flags=reply['flags']))
        if reply['model_crc']==int(identity['crc32'],16) and reply['flags']&31==3:
            return delay,attempts
    raise ValueError('No valid SDRAM read window; '+json.dumps(attempts))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',help='Auto-detect the unique CH340/CH341')
    parser.add_argument('--status',action='store_true',help='Read-only status; do not load or start')
    parser.add_argument('--check-files',action='store_true',help='Verify model integrity without connecting hardware')
    parser.add_argument('--wait-results',type=int,default=3,help='Wait for this many real inference replies after starting')
    parser.add_argument('--output',type=Path,help='Fresh JSON log path')
    args=parser.parse_args()
    if args.wait_results<0:parser.error('--wait-results must be nonnegative')
    identity,data=model_files()
    if args.check_files:
        print(json.dumps(dict(status='PASS',model_bytes=len(data),crc32=identity['crc32'],sha256=identity['model_sha256']),indent=2));return
    import serial
    from serial.tools import list_ports
    port_name=args.port
    if not port_name:
        ports=[p.device for p in list_ports.comports() if 'CH340' in p.description or 'CH341' in p.description or p.vid==0x1a86]
        if len(ports)!=1:raise ValueError('Connect the UART USB cable or specify --port COM11 (use your actual port)')
        port_name=ports[0]
    output=args.output or ROOT/'logs'/('start_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f')+'.json')
    if output.exists():raise FileExistsError('Choose a fresh log filename')
    report=dict(status='IN_PROGRESS',port=port_name,model_sha256=identity['model_sha256'],transactions=[],invalid_packets=0)
    def save():
        output.parent.mkdir(parents=True,exist_ok=True)
        output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    save()
    try:
        with serial.Serial(port_name,115200,timeout=.1,write_timeout=10) as port:
            port.reset_input_buffer();link=Link(port,identity,report)
            if args.status:
                report['video_status']=link.status();report['status']='PASS';save()
                print(json.dumps(report['video_status'],ensure_ascii=False,indent=2));return
            link.request(b'B',allow_error=True,timeout=30)
            initial=link.status();report['initial_status']=initial
            deadline=time.monotonic()+5
            while not initial['configured'] or not initial['memory_ready']:
                if initial['camera_fault'] or time.monotonic()>=deadline:
                    raise RuntimeError('Camera/SDRAM not ready: '+json.dumps(initial))
                time.sleep(.2);initial=link.status()
            print('Loading 156256-byte model into FPGA SDRAM...',flush=True)
            delay,attempts=load_model(link,data,identity)
            report.update(selected_read_delay=delay,calibration=attempts)
            link.request(b'A');report['camera_enabled']=True
            results=[]
            for _ in range(args.wait_results):
                reply=link.receive()
                if reply['command']!='I' or reply['flags']&63!=0x23 or reply['model_crc']!=int(identity['crc32'],16):
                    raise ValueError('Invalid autonomous inference result')
                results.append(dict(prediction=reply['prediction'],length=reply['length'],milliseconds=reply['cycles']/(reply['clock_hz']/1000)))
                print(json.dumps(results[-1],ensure_ascii=False),flush=True)
            final=link.status()
            if not all(final[k] for k in ['configured','memory_ready','model_ready','camera_mode']) or any(final[k] for k in ['camera_fault','bridge_fault','service_error']):
                raise RuntimeError('Pipeline not healthy after starting: '+json.dumps(final))
            if final['underflows']>report['initial_status']['underflows']:raise RuntimeError('HDMI underflow increased')
            report.update(status='PASS',camera_left_running=True,results=results,final_status=final);save()
            print('PASS: model verified, camera inference running. Log: '+str(output),flush=True)
    except BaseException as error:
        report.update(status='FAIL',error=repr(error));save();raise


if __name__=='__main__':
    main()
