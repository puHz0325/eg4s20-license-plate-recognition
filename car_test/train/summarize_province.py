"""Report province-focused experiments and their accuracy tradeoffs without deploying weights."""
import argparse
import json
from pathlib import Path
import shutil

from prepare_highres import file_hash
from summarize_highres import paired_plate_bootstrap
from train_highres import save_json
from lpr_common import CHARS


def prefix_rows(rows, non_anhui=True):
    return [dict(row,exact_match=bool(row['prediction']) and row['prediction'][0]==row['expected'][0])
            for row in rows if not non_anhui or row['expected'][0]!='皖']


def compare_subset(parent,new,prefix=False):
    a=prefix_rows(parent) if prefix else [r for r in parent if r['expected'][0]!='皖']
    b=prefix_rows(new) if prefix else [r for r in new if r['expected'][0]!='皖']
    result=paired_plate_bootstrap(a,b)
    result['direction']='selected province-focused minus parent128'
    result['only_new_correct']=result.pop('only_188_correct')
    result['only_parent_correct']=result.pop('only_128_correct')
    result['samples']=len(a)
    result['parent_accuracy']=sum(r['exact_match'] for r in a)/len(a)
    result['new_accuracy']=sum(r['exact_match'] for r in b)/len(b)
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    names=['province_20261026','province_bnfreeze_20261026',
           'province_rehearsal_20261026','province_rehearsal_ctc_20261026']
    experiments=[]
    for name in names:
        folder=args.root/name
        summary=json.loads((folder/'summary.json').read_text(encoding='utf-8'))
        config=json.loads((folder/'config.json').read_text(encoding='utf-8'))
        experiments.append(dict(name=name,summary=summary,config=config))
    selected=max(experiments,key=lambda r:(
        r['summary']['validation']['non_anhui_plate_accuracy'],
        r['summary']['validation']['macro_supported_accuracy'],r['summary']['validation']['plate_accuracy']))
    name=selected['name'];folder=args.root/name;summary=selected['summary']
    parent=json.loads((folder/'parent_test.json').read_text(encoding='utf-8'))
    new=json.loads((folder/'test.json').read_text(encoding='utf-8'))
    plate=compare_subset(parent['predictions'],new['predictions'])
    prefix=compare_subset(parent['predictions'],new['predictions'],True)
    args.output.mkdir(parents=True,exist_ok=True)
    save_json(args.output/'comparison.json',dict(selected=name,selection='validation metrics only; each experiment retains only a checkpoint satisfying its Anhui floor',
        experiments=experiments,non_anhui_plate=plate,non_anhui_prefix=prefix,
        ccpd2020_used=False,hardware_deployed=False,
        caveat='Prototype improvement is limited. The fixed test was evaluated across experiments; final independent real-camera validation remains outstanding.'))
    bundle=args.output/'selected_candidate';bundle.mkdir(exist_ok=True)
    shutil.copyfile(folder/'model_state.pth',bundle/'model_state.pth')
    shutil.copyfile(folder/'config.json',bundle/'training_config.json')
    assert file_hash(bundle/'model_state.pth')==summary['model_state_sha256']
    save_json(bundle/'model.json',dict(input_wh=[128,32],classes=68,ctc_steps=32,
        chars=CHARS,blank_index=67,grayscale='R8',normalization='(pixel-127.5)/128',
        model_class='FPGA_LPRNet(68,input_height=32)',inference_parameter_count=summary['inference_parameter_count'],
        auxiliary_loss_deployed=False,ccpd2020_used=False,model_sha256=summary['model_state_sha256'],
        status='EXPERIMENTAL_CANDIDATE_NOT_HARDWARE_VALIDATED',origin=str(folder.resolve())))
    lines=['# 仅使用CCPD2019的外省强化训练结果','',
        'CCPD2020未加入任何本轮训练。此前评估发现其96.58%为安徽牌，且全部八字符，不适合作为当前外省七字符识别的主补充。','',
        '原型训练模型仍为128×32七层CNN，增加的是训练采样/损失和数据视图，推理参数数量不变。没有量化、修改RTL或下载到板卡。','',
        '新增省份训练集21148张，非安徽15150张；重放实验使用58518个训练视图（48641个不同车牌），不把增强视图当作独立实拍。',
        '新验证932张、新测试915张，其车牌均未出现在父模型训练/验证/测试中。测试内515张非安徽。按车牌分组，不与训练交叉；当前仍不是实际OV5640测试。','',
        '新915张的省份分布及原生分辨率筛选条件与原4000张不同，不能把新集40%左右的外省成绩直接同原总体87.55%相比；表中只比较同一批图片上的父模型与候选。','',
        '| 实验 | 最佳轮次 | 非安徽验证整牌 | 安徽验证整牌 | 安徽保护下限 |',
        '|---|---:|---:|---:|---:|']
    for row in experiments:
        s=row['summary'];v=s['validation']
        lines.append(f"| {row['name']} | {s['best_epoch']} | {v['non_anhui_plate_accuracy']:.2%} | {v['anhui_plate_accuracy']:.2%} | {s['anhui_floor']:.2%} |")
    lines+=['','最佳轮次0表示实验没有通过该轮保护条件，保留了原父模型；不是把未达标权重冒充新成果。',
        f'按验证指标选出的实验候选：`{name}`。这只代表当前实验候选，不建议直接替换板上模型。','',
        '| 固定评测项 | 父模型 | 强化候选 |','|---|---:|---:|',
        f"| 非安徽省份首字正确率（515张） | {prefix['parent_accuracy']:.2%} | {prefix['new_accuracy']:.2%} |",
        f"| 非安徽整牌准确率（515张） | {plate['parent_accuracy']:.2%} | {plate['new_accuracy']:.2%} |",
        f"| 原4000张回归集整牌准确率 | 87.55% | {summary['old_test_regression']['plate_accuracy']:.2%} |",'',
        f"非安徽整牌差值的按车牌bootstrap 95%区间为{plate['bootstrap_95_percent_interval_pp'][0]:.2f}～{plate['bootstrap_95_percent_interval_pp'][1]:.2f}个百分点；"
        f"省份首字差值区间为{prefix['bootstrap_95_percent_interval_pp'][0]:.2f}～{prefix['bootstrap_95_percent_interval_pp'][1]:.2f}个百分点。",'',
        '结论：省份首字识别有所改善，整牌改善有限，而且原分布总体成绩回退。不能据此宣称外省识别已可靠，不能声称达到比赛最终95%以上目标。',
        '候选仅保留供后续分析；原128×32父模型和旧94×24板上权重/bit均保留。', '',
        '| 省份 | 测试张数 | 父模型整牌 | 强化候选整牌 |','|---|---:|---:|---:|']
    for province,value in sorted(new['province_results'].items()):
        old=parent['province_results'][province]
        lines.append(f"| {province} | {value['samples']} | {old['accuracy']:.2%} | {value['accuracy']:.2%} |")
    lines+=['','稀有省份样本数很小，单个样本的高低分不能代表泛化。训练原始图中藏仅1张、宁8张、青9张，过采样和透视增强不能创造新的真实信息。',
        '后续需要补充多省真实图像及固定ROI相机样本，审计难例/标签并评估池化前特征提取容量；不继续通过调整同一个测试集的结果制造高分。','']
    (args.output/'外省强化训练报告.md').write_text('\n'.join(lines),encoding='utf-8')
    snapshot=args.output/'source_snapshot';snapshot.mkdir(exist_ok=True)
    for filename in ['model.py','prepare_highres.py','prepare_province.py','prepare_rehearsal.py',
                     'train_highres.py','finetune_province.py','summarize_highres.py','summarize_province.py']:
        shutil.copyfile(Path(__file__).with_name(filename),snapshot/filename)
    shutil.copyfile(Path(__file__).resolve().parents[1]/'lpr_common.py',snapshot/'lpr_common.py')
    save_json(args.output/'source_sha256.json',{path.name:file_hash(path) for path in snapshot.glob('*.py')})
    print(json.dumps(dict(selected=name,non_anhui_plate=plate,non_anhui_prefix=prefix),indent=2))


if __name__=='__main__':main()
