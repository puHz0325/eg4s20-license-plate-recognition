import importlib.util
from pathlib import Path
import struct
import unittest
import zlib

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('minimal_runtime',ROOT/'minimal/host/start_camera.py')
runtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(runtime)


def packet(command='I',flags=0x63,classes=(11,43)):
    data=bytearray(128);data[:4]=b'TCH1';data[4]=ord(command);data[5]=flags;data[6]=len(classes);data[7]=1
    data[8:12]=struct.pack('<I',0xd5ca7402);data[24:24+len(classes)]=bytes(classes)
    data[120:124]=struct.pack('<I',0x20261028);data[124:128]=struct.pack('<I',zlib.crc32(data[:124]))
    return bytes(data)


class RuntimeTests(unittest.TestCase):
    def test_model_and_no_float_runtime_dependency(self):
        identity,data=runtime.model_files()
        self.assertEqual(len(data),156256);self.assertEqual(identity['crc32'],'D5CA7402')

    def test_response_integrity_and_all_corruption_offsets(self):
        data=packet();result=runtime.decode(data)
        self.assertEqual(result['prediction'],'浙C');self.assertEqual(result['clock_hz'],25000000)
        self.assertEqual(result['build_id'],'20261028')
        for index in range(128):
            broken=bytearray(data);broken[index]^=1
            with self.assertRaises(ValueError):runtime.decode(bytes(broken))

    def test_chunked_stream_resync_and_inflight_inference(self):
        bad=bytearray(packet());bad[42]^=1
        class Port:
            payload=bytearray(b'noise'+bad+packet()+packet('B',0x43,()))
            in_waiting=3
            def read(self,n):
                data=bytes(self.payload[:3]);del self.payload[:3];return data
            def write(self,data):return len(data)
            def flush(self):pass
        report=dict(transactions=[],invalid_packets=0)
        link=runtime.Link(Port(),dict(build_id='20261028'),report)
        self.assertEqual(link.request(b'B')['command'],'B')
        self.assertEqual(report['invalid_packets'],1);self.assertEqual(len(report['transactions']),2)

    def test_upload_block_layout_crc_and_read_delay_fallback(self):
        data=bytes(range(256))*16+bytes(range(16))
        class Link:
            commands=[];delay=None
            def request(self,value,allow_error=False):
                self.commands.append(value)
                if value[:1]==b'W':
                    block=value[6:-4]
                    if len(block)//16!=int.from_bytes(value[4:6],'little'):raise AssertionError('block length')
                    checksum=zlib.crc32(block)
                    if checksum!=int.from_bytes(value[-4:],'little'):raise AssertionError('block checksum')
                    return dict(upload_crc=checksum)
                if value[:1]==b'T':self.delay=value[1];return {}
                return dict(model_crc=0xd5ca7402 if self.delay==3 else 0,flags=0x43 if self.delay==3 else 0x49)
        link=Link();delay,attempts=runtime.load_model(link,data,dict(crc32='D5CA7402'))
        self.assertEqual(delay,3);self.assertEqual(len(attempts),2)
        writes=[c for c in link.commands if c[:1]==b'W']
        self.assertEqual([int.from_bytes(c[1:4],'little') for c in writes],[0x100000,0x101000])
        self.assertFalse(any(c==b'A' for c in link.commands))


if __name__=='__main__':unittest.main()
