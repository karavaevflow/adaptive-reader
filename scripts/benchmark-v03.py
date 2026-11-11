#!/usr/bin/env python3
"""Five Release runs: idle control vs index/paced fixture-response overlap. No real model."""
import argparse,json,subprocess
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=Path);p.add_argument('--output',type=Path,default=Path('Research/v0.3/overlap.json'));a=p.parse_args()
root=Path(__file__).resolve().parent.parent;rows=[];a.output.parent.mkdir(parents=True,exist_ok=True)
for path in ['Research/Large/large-text.pdf','Research/Fixtures/text.pdf','Research/Fixtures/scan.pdf']:
 for mode in ['original','selected']:
  for workload in [False,True]:
   for run in range(1,6):
    args=[str(a.binary.resolve()),'scroll',str(root/path),mode]+(['companion'] if workload else [])
    row=json.loads(subprocess.check_output(args));row['run']=run;rows.append(row);a.output.write_text(json.dumps(rows,indent=2,sort_keys=True)+'\n')
   print(path,mode,'companion' if workload else 'idle',flush=True)
