import json
import re
from pathlib import Path


def has_old_name(text):
    text = re.sub(r"(?:[\w${}~./-]*/)?fixit(?:-common\.sh|-ai\.py|\.zsh|\.bash)", "", text)
    text = re.sub(r"(?:\$HOME|~|[\w${}.-]+)?/\.local/share/fixit/?", "", text)
    text = re.sub(r"\b(?:FIXIT_HOME|uninstall_fixit)\b", "", text)
    return re.search(r"\bfixit\b", text, re.I) is not None


if __name__ == "__main__":
    package = json.loads(Path("package.json").read_text())
    for field in ("name", "description", "bin"):
        assert not has_old_name(json.dumps(package.get(field, ""))), field
    for name in ("README.md", "install.sh"):
        for number, line in enumerate(Path(name).read_text().splitlines(), 1):
            assert not has_old_name(line), f"{name}:{number}: old product name"
