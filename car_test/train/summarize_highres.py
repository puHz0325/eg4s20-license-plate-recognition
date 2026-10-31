"""Summarize completed paired training, including a plate-group bootstrap interval."""
import argparse
from collections import defaultdict
import json
from pathlib import Path

import numpy as np

from prepare_highres import file_hash


def paired_plate_bootstrap(left, right, draws=2000, seed=20261026):
    groups = defaultdict(lambda: [0, 0])
    better = worse = both_correct = both_wrong = 0
    for a, b in zip(left, right, strict=True):
        if a['id'] != b['id'] or a['expected'] != b['expected']:
            raise ValueError('The two models were not evaluated on the same ordered test examples')
        ac, bc = bool(a['exact_match']), bool(b['exact_match'])
        group = groups[a['expected']]
        group[0] += int(bc)-int(ac); group[1] += 1
        better += bc and not ac; worse += ac and not bc
        both_correct += ac and bc; both_wrong += not ac and not bc
    values = np.asarray(list(groups.values()), dtype=np.int64)[:, :2]
    rng = np.random.default_rng(seed); estimates = []
    for start in range(0, draws, 100):
        indices = rng.integers(0, len(values), size=(min(100,draws-start),len(values)))
        totals = values[indices].sum(axis=1)
        estimates.extend((totals[:,0]/totals[:,1]).tolist())
    return dict(direction='188x48 minus 128x32',unit='plate-group resampling',draws=draws,
        distinct_plate_groups=len(values),both_correct=int(both_correct),both_wrong=int(both_wrong),
        only_188_correct=int(better),only_128_correct=int(worse),
        accuracy_delta_percentage_points=100*(better-worse)/len(left),
        bootstrap_95_percent_interval_pp=(100*np.percentile(estimates,[2.5,97.5])).tolist())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--run',type=Path,required=True)
    parser.add_argument('--data',type=Path,required=True)
    args = parser.parse_args()
    comparison = json.loads((args.run/'comparison.json').read_text(encoding='utf-8'))
    tests = {size:json.loads((args.run/size/'test.json').read_text(encoding='utf-8'))
             for size in ['128x32','188x48']}
    paired = paired_plate_bootstrap(tests['128x32']['predictions'],tests['188x48']['predictions'])
    (args.run/'paired_comparison.json').write_text(json.dumps(paired,indent=2)+'\n',encoding='utf-8')
    manifest = json.loads((args.data/'manifest.json').read_text(encoding='utf-8'))
    lines = [
        '# 高分辨率模型重训结果', '',
        '来源：E:/Download/CCPD2019，原图R通道直接生成两种输入。', '',
        '裁剪使用原矩形与四角范围并集加边距；首次矩形截字试验已作废，不纳入以下结果。', '',
        '训练/验证/测试按车牌分组，无相同车牌或裁剪像素跨集合。两模型同种子从头训练，无旧权重初始化。', '',
        '| 数据集 | 图像 | 不同车牌 |', '|---|---:|---:|',
    ]
    for split in ['train','val','test']:
        info = manifest['splits'][split]
        lines.append(f"| {split} | {info['samples']} | {info['distinct_plates']} |")
    lines += ['', '| 输入 | 最佳轮次 | 验证整牌准确率 | 测试整牌准确率 | 测试CER |',
              '|---|---:|---:|---:|---:|']
    for summary in comparison['variants']:
        val, test = summary['best_validation'], summary['test']
        lines.append(f"| {summary['variant']} | {summary['best_epoch']} | {val['plate_accuracy']:.2%} | "
                     f"{test['plate_accuracy']:.2%} ({test['exact_matches']}/{test['samples']}) | {test['character_error_rate']:.2%} |")
    lines += ['', f"按验证指标选出的候选：**{comparison['selected_variant']}**。这不是FPGA部署结论，还需整数校准、资源/速度和摄像头验证。", '',
              f"188×48相对128×32的测试整牌准确率差：{paired['accuracy_delta_percentage_points']:.3f}个百分点；"
              f"按车牌分组bootstrap的95%区间：{paired['bootstrap_95_percent_interval_pp'][0]:.3f}～{paired['bootstrap_95_percent_interval_pp'][1]:.3f}个百分点。", '',
              '| 目标替换错误 | 128×32次数 | 188×48次数 |', '|---|---:|---:|---:|']
    for pair in ['A>Q','C>G','C>Q','C>0','G>C','0>C','Q>C']:
        lines.append(f"| {pair} | {tests['128x32']['substitutions'].get(pair,0)} | {tests['188x48']['substitutions'].get(pair,0)} |")
    legacy_path = args.run/'legacy_reference.json'
    if legacy_path.exists():
        legacy = json.loads(legacy_path.read_text(encoding='utf-8'))
        metrics = legacy['metrics']
        lines += ['', f"旧94×24模型的同批原图诊断参考：整牌准确率{metrics['plate_accuracy']:.2%}"
                  f"（{metrics['exact_matches']}/{metrics['samples']}），CER {metrics['character_error_rate']:.2%}。",
                  f"已知旧train_data1目录与本测试集重合{legacy['known_old_directory_plate_overlap']}个车牌；"
                  '旧模型完整训练历史未知，故不能将此分数称为严格独立基线，也不能把差异全部归因于分辨率。']
    lines += ['', '错误次数基于逐字符编辑距离对齐，只反映这4000张CCPD留出图，不代表实拍混淆已经解决。', '',
              '限制：数据省份分布偏安徽，部分省份只有少量样本；这不是官方CCPD标准测试成绩，不是OV5640实拍准确率。当前仅完成浮点模型训练，未量化、未修改RTL、未下载或烧写Flash。', '',
              '产物：各尺寸目录内model_state.pth为纯权重，best.pt/last.pt含训练状态；config.json记录高度和数据版本。旧94×24权重与板上bit保留。', '']
    province_count = len(tests['128x32']['province_results'])
    anhui_fraction = manifest['splits']['test']['provinces'].get('皖',0)/manifest['splits']['test']['samples']
    lines += [f"精度判断：128×32整牌错误{tests['128x32']['samples']-tests['128x32']['exact_matches']}张，"
              f"约每8张错1张；测试集安徽占{anhui_fraction:.1%}。按测试中{province_count}个省份等权计算，"
              f"128×32宏平均整牌准确率只有{tests['128x32']['macro_province_accuracy']:.2%}。"
              '稀有省份样本很少，这个宏平均也有很大不确定性。当前适合作为继续改进的原型基线，不应作为比赛最终精度验收通过。', '',
              '下一轮优先改善省份/字符数据覆盖、裁剪质量和实际相机域样本，再重新评估模型容量与感受野；多帧投票只能缓解随机错误，不能保证纠正持续误判。', '']
    (args.run/'训练结果.md').write_text('\n'.join(lines),encoding='utf-8')
    root = Path(__file__).resolve().parents[2]
    source_files = [root/'car_test/train'/name for name in
                    ['model.py','prepare_highres.py','train_highres.py','summarize_highres.py','evaluate_legacy_highres.py']]
    sources = {str(path.relative_to(root)):file_hash(path) for path in source_files}
    release = dict(status='FLOAT_TRAINING_COMPLETE',dataset_manifest_sha256=file_hash(args.data/'manifest.json'),
        source_sha256=sources,model_sha256={size:file_hash(args.run/size/'model_state.pth') for size in tests},
        legacy_model_sha256=file_hash(root/'car_test/train/weights/fpga_best_model.pth'),
        current_board_bit_sha256=file_hash(root/'car_test/PL/td/video_lpr_osd_health_build_p1/video_lpr_osd_p1.bit'),
        quantized=False,rtl_modified=False,hardware_downloaded=False)
    (args.run/'release.json').write_text(json.dumps(release,indent=2)+'\n',encoding='utf-8')
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print('Optional matplotlib unavailable; JSON and Markdown reports complete')
    else:
        fig, axes = plt.subplots(1,3,figsize=(13,3.8))
        for size in tests:
            history = [json.loads(line) for line in (args.run/size/'history.jsonl').read_text(encoding='utf-8').splitlines()]
            epochs = [row['epoch'] for row in history]
            axes[0].plot(epochs,[row['train_loss'] for row in history],label=size)
            axes[1].plot(epochs,[100*row['validation']['plate_accuracy'] for row in history],label=size)
            axes[2].plot(epochs,[100*row['validation']['character_error_rate'] for row in history],label=size)
        for ax,title in zip(axes,['Training CTC loss','Validation plate accuracy (%)','Validation character error rate (%)'],strict=True):
            ax.set_title(title); ax.set_xlabel('Epoch'); ax.grid(alpha=.25); ax.legend()
        fig.tight_layout(); fig.savefig(args.run/'training_curves.png',dpi=160); plt.close(fig)
    print(json.dumps({'selected':comparison['selected_variant'],'paired':paired},indent=2))
    print((args.run/'训练结果.md').resolve())


if __name__ == '__main__':
    main()
