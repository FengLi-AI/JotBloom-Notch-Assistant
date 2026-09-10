"""Bundle an already published win-x64 self-contained build with NSIS.

Usage: python3 scripts/package.py PUBLISH_DIRECTORY OUTPUT_DIRECTORY
The resulting installer is a local installation artifact, not automatically published.
"""
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
publish, output = (Path(value).resolve() for value in sys.argv[1:3])
output.mkdir(parents=True, exist_ok=True)
required = ["JotBloom.exe", "JotBloom.dll", "JotBloom.Windows.Storage.dll",
            "JotBloom.Windows.Core.dll", "JotBloom.runtimeconfig.json", "coreclr.dll",
            "hostfxr.dll", "hostpolicy.dll", "e_sqlite3.dll", "PresentationFramework.dll"]
for name in required:
    assert (publish / name).is_file(), f"Missing runtime component: {name}"
for name in ["JotBloom.exe", "coreclr.dll", "e_sqlite3.dll"]:
    blob = (publish / name).read_bytes()
    pe = struct.unpack_from("<I", blob, 0x3C)[0]
    assert blob[:2] == b"MZ" and blob[pe:pe+4] == b"PE\0\0"
    assert struct.unpack_from("<H", blob, pe+4)[0] == 0x8664, f"Not x64: {name}"
config = json.loads((publish / "JotBloom.runtimeconfig.json").read_text())
assert config["runtimeOptions"].get("includedFrameworks"), "Runtime must be self-contained"
shutil.copy(root.parent / "LICENSE", publish / "LICENSE.txt")
shutil.copytree(root / "licenses", publish / "licenses", dirs_exist_ok=True)
(publish / "JotBloom-installed.txt").write_text("JotBloom Windows 1.0.2\n", encoding="utf-8")
files = sorted(p for p in publish.rglob("*") if p.is_file() and not p.name.startswith("._") and p.name != "payload-sha256.json")
for path in files:
    assert path.suffix.lower() not in [".sqlite", ".db", ".pdb"], f"Unexpected payload: {path.name}"
manifest = {str(p.relative_to(publish)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(publish / "payload-sha256.json").write_text(json.dumps(manifest, indent=2)+"\n")
files.append(publish / "payload-sha256.json")
def quote_relative(path):
    return str(path.relative_to(publish)).replace("\\", "/").replace("$", "$$").replace('"', '$\\"').replace("/", "\\")
uninstall = output / "uninstall-files.nsh"
directories = sorted((p for p in publish.rglob("*") if p.is_dir()), key=lambda p: len(p.parts), reverse=True)
uninstall.write_text("\n".join([f'Delete "$INSTDIR\\{quote_relative(p)}"' for p in files] +
                               [f'RMDir "$INSTDIR\\{quote_relative(p)}"' for p in directories])+"\n")
installer = output / "JotBloom-1.0.2-Windows-x64-Setup.exe"
subprocess.run(["makensis", "-WX", "-V3", f"-DPUBLISH_DIR={publish}", f"-DOUTPUT_FILE={installer}",
                f"-DAPP_ICON={root / 'src/JotBloom.Windows.Desktop/Assets/JotBloom.ico'}",
                f"-DUNINSTALL_FILES={uninstall}", f"-DINSTALL_KB={sum(p.stat().st_size for p in files)//1024}",
                str(root / "scripts/installer.nsi")], check=True)
uninstall.unlink(missing_ok=True)
digest = hashlib.sha256(installer.read_bytes()).hexdigest()
(output / "SHA256SUMS.txt").write_text(f"{digest}  {installer.name}\n")
print(f"Installer: {installer}\nBytes: {installer.stat().st_size}\nSHA256: {digest}")
