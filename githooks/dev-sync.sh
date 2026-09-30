#!/usr/bin/env sh
# ============================================================================
# Orca dev 동기화 훅 본체 — 4개 훅이 이 파일 하나를 모드 인자로 호출한다.
# ----------------------------------------------------------------------------
# 트리거는 "dev 에 머지되는 순간" 하나다. feature 브랜치 커밋은 아무것도 돌리지
# 않는다 ([done] 은 dev 세션에게 보내는 선언일 뿐, 트리거가 아니다).
#
#   git merge 가 충돌 없이 커밋까지 만드는 경로
#     pre-merge-commit  -> gate          verify.sh. 실패면 머지 커밋 안 만듦
#     post-merge        -> report        보고서 + 큐
#
#   충돌 -> 사람이 해결 -> git commit 경로 (git 이 위 두 훅을 안 띄운다)
#     pre-commit        -> gate-commit   MERGE_HEAD 있을 때만 verify.sh
#     post-commit       -> report-commit HEAD 부모 2개일 때만 보고서 + 큐
#
# 그냥 dev 직접 커밋(docs·e2e 수정)은 아무것도 안 한다 — 사소한 변경이라 판단.
#
# dev -> 다른 워크트리 전파는 하지 않는다. 워크트리 수명 = 티켓 수명이라 드리프트가
# 생길 창이 짧고, 새 워크트리는 항상 최신 dev 에서 만들어진다. 동시에 도는 티켓이
# 실제로 겹치면 그때 손으로: git -C <워크트리> merge dev
#
# 전제:
#   - dev(통합 브랜치)가 별도 git worktree 로 체크아웃돼 있을 것
#   - dev 워크트리에 merge.ff=false — ff 머지는 pre-merge-commit 을 건너뛴다(게이트 우회)
#       git -C <dev워크트리> config merge.ff false
#   - git config core.hooksPath <이 폴더 절대경로>   # repo 안에서 1회
#   확인: sh dev-sync.sh --selftest
# ============================================================================
set -u   # 정의 안 된 변수 쓰면 에러 (오타 방지)

# ------------------------------ CONFIG (수정) -------------------------------
DEV_BRANCH=dev                    # 통합 브랜치 이름 (main / develop 등)
# 브랜치 이름 규칙에는 의존하지 않는다 — Orca 가 `fix/x` 를 `fix-x` 로 만들기도 한다.
# 훅이 보는 것은 "지금 브랜치가 DEV_BRANCH 인가" 하나뿐.
# 머지 후 리뷰 보고서 (게이트 아님 — 게이트는 verify.sh 하나뿐)
CLAUDE_BIN=@@CLAUDE_BIN@@ # 절대경로 필수 (훅은 로그인 셸 아님). install.sh 가 채운다
# 티켓별 산출물 루트 (dev 워크트리 기준 상대경로).
#   <TICKET_DIR>/queue.md                 = 유일한 인덱스. verify 통과 + 머지 완료분만
#       한 줄 형식: - [브랜치](링크) 시각 — <spec.html 의 h1>
#       제목이 없으면 첫 커밋 제목으로 대신한다 (브랜치명만으로는 무슨 작업인지 안 보인다)
#   <TICKET_DIR>/<slug>/verify-<sha>.log  = 기계 검증 (통과/실패 둘 다, sha별 누적)
#   <TICKET_DIR>/<slug>/review-<sha>.html = 라운드 리뷰 (머지 성공 시만). close 때 rounds/ 로 이동
#   <TICKET_DIR>/<slug>/review.html       = 티켓 종합 (close 때 1회. 라운드 리뷰들을 접은 최종본)
#       보고서도 스펙과 같은 HTML 한 장이다 — 사람이 브라우저에서 열어 체크하며 읽는다
#   <TICKET_DIR>/.verify-line             = gate -> report 로 넘기는 기계층 한 줄
TICKET_DIR=.tickets
# ---------------------------------------------------------------------------

