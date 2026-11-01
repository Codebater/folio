"""Some altool failures return exit status 0. Require explicit upload acknowledgment."""
from pathlib import Path
import re
import sys


def upload_succeeded(log: str) -> bool:
    if re.search(r"(?:UPLOAD|VALIDATION)\s+FAILED|(?:^|\s)ERROR:", log, re.I | re.M):
        return False
    return bool(re.search(r"UPLOAD\s+SUCCEEDED|No errors uploading", log, re.I))


if __name__ == "__main__":
    if not upload_succeeded(Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")):
        sys.exit("Apple did not explicitly acknowledge a successful upload. Inspect the upload log above.")
    print("Apple explicitly acknowledged the upload. Build processing is a separate step.")
