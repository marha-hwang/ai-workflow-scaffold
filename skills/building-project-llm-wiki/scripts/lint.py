#!/usr/bin/env python3
"""프로젝트 LLM 위키 lint. 레포 루트에서 `python3 docs/lint.py`로 실행한다. 문제가 있으면 종료 코드 1.
building-project-llm-wiki 스킬의 scripts/lint.py를 docs/lint.py로 복사하고 아래 설정 상수만 프로젝트에 맞춘다.

1. index.md, wiki/**, LINKED_RAW 아래 md의 상대 링크가 실제 파일을 가리키는가
   (EXCLUSIONS 파일에 적힌 "일부러 뺀 파일"로 가는 링크는 뺀다)
2. wiki/**의 모든 페이지가 index.md에 올라 있는가
3. 페이지 `sources:`의 경로가 존재하는가
4. 원천(docs/raw)에 ingest 뒤 바뀐 파일이 있는가, 그 파일을 근거로 쓰는 위키 페이지는 어디인가

원천 파일의 ingest 시점 상태는 docs/ingested.json(경로 → sha256)에 있다.

  --pending          4번만 보고, 대기 건이 있을 때만 출력한다 (UserPromptSubmit 훅용)
  --mark <경로>...    ingest를 마친 파일·폴더의 현재 상태를 대장에 기록한다
"""
import hashlib, json, re, sys, tempfile, unicodedata, urllib.parse
from pathlib import Path

# ── 설정: 프로젝트마다 여기만 바꾼다 ──────────────────────────────
ROOT = Path(__file__).resolve().parent.parent  # 레포 루트 (이 파일은 docs/lint.py)
WATCH = ("docs/raw",)            # 원천. 대장이 해시를 추적한다
LEDGER = "docs/ingested.json"    # 원천 해시 대장
LINKED_RAW = ()                  # 링크까지 검사할 raw 하위 폴더. 레포 전체 링크 검사가 docs/를 건너뛸 때 채운다
EXCLUSIONS = None                # [{"path": ...}] JSON. 일부러 뺀 파일로 가는 링크를 깨진 링크에서 제외
# ──────────────────────────────────────────────────────────────────
# 매번 전 파일을 sha256으로 읽는다(원천 1,000개·150MB에 0.3초 안팎). 느려지면 (size, mtime) 캐시를 앞에 둔다


def nfc(s):
    return unicodedata.normalize("NFC", s)


def front(text):
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        return None, []
    body = m.group(1)
    updated = re.search(r"^updated:\s*(\S+)", body, re.M)
    sources = [nfc(s) for s in re.findall(r"^\s+-\s+(.+?)\s*$", body, re.M)]
    return (updated.group(1) if updated else None), sources


def links(text):
    for t in re.findall(r"\[[^\]]*\]\(([^)]+)\)", text):
        if not re.match(r"[a-z]+:|#", t):
            yield urllib.parse.unquote(t.split("#", 1)[0])


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def watched(root):
    for w in WATCH:
        for f in sorted((root / w).rglob("*")):
            if f.is_file() and not f.name.startswith("."):
                yield nfc(f.relative_to(root).as_posix()), f  # 한글 파일명: macOS 사본은 NFD, git은 NFC


def load_ledger(root):
    p = root / LEDGER
    return {nfc(k): v for k, v in json.loads(p.read_text(encoding="utf-8")).items()} if p.exists() else {}


def pending(root=ROOT):
    """(상태, 경로) 목록. 상태: 새 파일 · 수정 · 삭제"""
    ledger = load_ledger(root)
    current = dict(watched(root))
    out = [("새 파일" if rel not in ledger else "수정", rel)
           for rel, f in current.items() if ledger.get(rel) != sha(f)]
    out += [("삭제", rel) for rel in ledger if rel not in current]
    return sorted(out, key=lambda x: x[1])


def mark(paths, root=ROOT):
    ledger = load_ledger(root)
    targets = [(root / p).resolve() for p in paths]
    current = dict(watched(root))
    for rel, f in current.items():
        if any(f.resolve() == t or t in f.resolve().parents for t in targets):
            ledger[rel] = sha(f)
    for rel in [r for r in ledger if r not in current]:
        if any((root / rel).resolve() == t or t in (root / rel).resolve().parents for t in targets):
            del ledger[rel]
    (root / LEDGER).write_text(json.dumps(dict(sorted(ledger.items())), ensure_ascii=False, indent=0) + "\n", encoding="utf-8")


def pages_citing(rel, root=ROOT):
    docs = root / "docs"
    hits = []
    for f in sorted((docs / "wiki").rglob("*.md")):
        _, sources = front(f.read_text(encoding="utf-8"))
        if any(rel == s.rstrip("/") or rel.startswith(s.rstrip("/") + "/") for s in sources):
            hits.append(f.relative_to(docs).as_posix())
    return hits


def excluded_names(root, exclusions=None):
    exclusions = exclusions or EXCLUSIONS
    p = root / exclusions if exclusions else None
    if not p or not p.exists():
        return set()
    items = json.loads(p.read_text(encoding="utf-8"))
    items = items.get("items", items) if isinstance(items, dict) else items
    return {Path(i["path"]).name for i in items if isinstance(i, dict) and "path" in i}