SELF_DIR=$(cd "$(dirname "$0")" && pwd)       # 이 파일이 있는 폴더
CONFLICT_LOG="$SELF_DIR/sync-conflicts.log"   # 충돌/스킵 기록 파일

# 훅 안에서 git 이 넘기는 환경변수 제거 (필수!)
# 안 지우면 GIT_INDEX_FILE/GIT_DIR 가 "지금 훅을 띄운 워크트리" 를 가리켜서
# 'git -C 다른워크트리 status/merge' 가 엉뚱한 인덱스를 봄 -> clean인데 dirty로 오판.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR GIT_NAMESPACE 2>/dev/null || true

VERIFY_LINE='verify: 실행 안 됨'   # 보고서 기계층 블록에 그대로 들어간다

# 브랜치 이름 -> 티켓 폴더 이름. dev 는 티켓이 아니라서 _dev 로 몰아둔다.
slug_of() {
  s=$(printf '%s' "$1" | tr '/' '-')
  [ "$s" = "$DEV_BRANCH" ] && s=_dev
  printf '%s' "$s"
}

# 커밋 $2 를 가리키는 로컬 브랜치 이름 (없으면 빈 값).
# 머지 커밋의 두 번째 부모/MERGE_HEAD 에서 "무엇을 머지했나" 를 얻는 데 쓴다.
branch_of() { # $1 워크트리  $2 커밋
  git -C "$1" name-rev --name-only --refs='refs/heads/*' "$2" 2>/dev/null \
    | sed 's/[~^].*//' | grep -v '^undefined$' || true
}

# 큐 한 줄에 붙일 작업 설명. 브랜치명(`fix-foo`)만으로는 무슨 작업이었는지 알 수 없고,
# 큐가 쌓이면 링크를 하나씩 열어봐야 한다. spec.html 의 <h1> 을 쓴다 — 사람이 붙인 이름이라
# 식별에 가장 좋고 새로 만들 것도 없다. 소제목(<h2>)은 태그가 달라 걸리지 않는다.
spec_title() { # $1 티켓디렉터리
  sed -n 's|.*<h1>\(.*\)</h1>.*|\1|p' "$1/spec.html" 2>/dev/null | head -1
}

# 머지 메시지에서 브랜치 이름 뽑기 (name-rev 가 못 찾을 때의 폴백)
branch_from_msg() { # $1 메시지
  printf '%s' "$1" | sed -n "s/^[Mm]erge branch '\([^']*\)'.*/\1/p" | head -1
}

# 사람에게 알림: 로그 파일에 기록 + Orca 워크트리 카드에 ⚠ 코멘트
notify() { # $1 대상경로  $2 메시지
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  printf '[%s] %s\n' "$ts" "$2" >> "$CONFLICT_LOG"
  orca worktree set --worktree "path:$1" --comment "⚠ $2" --json >/dev/null 2>&1 || true
}

