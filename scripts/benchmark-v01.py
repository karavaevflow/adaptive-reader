#!/usr/bin/env python3
"""Compare paired Foundation/current processes, then profile search during scroll."""
import argparse
import json
from pathlib import Path
import subprocess
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('foundation',type=Path);p.add_argument('current',type=Path)
a=p.parse_args(); root=Path(__file__).resolve().parent.parent; out=root/'Research/v0.1';out.mkdir(parents=True,exist_ok=True)
rows=[]
for fixture in ['dark.pdf','nasa-apollo-earth.pdf','text.pdf']:
    for mode in ['original','selected']:
        for run in range(1,6):
            for label,binary in [('foundation',a.foundation),('v01',a.current)]:
                row=json.loads(subprocess.check_output([str(binary.resolve()),'scroll',str(root/'Research/Fixtures'/fixture),mode]))
                row.update(build=label,run=run);rows.append(row)
        print(fixture,mode,flush=True)
(out/'paired.json').write_text(json.dumps(rows,indent=2,sort_keys=True)+'\n')
rows=[]
for mode in ['original','selected']:
    for run in range(1,6):
        row=json.loads(subprocess.check_output([str(a.current.resolve()),'scroll',str(root/'Research/Large/large-text.pdf'),mode,'search']))
        row['run']=run;rows.append(row)
    print('large-search',mode,flush=True)
(out/'large-search.json').write_text(json.dumps(rows,indent=2,sort_keys=True)+'\n')