def lint(root=ROOT, linked_raw=None, exclusions=None):
    docs = root / "docs"
    problems = []
    pages = sorted((docs / "wiki").rglob("*.md"))
    index = (docs / "index.md").read_text(encoding="utf-8")
    skip = excluded_names(root, exclusions)
    for d in (LINKED_RAW if linked_raw is None else linked_raw):
        for f in sorted((root / d).rglob("*.md")) if (root / d).exists() else []:
            for t in links(f.read_text(encoding="utf-8", errors="ignore")):
                if Path(t).name not in skip and not (f.parent / t).exists():
                    problems.append(f"깨진 링크: {f.relative_to(root)} → {t}")
    for f in [docs / "index.md", *pages]:
        text = f.read_text(encoding="utf-8")
        for t in links(text):
            if not (f.parent / t).exists():
                problems.append(f"깨진 링크: {f.relative_to(root)} → {t}")
        if f == docs / "index.md":
            continue
        rel = f.relative_to(docs).as_posix()
        if f"({rel})" not in index:
            problems.append(f"index 누락: {rel}")
        updated, sources = front(text)
        if not updated:
            problems.append(f"머리말 없음: {rel}")
        for s in sources:
            if not (root / s).exists():
                problems.append(f"없는 근거: {rel} → {s}")
    return problems


def report_pending(root=ROOT):
    lines = []
    for state, rel in pending(root):
        cited = pages_citing(rel, root)
        lines.append(f"- [{state}] {rel}" + (f" → 다시 대조할 페이지: {', '.join(cited)}" if cited else ""))
    return lines


def selfcheck():
    with tempfile.TemporaryDirectory() as d:
        r = Path(d); w = r / "docs" / "wiki"; w.mkdir(parents=True)
        raw = r / "docs" / "raw"; raw.mkdir()
        (raw / "source-docs").mkdir(); (raw / "08_MANIFEST").mkdir()
        (raw / "08_MANIFEST" / "EXCLUSIONS.json").write_text('[{"path": "docs/x/secret.md"}]')
        (raw / "source-docs" / "s.md").write_text("[ok](../a.md) [gone](missing.md) [excluded](secret.md)")
        (raw / "a.md").write_text("x"); (raw / "b.md").write_text("x")
        (r / "docs" / "index.md").write_text("[a](wiki/a.md)")
        (w / "a.md").write_text("---\nupdated: 2000-01-01\nsources:\n  - docs/raw\n  - gone.md\n---\n[x](nope.md)")
        (w / "b.md").write_text("no front")
        p = lint(r, linked_raw=("docs/raw/source-docs",), exclusions="docs/raw/08_MANIFEST/EXCLUSIONS.json")
        assert any("깨진 링크" in x and "nope.md" in x for x in p), p
        assert any("없는 근거" in x and "gone.md" in x for x in p), p
        assert "index 누락: wiki/b.md" in p and "머리말 없음: wiki/b.md" in p, p
        assert "깨진 링크: docs/raw/source-docs/s.md → missing.md" in p, p
        assert not any("secret.md" in x or "../a.md" in x for x in p), p
        new = [x for x in pending(r) if x[1] in ("docs/raw/a.md", "docs/raw/b.md")]
        assert new == [("새 파일", "docs/raw/a.md"), ("새 파일", "docs/raw/b.md")], pending(r)
        mark(["docs/raw"], r)
        assert pending(r) == [], pending(r)
        (raw / "a.md").write_text("changed"); (raw / "b.md").unlink(); (raw / "c.md").write_text("x")
        assert pending(r) == [("수정", "docs/raw/a.md"), ("삭제", "docs/raw/b.md"), ("새 파일", "docs/raw/c.md")], pending(r)
        assert pages_citing("docs/raw/a.md", r) == ["wiki/a.md"]
        mark(["docs/raw/a.md"], r)
        assert pending(r) == [("삭제", "docs/raw/b.md"), ("새 파일", "docs/raw/c.md")], pending(r)
        mark(["docs/raw"], r)
        assert pending(r) == [], pending(r)
        # 대장이 NFD 키(macOS 사본)여도 NFC 파일명(git 사본)과 같은 파일로 본다
        (raw / nfc("한.md")).write_text("x"); (w / "a.md").write_text("---\nupdated: 2000-01-01\nsources:\n  - " + unicodedata.normalize("NFD", "docs/raw/한.md") + "\n---\n")
        (r / LEDGER).write_text(json.dumps({unicodedata.normalize("NFD", k): v for k, v in {**load_ledger(r), "docs/raw/한.md": sha(raw / "한.md")}.items()}, ensure_ascii=False))
        assert pending(r) == [], pending(r)
        assert pages_citing("docs/raw/한.md", r) == ["wiki/a.md"]


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--pending"]:
        lines = report_pending()
        if lines:
            print(f"[위키] 원천에 ingest 대기 {len(lines)}건. 사용자 요청을 처리하기 전에 CLAUDE.md의 Ingest(원천 변경) 절차로 먼저 반영한다:")
            print("\n".join(lines[:30]) + (f"\n- ... 외 {len(lines) - 30}건 (python3 docs/lint.py로 전체 확인)" if len(lines) > 30 else ""))
        sys.exit(0)
    if args[:1] == ["--mark"]:
        mark(args[1:] or list(WATCH))
        print(f"대장 기록 완료. ingest 대기 {len(pending())}건")
        sys.exit(0)
    selfcheck()
    problems = lint()
    waiting = report_pending()
    for line in problems:
        print(line)
    if waiting:
        print(f"ingest 대기 {len(waiting)}건:")
        print("\n".join(waiting))
    print(f"문제 {len(problems)}건, ingest 대기 {len(waiting)}건")
    sys.exit(1 if problems else 0)
