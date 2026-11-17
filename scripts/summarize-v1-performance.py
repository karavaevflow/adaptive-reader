#!/usr/bin/env python3
"""Summarize retained five-process Release samples; never suppress threshold crossings."""
import json
from pathlib import Path
from statistics import median

root = Path(__file__).resolve().parent.parent
out = root / 'Research/v1.0'
comparisons = []

def load(path, key=None):
    value = json.loads((root / path).read_text())
    return value[key] if key else value

def compare(domain, old, new, group_keys, metrics):
    groups = sorted({tuple(row[key] for key in group_keys) for row in new})
    for group in groups:
        selected = [[row for row in rows if tuple(row[key] for key in group_keys) == group] for rows in [old, new]]
        if any(len(rows) != 5 for rows in selected):
            raise RuntimeError(f'Expected five independent runs: {domain} {group}')
        for metric in metrics:
            values = []
            for rows in selected:
                values.append(median(median(row[metric]) if isinstance(row[metric], list) else row[metric] for row in rows))
            baseline, current = values
            change = (current / baseline - 1) * 100 if baseline else None
            comparisons.append(dict(domain=domain, scenario=dict(zip(group_keys, group)), metric=metric,
                                    baseline=baseline, current=current, changePercent=change,
                                    investigate=change is not None and change > 20))

compare('split', load('Research/v0.6/performance-cpu-final.json', 'extended'),
        load('Research/v1.0/extended-performance.json', 'extended'), ['pair', 'mode'],
        ['openMS', 'peakRSSBytes', 'cpuFrameMS', 'ocrMS', 'cancellationMS'])
compare('pdf', load('Research/v0.6/performance-cpu-final.json', 'pdfIdle'),
        load('Research/v1.0/extended-performance.json', 'pdfIdle'), ['fixture', 'mode'],
        ['openMS', 'peakRSSBytes', 'cpuFrameMS'])
compare('epub', load('Research/v0.4/performance.json', 'epub'),
        load('Research/v1.0/epub-performance.json', 'epub'), ['speech'],
        ['longChapterFirstLayoutMs', 'reflowMs', 'locatorMs', 'speechFirstWordMs',
         'inputRoundTripMedianMs', 'runLoopIntervalP95Ms', 'peakClientBytes', 'sampledClientAndNewWebKitPeakBytes'])
compare('knowledge', load('Research/v0.5/performance.json', 'knowledge'),
        load('Research/v1.0/knowledge-performance.json', 'knowledge'), [],
        ['coldSearchMS', 'cachedSearchMS', 'boardDataOpenMS', 'canvasLayoutMedianMS',
         'canvasLayoutP95MS', 'nodeSaveMedianMS', 'cancelMS', 'peakClientBytes'])
compare('companion-fixture', load('Research/v0.3/overlap.json'),
        load('Research/v1.0/companion-overlap.json'), ['fixture', 'mode', 'companionWorkload'],
        ['openMS', 'peakRSSBytes', 'cpuFrameMS', 'indexMS', 'cancellationMS'])
metadata = {'sourceCommit': load('Research/v1.0/extended-performance.json')['sourceCommit'],
            'method': 'Median of five independent processes; CPU frames use median per-process medians. Historical baseline environment differences are documented separately.',
            'comparisons': comparisons}
(out / 'historical-comparison.json').write_text(json.dumps(metadata, indent=2) + '\n')
for row in comparisons:
    if row['investigate']:
        print(row['domain'], row['scenario'], row['metric'], f"{row['baseline']:.3f} -> {row['current']:.3f} ({row['changePercent']:+.1f}%)")
print(f'{len(comparisons)} metric comparisons; {sum(r["investigate"] for r in comparisons)} investigation triggers retained')

comparisons.clear()
paired_inputs = [
    ('pdf-paired-controls.json', 'pdf-paired', ['fixture', 'mode'], ['openMS', 'peakRSSBytes', 'cpuFrameMS']),
    ('companion-paired-controls.json', 'companion-fixture-paired', ['fixture', 'mode'], ['openMS', 'peakRSSBytes', 'cpuFrameMS', 'indexMS', 'cancellationMS']),
    ('epub-speech-paired.json', 'epub-speech-paired', [], ['speechFirstWordMs', 'longChapterFirstLayoutMs', 'reflowMs', 'locatorMs', 'peakClientBytes']),
    ('ocr-cancel-paired.json', 'ocr-cancel-paired', ['pair'], ['openMS', 'peakRSSBytes', 'cpuFrameMS', 'cancellationMS']),
]
for file, domain, groups, metrics in paired_inputs:
    data = json.loads((out / file).read_text())
    if not data.get('finishedUTC'):
        raise RuntimeError('Incomplete paired investigation: ' + file)
    compare(domain, [row for row in data['runs'] if row['version'] == 'baseline'],
            [row for row in data['runs'] if row['version'] == 'current'], groups, metrics)
(out / 'paired-comparison.json').write_text(json.dumps({'inputs': [row[0] for row in paired_inputs], 'comparisons': comparisons}, indent=2) + '\n')
for row in comparisons:
    if row['investigate']:
        print('PAIRED TRIGGER', row['domain'], row['scenario'], row['metric'], f"{row['changePercent']:+.1f}%")
print(f'{len(comparisons)} paired metric comparisons; {sum(r["investigate"] for r in comparisons)} investigation triggers')
