"""Fill {{placeholders}} from results.json, write traceability, render .docx with pandoc."""
import csv
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

ANY_PLACEHOLDER = re.compile(r"\{\{(.*?)\}\}")
STRICT_KEY = re.compile(r"[A-Za-z0-9_.]+")
TEMPLATE = Path(__file__).parent / "templates" / "reference.docx"
USAGE = ("usage: python -m tools.build_manuscript <paper_dir> [--results <results.json>] "
         "[--names manuscript,title_page,...]")
DEFAULT_NAMES = ("manuscript", "title_page", "cover_letter")


def fill(text: str, results: dict) -> tuple[str, list[str]]:
    found = ANY_PLACEHOLDER.findall(text)
    if "{{" in ANY_PLACEHOLDER.sub("", text):
        raise ValueError("Malformed placeholder: unclosed '{{' in text")
    malformed = [m for m in dict.fromkeys(found) if not STRICT_KEY.fullmatch(m)]
    if malformed:
        raise ValueError(f"Malformed placeholders: {', '.join(repr(m) for m in malformed)}")
    keys = list(dict.fromkeys(found))
    unknown = [k for k in keys if k not in results]
    if unknown:
        raise KeyError(f"Unknown placeholders: {', '.join(unknown)}")
    for k in keys:
        if results[k].get("display") is None:
            raise ValueError(f"Result '{k}' has no display value")
    out = ANY_PLACEHOLDER.sub(lambda m: str(results[m.group(1)]["display"]), text)
    if "{{" in out:
        raise ValueError("Unresolved '{{' remains after filling placeholders")
    return out, keys


def write_traceability(keys, results, out_csv) -> None:
    with open(out_csv, "w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=["key", "display", "value", "script", "description"])
        w.writeheader()
        for k in keys:
            r = results[k]
            w.writerow({"key": k, "display": r["display"], "value": r["value"],
                        "script": r["script"], "description": r["description"]})


def build(paper_dir, results_path=None, names=None) -> list[Path]:
    """Fill and render <name>.md files in paper_dir. results_path defaults to paper_dir/results.json;
    names defaults to DEFAULT_NAMES (missing files are skipped)."""
    d = Path(paper_dir)
    results_path = Path(results_path) if results_path else d / "results.json"
    results = json.loads(results_path.read_text(encoding="utf-8"))

    # Phase 1: fill every present file so any missing key fails before rendering.
    used, filled_files = [], []
    for name in (names or DEFAULT_NAMES):
        src = d / f"{name}.md"
        if not src.exists():
            continue
        text, keys = fill(src.read_text(encoding="utf-8"), results)
        used += [k for k in keys if k not in used]
        filled = d / f"{name}_filled.md"
        filled.write_text(text, encoding="utf-8")
        filled_files.append((name, filled))

    # Phase 2: render.
    if filled_files and shutil.which("pandoc") is None:
        raise RuntimeError("pandoc not found on PATH; install pandoc (https://pandoc.org) and retry")
    outputs = []
    for name, filled in filled_files:
        docx = d / f"{name}.docx"
        subprocess.run(["pandoc", str(filled), "-o", str(docx), f"--reference-doc={TEMPLATE}",
                        f"--resource-path={d}"], check=True)
        outputs.append(docx)
    write_traceability(used, results, d / "traceability.csv")
    return outputs


def main(argv=None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    opts = {"--results": None, "--names": None}
    pos = []
    while argv:
        a = argv.pop(0)
        if a in opts:
            if not argv:
                print(USAGE, file=sys.stderr)
                return 2
            opts[a] = argv.pop(0)
        else:
            pos.append(a)
    if len(pos) != 1:
        print(USAGE, file=sys.stderr)
        return 2
    names = tuple(n.strip() for n in opts["--names"].split(",") if n.strip()) if opts["--names"] else None
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    for p in build(pos[0], results_path=opts["--results"], names=names):
        print("wrote", p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
