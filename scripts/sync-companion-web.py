"""Keep website and native companion resources identical."""
from pathlib import Path
import argparse,shutil
root=Path(__file__).resolve().parent.parent
p=argparse.ArgumentParser();p.add_argument('--check',action='store_true');args=p.parse_args()
for name in ['companion-engine.js','native-renderer.js']:
 source=root/'JotBloom/Resources/Companions'/name;target=root/'site/companions'/name
 if args.check:
  if not target.exists() or source.read_bytes()!=target.read_bytes():raise SystemExit('Resource mismatch: '+name)
 else:
  target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
print('Companion website and native resources match.')
