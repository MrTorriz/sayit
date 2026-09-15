#!/usr/bin/env python3
"""Install the pinned model, verifying cached, copied and downloaded files."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
from urllib.request import urlopen


def valid(path, entry):
    if not path.is_file() or path.stat().st_size != entry["bytes"]:
        return False
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == entry["sha256"]


def install(destination, manifest, source=None):
    destination.mkdir(parents=True, exist_ok=True)
    for entry in manifest["files"]:
        name = entry["file"]
        if Path(name).name != name or name in (".", ".."):
            raise ValueError("invalid model filename")
        target = destination / name
        if valid(target, entry):
            continue
        partial = destination / (name + ".partial")
        try:
            if source is not None:
                if not valid(source / name, entry):
                    raise ValueError(f"source checksum mismatch: {name}")
                shutil.copyfile(source / name, partial)
            else:
                url = f'https://huggingface.co/{manifest["repo"]}/resolve/{manifest["revision"]}/{name}'
                print(f"Downloading {name}", flush=True)
                with urlopen(url, timeout=60) as response, partial.open("wb") as out:
                    shutil.copyfileobj(response, out)
            if not valid(partial, entry):
                raise ValueError(f"download checksum mismatch: {name}")
            partial.replace(target)
        finally:
            partial.unlink(missing_ok=True)
    print("All model checksums verified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--source", type=Path)
    args = parser.parse_args()
    manifest = json.loads(Path(__file__).with_name("model-provenance.json").read_text())
    install(args.destination, manifest, args.source)


if __name__ == "__main__":
    main()