# 보고서 머리. 라운드 리뷰·티켓 종합 둘 다 이걸로 연다 — 보고서는 브라우저에서 바로
# 열리는 HTML 한 장이다. 뒤에 기계층 블록과 LLM 출력이 조각으로 이어붙는다
# (닫는 태그는 없어도 된다 — 이어붙이기로 끝나는 파일이라 열어두는 편이 안전하다).
# 색은 --bg/--fg 로 못박는다. color-scheme 만 걸면 그 규칙을 안 따르는 뷰어에서
# 글자가 배경색에 묻혀 안 보인다.
report_head() { # $1 제목 한 줄  $2 부제(시각)
  cat <<HTML
<!doctype html>
<meta charset="utf-8">
<title>$1</title>
<style>
  :root { color-scheme: light dark; --bg: #fff; --fg: #1a1a1a; }
  @media (prefers-color-scheme: dark) { :root { --bg: #16181d; --fg: #e8e8e8; } }
  body { background: var(--bg); color: var(--fg);
         max-width: 46rem; margin: 3rem auto; padding: 0 1.5rem;
         font: 16px/1.75 -apple-system, system-ui, sans-serif; }
  h1 { font-size: 1.5rem; margin: 0 0 .3rem; }
  .when { opacity: .55; font-size: .85em; margin: 0 0 2rem; }
  section { border-top: 1px solid rgba(128,128,128,.3); margin-top: 2rem; padding-top: 1rem; }
  h2 { font-size: .9rem; letter-spacing: .04em; opacity: .6; margin: 0 0 .75rem; }
  h3 { font-size: .85rem; opacity: .8; margin: 1.2rem 0 .4rem; }
  ul { margin: 0; padding-left: 1.2rem; }
  li { margin-bottom: .4rem; }
  code { font-size: .9em; background: rgba(128,128,128,.18);
         padding: .1em .35em; border-radius: 3px; }
  .machine { border-left: 3px solid #3b82f6; padding-left: 1rem; border-top: none; }
  .check { list-style: none; padding-left: 0; }
  .check input { margin-right: .4rem; }
</style>

<h1>$1</h1>
<p class="when">$2</p>
HTML
}

# 머지 게이트. 워크트리 $1 에서 verify.sh 를 돌리고 종료코드로 판정한다.
# 통과 0 / 실패 1.  verify.sh 가 없으면 통과로 친다 (없는 프로젝트도 있다 —
# 전부 갖춘 뒤 켜려 하면 시작을 못 한다).
run_verify() { # $1 워크트리  $2 라벨(브랜치)  $3 티켓디렉터리  $4 로그이름용 커밋
  wt="$1"; br="$2"; tdir="$3"; sha="$4"
  if [ ! -x "$SELF_DIR/verify.sh" ]; then
    VERIFY_LINE='verify: 건너뜀 (verify.sh 없음 — 기계 검증 안 함)'
    return 0
  fi
  mkdir -p "$tdir"
  # sha 별로 남긴다 — 재요청을 반복할 때 실패 이력이 덮이지 않아야 한다.
  # (실패는 queue.md 에 올리지 않는다. 큐 = 통과 + 머지 완료 라는 근거를 지킨다)
  vlog="$tdir/verify-$(git -C "$wt" rev-parse --short "$sha").log"
  if (cd "$wt" && "$SELF_DIR/verify.sh") > "$vlog" 2>&1; then
    VERIFY_LINE="verify: 통과 — $(basename "$vlog")"
    return 0
  fi
  VERIFY_LINE="verify: 실패 — $vlog"
  notify "$wt" "verify 실패: $br — 머지 안 함. 로그: $vlog"
  return 1
}

# diff before..after 를 읽기전용 리뷰 에이전트에 물려 보고서 남기고 큐에 등록.
# 게이트 아님 — 리뷰 실패해도 머지는 유지. 기계층(VERIFY_LINE 전역)은 훅이 쓴다.
review_range() { # $1 dev워크트리  $2 before  $3 after  $4 라벨(브랜치)
  devwt="$1"; before="$2"; after="$3"; src="$4"
  rdir="$devwt/$TICKET_DIR"; mkdir -p "$rdir"
  [ "$before" = "$after" ] && return 0        # diff 없음 = 리뷰할 것 없음
  if [ ! -x "$CLAUDE_BIN" ]; then
    notify "$devwt" "CLAUDE_BIN 없음($CLAUDE_BIN) — 리뷰 생략, 머지는 됨"
    return 0
  fi
  # 산출물은 티켓 폴더 안, 인덱스(queue.md)는 루트 하나. 큐가 dev 전체를 대표해야 한다.
  slug=$(slug_of "$src")
  mkdir -p "$rdir/$slug"
  fname="$slug/review-$(git -C "$devwt" rev-parse --short "$after").html"
  # 큐 식별용 한 줄. spec.html 이 없는 경로(_dev 등)는 첫 커밋 제목으로 대신한다.
  desc=$(spec_title "$rdir/$slug")
  [ -n "$desc" ] || desc=$(git -C "$devwt" log "$before".."$after" --no-merges --pretty=%s | head -1)

  # 기계층 블록은 훅이 쓴다. LLM 이 못 건드려야 사실로 읽힌다.
  # (판단층과 섞이면 의견이 사실의 신뢰도를 빌려간다)
  {
    report_head "$src → $DEV_BRANCH" "$(date '+%Y-%m-%d %H:%M')"
    printf '<section class="machine">\n<h2>기계 검증</h2>\n<p>%s</p>\n</section>\n\n' "$VERIFY_LINE"
  } > "$rdir/$fname"

  # --allowedTools 는 가변인자라 뒤에 오는 positional(프롬프트)까지 삼킨다.
  # 프롬프트를 먼저, --allowedTools 를 맨 뒤에 둔다.
  if {
       printf '# 커밋 (%s)\n\n' "$src"
       git -C "$devwt" log "$before".."$after" --no-merges --pretty='- %s%n%b'
       printf '\n# diff\n\n'
       git -C "$devwt" diff "$before".."$after"
     } | (
       cd "$devwt" && "$CLAUDE_BIN" -p "$(cat "$SELF_DIR/reviewer-prompt.md")" \
         --allowedTools Read Grep Glob
     ) >> "$rdir/$fname" 2>>"$CONFLICT_LOG"; then
    # append 는 훅이 한다. 리뷰어에 Write 를 주면 코드도 고칠 수 있고
    # 그 순간 검증이 2차 구현이 된다.
    printf -- '- [%s](%s) %s — %s\n' "$src" "$fname" "$(date '+%m-%d %H:%M')" "$desc" \
      >> "$rdir/queue.md"
  else
    notify "$devwt" "리뷰 실패: '$src' (머지는 됨) — $TICKET_DIR/$fname 확인"
  fi
  return 0
}

# 티켓 종합. 라운드 리뷰 N개(review-<sha>.html)를 review.html 하나로 접는다.
# close 시점에만 돈다 — 그때가 티켓의 최종 상태이고, dev 워크트리가 최종 코드다.
# 라운드 원본은 rounds/ 로 옮겨 남긴다(기록은 지우지 않는다). 큐 줄도 티켓 1줄로 접는다.
do_consolidate() { # $1 브랜치
  here=$(git rev-parse --show-toplevel)
  br="$1"; slug=$(slug_of "$br")
  rdir="$here/$TICKET_DIR"; tdir="$rdir/$slug"
  [ -d "$tdir" ] || { echo "  종합 생략: 티켓 폴더 없음 ($TICKET_DIR/$slug)"; return 0; }
  # 생성 순 = 라운드 순 (sha 는 순서를 안 알려준다).
  # fresh = 아직 안 접은 라운드(폴더 직속) / prev = 지난 close 가 접어둔 이력(rounds/).
  # 재개된 티켓을 두 번째로 close 할 때 prev 를 입력에 넣지 않으면 종합이 앞 라운드를 잃는다.
  fresh=$(ls -tr "$tdir"/review-*.html 2>/dev/null || true)
  [ -n "$fresh" ] || { echo "  종합 생략: 접을 라운드 리뷰 없음 (이미 종합됨)"; return 0; }
  prev=$(ls -tr "$tdir"/rounds/review-*.html 2>/dev/null || true)
  rounds=$(printf '%s\n%s\n' "$prev" "$fresh" | grep -v '^$' || true)
  n=$(printf '%s\n' "$rounds" | wc -l | tr -d ' ')

  # 리뷰 훅이 큐에 append 하는 중일 수 있다 — 큐를 재작성하므로 같은 락을 잡는다.
  lock="$rdir/.lock"; waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    if [ "$waited" -ge 60 ]; then
      echo "  종합 생략: 리뷰 락 60초 초과 (다른 머지 리뷰가 도는 중) — 나중에 'dev-sync.sh consolidate $br'"
      return 0
    fi
    sleep 1; waited=$((waited + 1))
  done

  out="$tdir/review.html"
  # 기계층은 스크립트가 쓴다 (리뷰 보고서와 같은 원칙 — LLM 이 못 건드려야 사실로 읽힌다)
  {
    report_head "$br — 티켓 종합 (라운드 $n)" "$(date '+%Y-%m-%d %H:%M')"
    printf '<section class="machine">\n<h2>기계 검증 (라운드별)</h2>\n<ul>\n'
    i=0
    printf '%s\n' "$rounds" | while IFS= read -r f; do
      i=$((i + 1))
      # 마크업을 건너뛰고 한 줄만 집는다 — 훅이 <p> 안에 넣든 밖에 넣든 걸린다.
      v=$(grep -m1 -o 'verify: [^<]*' "$f" 2>/dev/null || true)
      [ -n "$v" ] || v='verify: 기록 없음'
      printf -- '<li>round %s: <code>rounds/%s</code> — %s</li>\n' "$i" "$(basename "$f")" "$v"
    done
    printf '</ul>\n</section>\n\n'
  } > "$out"

  ok=0
  if [ -x "$CLAUDE_BIN" ] && [ -r "$SELF_DIR/closing-prompt.md" ]; then
    # 입력 = 스펙 + 라운드 리뷰 전문. 현재 코드 확인은 프롬프트가 Read/Grep 으로 시킨다.
    if {
         printf '# 티켓 스펙\n\n'
         cat "$tdir/spec.html" 2>/dev/null || printf '(스펙 파일 없음)\n'
         printf '\n# 라운드 리뷰 (오래된 것부터)\n'
         printf '%s\n' "$rounds" | while IFS= read -r f; do
           # 머리(doctype·style)는 빼고 본문만 — 스타일 블록은 리뷰 재료가 아니다
           printf '\n## %s\n\n' "$(basename "$f")"; sed '1,/<\/style>/d' "$f"
         done
       } | (
         cd "$here" && "$CLAUDE_BIN" -p "$(cat "$SELF_DIR/closing-prompt.md")" \
           --allowedTools Read Grep Glob
       ) >> "$out" 2>>"$CONFLICT_LOG"; then
      ok=1
    fi
  fi
  if [ "$ok" = 0 ]; then
    # 종합이 안 되면 이어붙이기라도 한다 — 라운드 파일이 rounds/ 로 옮겨지므로 본문이 여기 남아야 한다.
    notify "$here" "종합 리뷰 생성 실패: $br — 라운드 리뷰를 이어붙였다 ($TICKET_DIR/$slug/review.html)"
    printf '<section>\n<h2>종합 실패 — 라운드 리뷰 원문</h2>\n' >> "$out"
    printf '%s\n' "$rounds" | while IFS= read -r f; do
      # 각 라운드도 완결된 HTML 이라 머리를 지우고 붙인다 (doctype 이 중첩되면 안 된다)
      printf '\n<h3>%s</h3>\n' "$(basename "$f")"; sed '1,/<\/style>/d' "$f"
    done >> "$out"
    printf '</section>\n' >> "$out"
  fi

  # 라운드 원본은 남긴다. 폴더 루트에는 review.html 하나만 보이게. (prev 는 이미 rounds/ 안이다)
  mkdir -p "$tdir/rounds"
  printf '%s\n' "$fresh" | while IFS= read -r f; do mv "$f" "$tdir/rounds/"; done

  # 큐: 같은 티켓의 라운드 줄들(링크가 rounds/ 로 이동해 깨졌다)을 종합 1줄로 교체.
  if [ -f "$rdir/queue.md" ]; then
    grep -v -- "]($slug/review-" "$rdir/queue.md" > "$rdir/queue.md.tmp" || true
    mv "$rdir/queue.md.tmp" "$rdir/queue.md"
    printf -- '- [%s](%s/review.html) 종합 %s라운드 %s — %s\n' \
      "$br" "$slug" "$n" "$(date '+%m-%d %H:%M')" "$(spec_title "$tdir")" \
      >> "$rdir/queue.md"
  fi

  rm -rf "$lock"
  # ${n} 로 감싼다 — sh 가 `$n건` 을 변수명 'n건' 으로 읽어 set -u 에 걸린다
  echo "  종합: $TICKET_DIR/$slug/review.html (라운드 ${n}건 → rounds/ 로 이동, 큐 1줄로 접힘)"
}

# ---------------------------- 모드 구현 ------------------------------------

# 게이트 본체. dev 워크트리에서 머지가 진행 중일 때만 돈다.
# 여기서 verify 하는 대상은 "머지 결과 트리" 다 — feature 브랜치에서만 통과하고
# 머지 후 깨지는 충돌은 이 위치에서만 잡힌다.
do_gate() {
  here=$(git rev-parse --show-toplevel)
  [ "$(git -C "$here" rev-parse --abbrev-ref HEAD)" = "$DEV_BRANCH" ] || return 0
  # ⚠ pre-merge-commit 시점엔 MERGE_HEAD·MERGE_MSG 가 아직 없다 (git 이 커밋할 때 쓴다).
  # 이 시점에 "무엇을 머지하는지" 아는 유일한 소스는 git merge 가 넣어주는 환경변수
  # GITHEAD_<머지대상sha>=<브랜치이름> 이다. (측정으로 확인 — 다른 경로는 다 빈손)
  gh=$(env | grep '^GITHEAD_' | head -1 || true)
  br=${gh#*=}; sha=${gh#GITHEAD_}; sha=${sha%%=*}
  if [ -z "$gh" ]; then
    # 충돌 해결 후 pre-commit 으로 들어온 경로 — 여기선 MERGE_HEAD 가 있다
    mh=$(git -C "$here" rev-parse --verify -q MERGE_HEAD || true)
    [ -n "$mh" ] && { sha=$mh; br=$(branch_of "$here" "$mh"); }
    [ -n "$br" ] || br=$(branch_from_msg "$(cat "$(git -C "$here" rev-parse --git-path MERGE_MSG)" 2>/dev/null || true)")
  fi
  [ -n "$br" ] || br=$DEV_BRANCH                      # 알 수 없으면 _dev 폴더에 기록
  [ -n "$sha" ] || sha=$(git -C "$here" rev-parse HEAD)
  if run_verify "$here" "$br" "$here/$TICKET_DIR/$(slug_of "$br")" "$sha"; then
    # 다음 훅(report)이 보고서 기계층에 그대로 쓴다
    printf '%s\n' "$VERIFY_LINE" > "$here/$TICKET_DIR/.verify-line"
    return 0
  fi
  echo "게이트 실패: verify 통과 못 함 — 머지 커밋 안 만든다."
  echo "  로그:      ${VERIFY_LINE#verify: 실패 — }"
  echo "  되돌리기:  git -C $here merge --abort"
  return 1
}

# 보고서 본체. before..after 를 리뷰하고 큐에 올린다.
do_report() { # $1 before  $2 after  $3 라벨
  here=$(git rev-parse --show-toplevel)
  rdir="$here/$TICKET_DIR"; lock="$rdir/.lock"
  mkdir -p "$rdir"
  # 리뷰 도는 중 dev 에 다른 머지가 들어오면 diff 는 A인데 파일은 A+B 라서 오진이 난다.
  # macOS 엔 flock 이 없어서 mkdir 의 원자성으로 락을 잡는다.
  waited=0
  while ! mkdir "$lock" 2>/dev/null; do
    if [ "$waited" -ge 300 ]; then
      notify "$here" "리뷰 락 300초 초과 — 강제 해제 (이전 훅이 죽었을 수 있음)"
      rm -rf "$lock"; continue
    fi
    sleep 1; waited=$((waited + 1))
  done
  trap 'rm -rf "$lock" 2>/dev/null || true' EXIT INT TERM

  # 기계층 한 줄은 gate 가 남긴 것을 쓴다. 없으면 게이트가 안 돈 경로다(사실대로 적는다).
  if [ -r "$rdir/.verify-line" ]; then
    VERIFY_LINE=$(cat "$rdir/.verify-line")
    rm -f "$rdir/.verify-line"
  else
    VERIFY_LINE='verify: 실행 안 됨 (게이트 훅이 돌지 않은 경로)'
  fi

  review_range "$here" "$1" "$2" "$3"

  rm -rf "$lock"; trap - EXIT INT TERM
}

# ------------------------------ 셀프 테스트 --------------------------------
if [ "${1:-}" = "--selftest" ]; then
  fail=0
  [ "$(slug_of 'feat/export-excel')" = "feat-export-excel" ] \
    || { echo "실패: slug_of 슬래시 변환"; fail=1; }
  [ "$(slug_of "$DEV_BRANCH")" = "_dev" ] \
    || { echo "실패: dev 는 _dev 로 가야 함"; fail=1; }
  [ "$(branch_from_msg "Merge branch 'fix/step-labels' into dev")" = "fix/step-labels" ] \
    || { echo "실패: branch_from_msg 파싱"; fail=1; }
  # spec_title: <h1> 만 뽑는다. <h2> 를 잡으면 큐 줄에 소제목이 들어간다
  st=$(mktemp -d)
  printf '<h1>결과 페이지 언어 전환</h1>\n<section><h2>목적</h2><p>화면이 바뀐다</p></section>\n' > "$st/spec.html"
  [ "$(spec_title "$st")" = "결과 페이지 언어 전환" ] \
    || { echo "실패: spec_title h1 추출"; fail=1; }
  [ -z "$(spec_title "$st/없는폴더")" ] \
    || { echo "실패: spec.html 없으면 빈 값이어야 함 (호출부가 커밋 제목으로 폴백한다)"; fail=1; }
  rm -rf "$st"
  # 보고서 HTML: 훅이 쓴 머리+기계층에서 종합이 verify 한 줄을 다시 집어내고,
  # 머리 잘라내기가 doctype 을 지우는가. 이 둘이 깨지면 종합 보고서가 조용히 망가진다.
  rt=$(mktemp -d)
  { report_head 'fix-x → dev' '2026-01-01 00:00'
    printf '<section class="machine">\n<h2>기계 검증</h2>\n<p>verify: 통과 — v.log</p>\n</section>\n'
  } > "$rt/review-abc.html"
  [ "$(grep -m1 -o 'verify: [^<]*' "$rt/review-abc.html")" = 'verify: 통과 — v.log' ] \
    || { echo "실패: 보고서에서 verify 줄 추출 (종합의 기계층이 빈다)"; fail=1; }
  if sed '1,/<\/style>/d' "$rt/review-abc.html" | grep -q '<!doctype'; then
    echo "실패: 머리 잘라내기 — 종합 보고서에 doctype 이 중첩된다"; fail=1
  fi
  rm -rf "$rt"
  # 훅 4개가 이 파일을 가리키고 실행 가능한가
  for h in pre-merge-commit pre-commit post-merge post-commit; do
    [ -x "$SELF_DIR/$h" ] || { echo "실패: 훅 없음/실행권한 없음 — $h"; fail=1; }
  done
  [ -x "$SELF_DIR/verify.sh" ] || echo "경고: verify.sh 없음/실행권한 없음 — 검증 없이 머지됨"
  [ -x "$CLAUDE_BIN" ] || { echo "실패: CLAUDE_BIN 실행 불가 — $CLAUDE_BIN"; fail=1; }
  [ -r "$SELF_DIR/reviewer-prompt.md" ] || { echo "실패: reviewer-prompt.md 없음"; fail=1; }
  [ -r "$SELF_DIR/closing-prompt.md" ] \
    || echo "경고: closing-prompt.md 없음 — close 시 종합이 이어붙이기로 폴백된다"
  # dev 워크트리 전제: 존재 + merge.ff=false (ff 머지는 게이트를 건너뛴다)
  d=$(git worktree list --porcelain | awk -v b="refs/heads/$DEV_BRANCH" '
        /^worktree /{p=substr($0,10)} $0=="branch "b{print p; exit}')
  if [ -z "$d" ]; then
    echo "실패: $DEV_BRANCH 워크트리 없음"; fail=1
  else
    mkdir -p "$d/$TICKET_DIR" 2>/dev/null || { echo "실패: $d/$TICKET_DIR 생성 불가"; fail=1; }
    [ "$(git -C "$d" config --get merge.ff)" = "false" ] \
      || { echo "실패: dev 워크트리에 merge.ff=false 없음 (ff 머지가 게이트를 우회한다)"; fail=1; }
  fi
  [ "$fail" = 0 ] && echo "selftest OK" || echo "selftest 실패"
  exit "$fail"
fi

# ------------------------------ 모드 디스패치 -------------------------------
mode=${1:-}
branch=$(git rev-parse --abbrev-ref HEAD)
here=$(git rev-parse --show-toplevel)

case "$mode" in
  gate)                       # pre-merge-commit: 충돌 없는 머지
    do_gate || exit 1
    ;;

  gate-commit)                # pre-commit: 충돌 해결 후 손으로 마치는 머지만
    [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] || exit 0
    do_gate || exit 1
    ;;

  report)                     # post-merge: 충돌 없는 머지가 커밋까지 끝난 뒤
    [ "$branch" = "$DEV_BRANCH" ] || exit 0
    p2=$(git rev-parse --verify -q HEAD^2) || exit 0    # 머지 커밋 아니면 볼 것 없음
    label=$(branch_of "$here" "$p2")
    [ -n "$label" ] || label=$(branch_from_msg "$(git log -1 --pretty=%s)")
    [ -n "$label" ] || label=$DEV_BRANCH   # 못 알아내면 _dev 폴더로 (slug_of 규칙)
    do_report "$(git rev-parse ORIG_HEAD)" "$(git rev-parse HEAD)" "$label"
    ;;

  report-commit)              # post-commit: dev 의 머지 커밋만 (그 외는 전부 통과)
    [ "$branch" = "$DEV_BRANCH" ] || exit 0
    # 부모 2개 = 충돌을 해결하고 손으로 만든 머지 커밋. 그 외 dev 직접 커밋은
    # 사소한 변경(docs·e2e 수정)이라 보고서를 만들지 않는다.
    p2=$(git rev-parse --verify -q HEAD^2) || exit 0
    label=$(branch_of "$here" "$p2")
    [ -n "$label" ] || label=$(branch_from_msg "$(git log -1 --pretty=%s)")
    [ -n "$label" ] || label=$DEV_BRANCH   # 못 알아내면 _dev 폴더로 (slug_of 규칙)
    do_report "$(git rev-parse HEAD^1)" "$(git rev-parse HEAD)" "$label"
    ;;

  consolidate)                # ticket.sh close 가 부른다 (훅 아님). 라운드 리뷰 → review.html 하나
    [ "$branch" = "$DEV_BRANCH" ] || { echo "consolidate 는 $DEV_BRANCH 워크트리에서만" >&2; exit 1; }
    [ -n "${2:-}" ] || { echo "사용: dev-sync.sh consolidate <브랜치>" >&2; exit 1; }
    do_consolidate "$2"
    ;;

  *) echo "사용: dev-sync.sh gate|gate-commit|report|report-commit|consolidate <브랜치>|--selftest" >&2; exit 1 ;;
esac
exit 0
