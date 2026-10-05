# Source-only disposable copies; run from the Kogen worktree.
# Usage: python3 research/t79/copy_precision_projects.py /path/to/phoenix-project
from pathlib import Path
import shutil
import subprocess
import sys

root = Path.cwd()
projects = [("kogen", root), ("campfire", Path(sys.argv[1]).expanduser().resolve())]
for label, source in projects:
    destination = root / "_build" / f"t79-{label}-copy"
    assert destination.resolve().is_relative_to(root.resolve())
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir()
    tracked = subprocess.check_output(
        ["git", "-C", str(source), "ls-files", "-z"]
    ).decode().split("\0")
    files = {name for name in tracked if name}
    if label == "kogen":
        for directory in ["lib", "test"]:
            files.update(
                str(path.relative_to(source))
                for path in (source / directory).rglob("*")
                if path.suffix in [".ex", ".exs"]
            )
    count = 0
    for name in sorted(files):
        path = Path(name)
        excluded = {".git", "deps", "_build", ".kogen", "credentials", "secrets"}
        if any(part in excluded or part.startswith(".codex") for part in path.parts):
            continue
        if path.name.startswith(".env") or path.suffix in [".pem", ".key", ".keychain-db"]:
            continue
        origin = source / path
        if origin.is_symlink() or not origin.is_file():
            continue
        target = destination / path
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(origin, target)
        count += 1
    print(label, "copied source/project files:", count)
