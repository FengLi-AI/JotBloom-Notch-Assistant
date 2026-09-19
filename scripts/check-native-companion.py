#!/usr/bin/env python3
"""Run the DEBUG companion checks against an explicitly supplied app, with temporary data."""
from pathlib import Path
import argparse,json,os,subprocess,tempfile
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--app',type=Path,required=True);args=parser.parse_args()
app=args.app.expanduser().resolve();binary=app/'Contents/MacOS/JotBloom'
out=Path(tempfile.mkdtemp(prefix='jotbloom-companion-check-'));env=os.environ.copy();env.update(JOTBLOOM_COMPANION_SMOKE=str(out),JOTBLOOM_DEBUG_DATA_DIRECTORY=str(out/'data'),JOTBLOOM_UI_WALKTHROUGH='1')
with (out/'execution.log').open('w') as log:subprocess.run([str(binary)],env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=40)
report=json.loads((out/'native-checks.json').read_text());print(out);print('Native companion: %d/%d passed'%(sum(i['passed'] for i in report['checks']),len(report['checks'])))
if not report['passed']:raise SystemExit(json.dumps([i for i in report['checks'] if not i['passed']],ensure_ascii=False))
