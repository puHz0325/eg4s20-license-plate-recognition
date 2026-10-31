"""Finish an already running QAT experiment and notify locally; never program hardware."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import ctypes
from ctypes import wintypes
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
STAGE = ROOT/'car_test/train/accuracy_stage3'
TEACHER = ROOT/'car_test/PL/teacher'
RUN = STAGE/'qat_run_04'
PACKAGE = STAGE/'robust_int8_04'
OUTPUT = STAGE/'qat_release_04'
STATUS = OUTPUT/'status.json'
BUILD = TEACHER/'td/video_20261029_qat_v1'
NOTIFY = True


def read(path): return json.loads(path.read_text(encoding='utf-8-sig'))
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()


def save_status(state, **details):
    blob = dict(state=state, run=str(RUN), package=str(PACKAGE), hardware_programmed=False, **details)
    temporary = STATUS.with_suffix('.tmp')
    temporary.write_text(json.dumps(blob, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    temporary.replace(STATUS)


def check_gates(fixed, quantized, stress, qat_audit=None):
    if not fixed.get('fixed_retention_passed'): raise ValueError('Fixed-test clean retention failed')
    if not quantized.get('validation_gate_passed'): raise ValueError('Clean INT8 validation failed')
    if qat_audit is not None:
        required={'main_retention','non_anhui_retention','robustness_gain','qat_export_agreement'}
        if (qat_audit.get('status')!='COMPLETE' or not qat_audit.get('passed') or
                not required<=qat_audit.get('gates',{}).keys() or
                not all(qat_audit['gates'][k] for k in required)):
            raise ValueError('Complete paired QAT/INT8 validation failed')
        if (not qat_audit.get('model_sha256') or qat_audit['model_sha256']!=stress.get('model_sha256')):
            raise ValueError('Full QAT audit refers to a different integer package')
        numeric=qat_audit.get('qat_integer',{})
        if (sum(v['samples'] for v in numeric.values())<4930 or
                any(v['prediction_differences'] for v in numeric.values())):
            raise ValueError('Require zero QAT/export prediction differences on complete validation')
    elif not stress.get('stress_quantization_passed'): raise ValueError('Photometric INT8 validation failed')
    if fixed.get('status') != 'COMPLETE' or quantized.get('status') != 'COMPLETE' or stress.get('status') != 'COMPLETE':
        raise ValueError('Incomplete evaluation')


def process_alive(pid):
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.WaitForSingleObject.restype = wintypes.DWORD
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x100000, False, pid)  # SYNCHRONIZE, read-only lifetime check.
    if not handle: return False
    try: return kernel.WaitForSingleObject(handle, 0) == 0x102
    finally: kernel.CloseHandle(handle)


def command(name, arguments):
    log = OUTPUT/(name+'.log')
    print('START '+name, flush=True)
    with log.open('w', encoding='utf-8') as stream:
        process = subprocess.run(list(map(str, arguments)), cwd=ROOT, stdout=stream,
            stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
    if process.returncode: raise RuntimeError(name+' failed; see '+str(log))
    print('PASS '+name, flush=True)


def notify(message, failure=False):
    if not NOTIFY:return
    ctypes.windll.user32.MessageBoxW(None, message, 'FPGA 车牌模型后台验证', 0x10000 | (0x10 if failure else 0x40))


def main():
    global OUTPUT,STATUS,NOTIFY
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--training-pid', type=int)
    p.add_argument('--resume-with-qat-audit',type=Path,help='Preserve the failed raw-FP32 audit and use a complete paired QAT/INT8 proof')
    p.add_argument('--no-popup',action='store_true')
    args = p.parse_args()
    NOTIFY=not args.no_popup
    if args.resume_with_qat_audit:
        OUTPUT=STAGE/'qat_release_04_verified';STATUS=OUTPUT/'status.json'
    if OUTPUT.exists(): raise FileExistsError('Preserve previous pipeline evidence')
    OUTPUT.mkdir(parents=True)
    try:
        save_status('WAITING_FOR_QAT', training_pid=args.training_pid)
        while not (RUN/'summary.json').exists():
            if not args.training_pid or not process_alive(args.training_pid): raise RuntimeError('QAT process exited without a completed summary')
            time.sleep(5)
        summary = read(RUN/'summary.json')
        if not summary['validation_qualified']: raise ValueError('QAT validation retention gate failed')
        if sha(RUN/'model_state.pth') != summary['model_state_sha256']: raise ValueError('QAT weights changed')
        config = read(RUN/'config.json')
        if config['qat_source_sha256'] != sha(Path(__file__).with_name('teacher_qat.py')):
            raise ValueError('QAT implementation changed during training')
        save_status('OFFLINE_EVALUATION', qat=summary)
        python = sys.executable
        if not args.resume_with_qat_audit:
            command('fixed_audit', [python,'-u','car_test/train/evaluate_robust_teacher.py','--run',RUN,
                '--parent-run','car_test/train/accuracy_stage2/teacher_run','--output',STAGE/'fixed_audit_04'])
            command('quantize', [python,'-u','car_test/train/quantize_teacher.py','--run',RUN,
                '--training-data','car_test/train/highres_v3/data_rehearsal','--main-data','car_test/train/highres_v2/data_quad',
                '--province-data','car_test/train/highres_v3/data_rehearsal','--robust-calibration',
                '--fixed-scales',STAGE/'robust_int8_03','--output',PACKAGE])
            command('integer_stress', [python,'-u','car_test/train/evaluate_integer_robust.py','--run',RUN,
                '--package',PACKAGE,'--output',PACKAGE/'stress_camera_evaluation.json'])
        fixed = read(STAGE/'fixed_audit_04/summary.json')
        quantized = read(PACKAGE/'evaluation.json')
        stress = read(PACKAGE/'stress_camera_evaluation.json')
        qat_audit=read(args.resume_with_qat_audit) if args.resume_with_qat_audit else None
        check_gates(fixed, quantized, stress,qat_audit)
        save_status('GENERATING_RTL_VECTORS', fixed=fixed['metrics'], integer_stress=stress['groups'])
        staging = TEACHER/'candidate_data_20261029_qat04'
        command('vectors', [python,'-u','car_test/PL/teacher/generate_vectors.py','--package',PACKAGE,
            '--float-run',RUN,'--output',staging])
        manifest = read(staging/'manifest.json')
        if any(sha(staging/name) != value for name, value in manifest['files'].items()):
            raise ValueError('Candidate vectors changed')
        for path in staging.iterdir():
            if path.is_file(): shutil.copy2(path,TEACHER/'data'/path.name)
        command('expected_crcs',[python,'car_test/PL/teacher/board/generate_expected.py'])
        save_status('MODELSIM_AND_TD_MAP')
        powershell = Path('C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe')
        jobs = [
            ('core_sim',[powershell,'-NoProfile','-ExecutionPolicy','Bypass','-File',TEACHER/'sim/run_tests.ps1']),
            ('video_sim',[python,'-B','car_test/PL/teacher/video/run_tests.py']),
            ('td_map',[python,'-B','car_test/PL/teacher/video/build_video.py','--stage','map','--output',BUILD,'--seed','2'])]
        with ThreadPoolExecutor(max_workers=3) as pool:
            futures = [pool.submit(command,name,arguments) for name,arguments in jobs]
            for future in futures: future.result()
        core = read(TEACHER/'simulation_report.json')
        video = read(TEACHER/'video/simulation_report.json')
        if core['status'] != 'PASS' or core['model_sha256'] != manifest['model_sha256'] or video['status'] != 'PASS':
            raise ValueError('Full ModelSim proof incomplete')
        save_status('TD_PLACE_ROUTE')
        command('td_pnr',[python,'-B','car_test/PL/teacher/video/build_video.py','--stage','pnr','--output',BUILD,'--seed','2'])
        save_status('TD_BITGEN')
        command('td_bit',[python,'-B','car_test/PL/teacher/video/build_video.py','--stage','bit','--output',BUILD,'--seed','2'])
        identity = read(TEACHER/'data/model_identity.json')
        result = dict(status='READY_FOR_JTAG', hardware_programmed=False, hardware_validated=False,
            bit=str(BUILD/'teacher_video_p1.bit'), bit_sha256=sha(BUILD/'teacher_video_p1.bit'),
            model=identity, qat=summary, fixed=fixed['metrics'], clean_int8={k:{a:b for a,b in v.items() if a!='examples'}
                for k,v in quantized['reports'].items()}, integer_stress=stress['groups'],
            core_compared_elements=core['total_compared_elements'], video_checks=len(video['tests']),
            implementation=read(BUILD/'pnr_summary.json'),
            limitations='Known correlated bright camera frames and six confusion pairs are not fully solved; inspect audits before hardware comparison.')
        if qat_audit:
            result['full_qat_integer_audit']=dict(path=str(args.resume_with_qat_audit.resolve()),
                sha256=sha(args.resume_with_qat_audit),gates=qat_audit['gates'],
                original_raw_fp32_stress_gate=stress['stress_quantization_passed'])
        (OUTPUT/'release.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
        shutil.copy2(TEACHER/'simulation_report.json',OUTPUT/'core_simulation.json')
        shutil.copy2(TEACHER/'video/simulation_report.json',OUTPUT/'video_simulation.json')
        save_status('READY_FOR_JTAG', release=str(OUTPUT/'release.json'), bit=result['bit'], bit_sha256=result['bit_sha256'])
        notify('量化感知训练、整数验证、ModelSim 和 TD 构建已完成。\n新 bit 已生成，尚未下载到 FPGA。\n请回到 Codex 查看报告并继续上板验证。\n'+str(OUTPUT/'release.json'))
    except Exception as exc:
        save_status('FAILED', error=repr(exc), traceback=traceback.format_exc())
        notify('后台验证未通过，原板上程序未改动。\n'+str(exc)+'\n详情：'+str(STATUS), failure=True)
        raise


if __name__ == '__main__': main()
