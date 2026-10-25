"""Check papers/E/results.json against the contract papers/E/results_keys.md and the manuscript files.

    python papers/E/check_results_keys.py                  # exit 1 on any failure below
    python papers/E/check_results_keys.py --allow-pending  # check the git-ignored papers/E/results.pending.json:
                                                           # pending displays are reported, then accepted
    python papers/E/check_results_keys.py --build          # also fill and trace the manuscript files with
                                                           # tools.build_manuscript.build(names=E_NAMES) (F13)
    --results PATH                                         # another results file (default papers/E/results.json,
                                                           # or results.pending.json with --allow-pending)

Contract keys are the backticked `E.*` names in the first cell of the table rows that start with "| `E.", with
shell-style brace expansion only (`{a,b}`; consecutive groups expand as a product; no nesting; ruling F20).
Fails (exit 1) when:
- the results.json key set differs from the contract;
- a placeholder {{E.*}} in a manuscript file (E_NAMES: manuscript, supplement, title page, cover letter) is not in
  the contract;
- a display is empty;
- the contract's declared total "(N keys)" or a section's "(N keys)" differs from the keys it lists (F20);
- a display reads "pending (<script> not finished)" (a step of models/E/run_all.R had not finished), unless
  --allow-pending is given and the file is not named results.json: a results.json never holds pending displays
  (run_all.R --allow-pending writes the git-ignored results.pending.json); pending keys are always counted by
  producing script.
Pending drafts (opt-in only, never the default): `--build --allow-pending` fills the manuscript files from
results.pending.json; equivalently `python -m tools.build_manuscript papers/E --results papers/E/results.pending.json
--names manuscript,supplement,title_page,cover_letter`. Their outputs (*_filled.md, *.docx, traceability.csv) show
"pending (...)" text and must not be committed.
Contract keys not used by the manuscript files are reported, not failed (the manuscript is written in Task 13).
"""
import itertools
import json
import re
import sys
from collections import Counter
from pathlib import Path

PAPER = Path(__file__).resolve().parent
REPO = PAPER.parents[1]
# F13: the manuscript files are named explicitly, the supplement included, so that its keys are filled and traced.
E_NAMES = ("manuscript", "supplement", "title_page", "cover_letter")
SECTION_RE = re.compile(r"^## (\d+)\. .*\((\d[\d,]*) keys?\)\s*$")
PENDING_RE = re.compile(r"^pending \((\S+) not finished\)$")


def expand(key: str) -> list[str]:
    parts = re.split(r"(\{[^{}]*\})", key)
    opts = [p[1:-1].split(",") if p.startswith("{") else [p] for p in parts]
    return ["".join(c) for c in itertools.product(*opts)]


def _row_keys(lines) -> list[str]:
    keys = []
    for line in lines:
        if not line.startswith("| `E."):
            continue
        cell = line.split("|")[1]
        for k in re.findall(r"`(E\.[^`]+)`", cell):
            keys += [x for x in expand(k) if x not in keys]
    return keys


def contract_keys(md: str) -> set[str]:
    return set(_row_keys(md.splitlines()))


def declared_total(md: str) -> int:
    intro = next(ln for ln in md.splitlines() if ln.startswith("This contract lists"))
    return int(re.search(r"\((\d[\d,]*) keys\)", intro).group(1).replace(",", ""))


def section_counts(md: str) -> list[tuple[str, int, int]]:
    """(section number, declared, found) for every numbered section with a "(N keys)" heading."""
    lines = md.splitlines()
    out = []
    for i, line in enumerate(lines):
        m = SECTION_RE.match(line)
        if not m:
            continue
        j = next((k for k in range(i + 1, len(lines)) if lines[k].startswith("## ")), len(lines))
        out.append((m.group(1), int(m.group(2).replace(",", "")), len(_row_keys(lines[i + 1:j]))))
    return out


def placeholders(paper: Path, names=E_NAMES) -> set[str]:
    used = set()
    for n in names:
        f = paper / f"{n}.md"
        if f.exists():
            used |= set(re.findall(r"\{\{(E\.[A-Za-z0-9_.]+)\}\}", f.read_text(encoding="utf-8")))
    return used


def pending_by_script(res: dict) -> Counter:
    c = Counter()
    for v in res.values():
        m = PENDING_RE.match(str(v.get("display", "")))
        if m:
            c[m.group(1)] += 1
    return c


def main(argv=None, paper: Path = PAPER) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    allow_pending = "--allow-pending" in argv
    build = "--build" in argv
    default = paper / ("results.pending.json" if allow_pending else "results.json")
    results_path = Path(argv[argv.index("--results") + 1]) if "--results" in argv else default
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    md = (paper / "results_keys.md").read_text(encoding="utf-8")
    contract = contract_keys(md)
    declared = declared_total(md)
    res = json.loads(results_path.read_text(encoding="utf-8"))
    used = placeholders(paper)
    errors, warnings = [], []
    if len(contract) != declared:
        errors.append(f"contract lists {len(contract)} keys but declares {declared}")
    secs = section_counts(md)
    for sec, dec, found in secs:
        if dec != found:
            errors.append(f"section {sec} declares {dec} keys but lists {found}")
    if sum(f for _, _, f in secs) != len(contract):
        errors.append(f"sections list {sum(f for _, _, f in secs)} keys, the contract {len(contract)}")
    if set(res) - contract:
        errors.append(f"results.json keys not in contract: {sorted(set(res) - contract)}")
    if contract - set(res):
        errors.append(f"contract keys missing from results.json: {sorted(contract - set(res))}")
    if used - contract:
        errors.append(f"manuscript placeholders not in contract: {sorted(used - contract)}")
    for k, v in sorted(res.items()):
        if not isinstance(v.get("display"), str) or not v["display"].strip():
            errors.append(f"{k}: empty display")
    pend = pending_by_script(res)
    n_pend = sum(pend.values())
    print(f"contract {len(contract)} keys (declared {declared}; {len(secs)} sections); results.json {len(res)}; "
          f"manuscript files {', '.join(E_NAMES)} use {len(used)} ({len(contract - used)} contract keys not used yet)")
    print(f"checked {results_path.name}")
    print(f"pending keys: {n_pend}" + (f" ({', '.join(f'{s}: {n}' for s, n in sorted(pend.items()))})" if n_pend else ""))
    if n_pend and results_path.name == "results.json":
        errors.append(f"results.json holds {n_pend} pending displays (a pending assembly goes to the git-ignored "
                      "results.pending.json; rerun models/E/run_all.R without --allow-pending when the steps have finished)")
    elif n_pend and allow_pending:
        warnings.append(f"{n_pend} pending displays accepted (--allow-pending); {results_path.name} is git-ignored and "
                        "never committed")
    elif n_pend:
        errors.append(f"{n_pend} pending displays (rerun models/E/run_all.R when the steps have finished, or pass "
                      "--allow-pending to report them only)")
    for w in warnings:
        print("WARN:", w)
    for e in errors:
        print("FAIL:", e)
    if errors:
        return 1
    print(f"OK: {results_path.name} matches the contract key set exactly")
    if build:
        if str(REPO) not in sys.path:
            sys.path.insert(0, str(REPO))
        from tools import build_manuscript as bm
        for p in bm.build(paper, results_path=results_path, names=E_NAMES):
            print("wrote", p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
