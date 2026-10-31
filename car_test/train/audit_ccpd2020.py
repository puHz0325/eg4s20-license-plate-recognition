"""Audit the local CCPD2020 download for auxiliary non-Anhui training suitability."""
import argparse
from collections import Counter
import json
import os
from pathlib import Path

from prepare_highres import PROVINCES


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    splits = {}; plates = {}; all_provinces = Counter(); lengths = Counter()
    for folder in sorted(args.source.iterdir()):
        if not folder.is_dir(): continue
        counts = Counter(); sizes = Counter(); groups = set(); invalid = 0
        for entry in os.scandir(folder):
            if not entry.name.lower().endswith('.jpg'):continue
            try:
                fields = Path(entry.name).stem.split('-')
                indices = [int(x) for x in fields[4].split('_')]
                if not 0 <= indices[0] < 31:raise ValueError('province')
                counts[PROVINCES[indices[0]]] += 1; sizes[len(indices)] += 1
                groups.add(fields[4])
            except (ValueError,IndexError):invalid += 1
        plates[folder.name] = groups; all_provinces.update(counts); lengths.update(sizes)
        splits[folder.name] = dict(samples=sum(counts.values()),provinces=dict(counts),
                                  lengths=dict(sizes),distinct_plates=len(groups),invalid=invalid)
    total = sum(all_provinces.values())
    overlaps = {f'{a}/{b}':len(plates[a]&plates[b]) for a,b in
                [('train','val'),('train','test'),('val','test')]}
    report = dict(source=str(args.source.resolve()),samples=total,provinces=dict(all_provinces),
        lengths=dict(lengths),anhui_fraction=all_provinces['皖']/total,
        non_anhui_samples=total-all_provinces['皖'],splits=splits,plate_overlap=overlaps,
        decision='Exclude from this seven-character non-Anhui reinforcement run',
        reasons=['All annotated targets have eight characters; never truncate labels to seven',
                 'About 96.6% of images are Anhui, so bulk mixing worsens the intended balance',
                 'Green-plate appearance differs from the blue-plate/R8 deployment domain',
                 'Original image-level splits do not satisfy our plate-disjoint evaluation contract'],
        future_use='Can be separately evaluated for a genuine eight-character task or carefully isolated auxiliary learning; not a replacement for missing province coverage')
    args.output.mkdir(parents=True,exist_ok=True)
    (args.output/'audit.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    text = ['# CCPD2020加入训练的评估','',f'本地共{total}张，全部为八字符标注；安徽{all_provinces["皖"]}张（{all_provinces["皖"]/total:.2%}），其他省份合计{total-all_provinces["皖"]}张。','',
            '| 原目录 | 图片 | 非安徽图片 | 不同车牌 |','|---|---:|---:|---:|']
    for split,value in splits.items():
        text.append(f'| {split} | {value["samples"]} | {value["samples"]-value["provinces"].get("皖",0)} | {value["distinct_plates"]} |')
    text += ['',f'同车牌交叉：train/val {overlaps["train/val"]}个，train/test {overlaps["train/test"]}个，val/test {overlaps["val/test"]}个。原划分不满足本工程按车牌隔离的验收要求，不能直接照搬。','',
             '结论：不作为本轮强化非安徽七字符车牌训练的主数据，也不将八字符截成七字符混入。完整八字符辅助训练或新能源识别可以另设任务、重新分组并单独评测；它不能解决多数省份样本缺失。当前优先扩展CCPD2019可用非安徽原图、加强省份采样和省份辅助损失。','']
    (args.output/'评估.md').write_text('\n'.join(text),encoding='utf-8')
    print(json.dumps({k:report[k] for k in ['samples','anhui_fraction','non_anhui_samples','plate_overlap','decision']},ensure_ascii=False))


if __name__=='__main__':main()
