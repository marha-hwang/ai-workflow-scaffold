#!/bin/sh
# ============================================================================
# 티켓 라이프사이클 — dev 워크트리에서만 실행한다.
# ----------------------------------------------------------------------------
# 이 스크립트는 발사·머지·통지·정리만 한다. 판정은 없다.
#   게이트   = .githooks/verify.sh (하나뿐). 머지 시점에 pre-merge-commit 훅이 실행
#   리뷰     = post-merge 훅의 리뷰 에이전트 (읽기 전용, 게이트 아님)
#   계획     = 사람 + dev 세션 (자동 트리거를 붙이지 않는다)
#
# 사용:
#   ticket.sh new <feat/브랜치> <스펙파일>       워크트리 생성 + 작업 전달
#   ticket.sh wait [timeout_ms]                worker_done/escalation/decision_gate 대기 (기본 9분)
#   ticket.sh merge <브랜치>                   dev 로 머지 (훅이 verify → 보고서)
#   ticket.sh send <브랜치> <파일|텍스트>        재요청 (같은 워크트리, 브랜치 유지)
#   ticket.sh close <브랜치>                   워크트리 제거
#
# ⚠ 브랜치명은 orca 가 정규화한다: `new feat/x` 로 발사해도 실제 브랜치는 `feat-x` 다.
#   merge·send·close 는 **new 가 출력한 실제 이름**을 써라. new 가 달라지면 경고를 찍는다.
#
# 전제: Orca 런타임 실행 중 + Settings > Experimental 의 orchestration 활성
# ============================================================================
set -eu

REPO=name:@@REPO@@ # Orca 레포 이름. install.sh 가 채운다
SELF_DIR=$(cd "$(dirname "$0")" && pwd) # dev-sync.sh 와 같은 폴더 (close 가 종합을 위임한다)
DEV=$(git rev-parse --show-toplevel)   # dev 워크트리 (여기서만 실행한다)
TICKETS="$DEV/.tickets"

usage() {
  echo "ticket.sh new <feat/브랜치> <스펙파일> | wait [ms] | merge <브랜치> | send <브랜치> <텍스트> | close <브랜치>"
  exit 1
}

slug_of() { printf '%s' "$1" | tr / -; }

# orca CLI 실행 + 성공 판정. 성공이면 JSON 을 stdout 으로 넘기고, 실패면 이유를 stderr 에 찍고 죽는다.
# `--json` 은 이 함수가 붙인다 — 호출부에 쓰지 마라.
#
# 함정 둘을 여기 한 자리에서 막는다:
#   ① orca 는 실패 시 **exit 1 + {"ok":false}** 다(에러 JSON 도 stdout 으로 온다).
#      `set -e` 아래에서 그냥 `X=$(orca ...)` 하면 그 줄에서 **출력 한 줄 없이** 죽는다.
#   ② 반대로 `orca ... | jq -r ...` 로 받으면 파이프라인 종료코드가 jq 것(0)이라 **실패가 사라지고**
#      값만 "null" 이 되어 한참 뒤 엉뚱한 단계에서 터진다(워크트리는 이미 만들어진 채 남는다).
# 그래서 잡을 값은 항상 `X=$(orca_ok ...)` 로 받고, jq 는 그 다음 줄에서 별도로 돌린다.
#
# 진단은 **stderr** 로 낸다 — stdout 은 호출부가 $( ) 로 잡으므로 섞이면 JSON 이 깨진다.
# stderr 를 stdout 으로 병합하지 않는 이유도 그것이다: `orchestration check --wait` 는
# keepalive 를 stderr 로 흘리므로 병합하면 JSON 파싱이 깨진다.
orca_ok() {
  _out=$(orca "$@" --json) || true
  printf '%s' "$_out" | jq -e '.ok == true' >/dev/null 2>&1 || {
    echo "orca $1 $2 실패: $(printf '%s' "$_out" | jq -r '.error.code // empty' 2>/dev/null || true)" >&2
    printf '  응답: %s\n' "$(printf '%s' "$_out" | tr -d '\n' | head -c 300)" >&2
    case "$1 $2" in
      'worktree create')
        echo "  현재 설정: REPO=$REPO  (ticket.sh 상단)" >&2
        echo "  등록된 레포 이름 확인: orca repo list --json | jq -r '.result.repos[].displayName'" >&2 ;;
      'terminal wait')
        echo "  워커 TUI 가 제때 준비되지 않았다(dispatch 하면 프롬프트가 유실된다)." >&2
        echo "  ⚠ 워크트리는 **이미 만들어져 있다** — 'orca worktree ps --json' 으로 확인하고 close 하거나 다시 발사해라" >&2 ;;
    esac
    exit 1
  }
  printf '%s' "$_out"
}

# 브랜치 $1 워크트리의 에이전트 터미널 핸들.
#   `terminal list --worktree branch:<브랜치>` 는 어떤 형태로도 0건을 돌려준다(필터 미동작).
#   레코드에 agentType 필드도 없다 — 옛 구현이 두 가지 다 기대해서 send 가 항상 실패했다.
#   그래서 ①발사 때 적어둔 핸들을 쓰고 ②없으면 branch 로 직접 고른다(에이전트 터미널 = 제목이 ✳ 로 시작. Setup 터미널과 구분).
handle_of() {
  _saved=$(cat "$TICKETS/$(slug_of "$1")/terminal" 2>/dev/null || true)
  _all=$(orca_ok terminal list)
  if [ -n "$_saved" ] \
     && printf '%s' "$_all" | jq -e --arg h "$_saved" '.result.terminals[]|select(.handle==$h)' >/dev/null 2>&1; then
    printf '%s\n' "$_saved"
    return
  fi
  printf '%s' "$_all" | jq -r --arg br "$1" '
    [.result.terminals[] | select(.branch == "refs/heads/\($br)" or .branch == $br)]
    | (map(select((.title // "") | startswith("✳"))) + .)
    | .[0].handle // empty'
}

# **이 세션(dev)의** orchestration 핸들. 메일박스는 핸들 단위다 —
# `check` 를 --terminal 없이 부르면 어떤 메일박스도 열리지 않고 항상 count:0 이 온다.
# 그때 통지는 하네스가 턴 경계에 주입하는 경로로만 보여서, **사람이 ESC 를 누를 때까지 dev 가 안 깨어난다**
# (실제 사고: wait 가 9분씩 헛돌고, 그 사이 끝난 워커의 worker_done 이 쌓여 있었다).
# ORCA_PANE_KEY="<tabId>:<leafId>" 가 terminal list 레코드와 1:1 로 맞는다. 같은 브랜치에
# 터미널이 여러 개(dev 는 항상 그렇다)여도 이 키로는 하나로 정해진다.
self_handle() {
  _tl=$(orca_ok terminal list)
  printf '%s' "$_tl" | jq -r --arg k "${ORCA_PANE_KEY:-}" --arg t "${ORCA_TAB_ID:-}" '
    [ .result.terminals[]
      | select( ($k != "" and "\(.tabId):\(.leafId)" == $k)
                or ($k == "" and $t != "" and .tabId == $t) ) ]
    | .[0].handle // empty'
}

# 미읽음 통지를 비운다 — 발사·재요청 **직전에** 부른다.
# 하네스 주입 경로는 읽음 처리를 하지 않아서 옛 라운드의 worker_done 이 미읽음으로 남는다.
# 비우지 않으면 다음 wait 가 그 옛 통지를 즉시 물어와 "워커가 벌써 끝냈다"로 오독되고,
# 아직 돌고 있는 워커를 두고 merge 가 돌아간다 (= 다음 작업을 이어받아 버린다).
# 여기서만 orca_ok 를 쓰지 않는다 — 비우기는 **최선 노력**이다. 이것 때문에 발사가 막히면 안 된다.
drain_notices() {
  _me=$(self_handle)
  [ -n "$_me" ] || return 0
  _n=$(orca orchestration check --terminal "$_me" --types worker_done,escalation,decision_gate --json 2>/dev/null \
        | jq -r '.result.messages | length' 2>/dev/null || echo 0)
  case "${_n:-0}" in
    ''|0) : ;;
    *) echo "  (옛 통지 $_n 건을 비웠다 — 이번 라운드 통지만 wait 에 잡힌다)" ;;
  esac
}

case "${1:-}" in
new)
  BR=${2:-}; SPEC=${3:-}
  [ -n "$BR" ] && [ -n "$SPEC" ] || usage
  [ -r "$SPEC" ] || { echo "스펙 파일 없음: $SPEC"; exit 1; }

  # 발사 전에 메일박스를 비운다 — 옛 라운드의 미읽음 통지가 남아 있으면 첫 wait 가 그걸 물어온다.
  drain_notices

  # 워크트리를 **먼저** 만든다. task-create 를 앞에 두면 워크트리 생성이 실패할 때마다
  # 고아 task 레코드가 쌓인다(CLI 로 지우기도 어렵다). 실패할 수 있는 것을 먼저 한다.
  # base=dev, lineage=top-level. 워크트리 수명 = 티켓 수명이라 dev 와 벌어질 틈이 없다.
  W=$(orca_ok worktree create --repo "$REPO" --name "$BR" \
        --base-branch dev --no-parent --agent claude)
  H=$(printf '%s' "$W" | jq -r '.result.agentTerminalHandle // .result.startupTerminal.handle // empty')
  [ -n "$H" ] || { echo "에이전트 핸들 못 찾음: $W"; exit 1; }

  # 티켓 = 작업 단위. 스펙 본문이 그대로 dispatch 프롬프트가 된다.
  # jq 는 orca_ok 다음 줄에서 따로 돈다 — 파이프로 이으면 실패가 종료코드에서 사라진다(orca_ok 주석 ②).
  TJ=$(orca_ok orchestration task-create --spec "$(cat "$SPEC")" --task-title "$BR")
  T=$(printf '%s' "$TJ" | jq -r '.result.task.id // empty')
  [ -n "$T" ] || { echo "task id 없음: $TJ"; exit 1; }

  # TUI 준비 전에 dispatch 하면 프롬프트가 유실된다
  orca_ok terminal wait --terminal "$H" --for tui-idle --timeout-ms 60000 >/dev/null
  # --inject 프리앰블이 worker_done 규칙을 주입한다 (CLAUDE.md 수정 불필요)
  orca_ok orchestration dispatch --task "$T" --to "$H" --inject >/dev/null

  # orca 가 브랜치명을 정규화한다: `feat/x` 로 발사해도 실제 브랜치는 `feat-x` 다.
  # 이후 merge·close 는 **실제** 브랜치명을 써야 하므로 여기서 확정해 출력한다(요청명으로 merge 하면 브랜치를 못 찾는다).
  ACTUAL=$(orca terminal list --json \
    | jq -r --arg h "$H" '.result.terminals[]|select(.handle==$h)|.branch // empty' \
    | sed 's|^refs/heads/||' | head -1)
  [ -n "$ACTUAL" ] || ACTUAL=$BR

  # 티켓 산출물은 한 폴더에 모인다: spec.html + verify-<sha>.log + review-<sha>.html (훅이 씀)
  # 폴더명은 실제 브랜치 기준 — 훅도 실제 브랜치로 슬러그를 뽑으므로 여기서 어긋나면 보고서가 다른 폴더에 떨어진다.
  TDIR="$TICKETS/$(slug_of "$ACTUAL")"
  mkdir -p "$TDIR"
  # 스펙을 이미 티켓 폴더에 써둔 경우 cp 가 "same file" 로 실패한다 (set -e 라 그대로 죽음)
  [ "$(cd "$(dirname "$SPEC")" && pwd)/$(basename "$SPEC")" = "$TDIR/spec.html" ] \
    || cp "$SPEC" "$TDIR/spec.html"
  # 핸들을 남긴다 — send(재요청)가 터미널을 추측하지 않게. 워크트리가 살아있는 동안만 유효하다.
  printf '%s\n' "$H" > "$TDIR/terminal"
  echo "발사: $ACTUAL  task=$T  terminal=$H  산출물=$TDIR"
  [ "$ACTUAL" = "$BR" ] || echo "  ⚠ 브랜치명이 정규화됐다: 요청 '$BR' → 실제 '$ACTUAL'. merge·close 는 '$ACTUAL' 로 해라"
  ;;

wait)
  # 화면을 안 봐도 완료 시점에 깨어난다 (병목 6 대응).
  # worker_done 은 "구현 끝났다"는 선언일 뿐이다 — verify·보고서는 아직 없다.
  # 판정은 이 다음 단계인 `ticket.sh merge` 에서 훅이 한다.
  # 빈손 복귀는 실패가 아니라 체크포인트 — 다시 wait 한다.
  # 기본 9분: Claude Code Bash 도구 상한(10분)보다 짧게 잡는다.
  # decision_gate 도 받는다 — 빼면 워커 질문에 dev 가 안 깨어나고, 그 질문은 orca 가 임의 시점에
  # 세션으로 밀어넣는 경로로만 보이게 된다(도착 순서가 worker_done 뒤로 밀려 "죽은 워커에게 답장"이 된다).
  # --terminal 은 **필수**다. 빼면 메일박스가 안 열려 항상 빈손이고(self_handle 주석 참고)
  # 통지는 사람이 ESC 를 눌러 턴을 끊을 때까지 안 보인다.
  ME=$(self_handle)
  [ -n "$ME" ] || {
    echo "이 터미널의 orchestration 핸들을 못 찾았다 — wait 를 돌려도 없는 메일박스를 폴링한다(빈손 무한 반복)."
    echo "  ORCA_PANE_KEY=${ORCA_PANE_KEY:-<없음>}  ORCA_TAB_ID=${ORCA_TAB_ID:-<없음>}"
    echo "  Orca 가 띄운 터미널에서 실행해야 한다. 확인: orca terminal list --json | jq '.result.terminals[]|{handle,tabId,leafId}'"
    exit 1; }
  # 타임아웃(빈손)은 {"ok":true, count:0} 이라 orca_ok 를 통과한다 — 죽는 건 진짜 실패(핸들 오류 등)뿐이다.
  # keepalive 는 stderr 로 흐르므로 OUT 을 오염시키지 않는다(orca_ok 가 stderr 를 병합하지 않는 이유).
  OUT=$(orca_ok orchestration check --wait --terminal "$ME" --types worker_done,escalation,decision_gate \
          --timeout-ms "${2:-540000}")
  printf '%s\n' "$OUT"
  # 빈손 복귀와 통지 도착이 둘 다 exit 0 + 비슷한 JSON 이라 "끝났다"로 오독된다 → 한 줄로 못을 박는다.
  N=$(printf '%s' "$OUT" | jq -r '.result.count // 0')
  if [ "${N:-0}" -gt 0 ] 2>/dev/null; then
    TYPES=$(printf '%s' "$OUT" | jq -r '[.result.messages[].type] | unique | join(",")')
    echo "통지 $N 건 [$TYPES] — body 에서 브랜치·커밋 sha·[done] 여부만 취한다. 다음은 merge(판정)"
    case "$TYPES" in *decision_gate*|*escalation*)
      echo "  ⚠ 질문/막힘 통지가 섞여 있다. 답은 'ticket.sh send <브랜치> <파일>' 로 보낸다"
      echo "     'orca orchestration reply' 를 쓰지 마라 — 워커 턴이 이미 끝났으면(worker_done 이후) 답이 전달되지 않고 wait 가 영원히 빈손이 된다" ;;
    esac
  else
    echo "통지 없음(타임아웃) — 실패가 아니다. 다시 wait 하라. 머지하지 마라"
    echo "  단 2회 연속 빈손이면 워커가 멈춘 것이다: 'git log -1 <브랜치>' 로 커밋 진척을 보고, 안 늘었으면 'ticket.sh send' 로 지시를 다시 보낸다"
  fi
  ;;

merge)
  BR=${2:-}; [ -n "$BR" ] || usage
  SLUG=$(slug_of "$BR")
  # dev 워크트리는 티켓들이 공유한다 — 다른 머지가 진행 중이면 git 이 즉시 거부하고,
  # 그 실패가 아래 폴백에서 "게이트 실패"로 잘못 보고됐다(verify 는 돌지도 않았다). 먼저 끊는다.
  if git -C "$DEV" rev-parse --verify -q MERGE_HEAD >/dev/null 2>&1; then
    echo "머지 미완결(MERGE_HEAD 존재) — 게이트 문제가 아니다. 다른 머지가 진행 중이거나 중단됐다."
    echo "  해결: 충돌 해결 후 'git -C $DEV commit'  또는  'git -C $DEV merge --abort'"
    exit 1
  fi
  git -C "$DEV" rev-parse --verify -q "$BR" >/dev/null 2>&1 \
    || { echo "브랜치 없음: $BR  (발사 시 정규화된 이름을 써라 — 'git -C $DEV branch --list' 로 확인)"; exit 1; }
  # 판정은 훅이 한다: pre-merge-commit(verify.sh) → post-merge(보고서·큐).
  # --no-ff 고정 — ff 머지는 pre-merge-commit 을 건너뛰어 게이트가 우회된다.
  SHA=$(git -C "$DEV" rev-parse --short "$BR")
  if git -C "$DEV" merge --no-ff --no-edit "$BR"; then
    echo "머지 완료: $BR  (보고서: $TICKETS/$SLUG/)"
    exit 0
  fi
  # 실패 원인이 둘이라 구분해야 한다: 파일 충돌은 사람 차례, 게이트 실패는 되돌린다.
  if [ -n "$(git -C "$DEV" diff --name-only --diff-filter=U)" ]; then
    echo "충돌 — 아래 파일 해결 후 'git -C $DEV commit'. 그때 pre-commit 게이트가 verify 를 돈다:"
    git -C "$DEV" diff --name-only --diff-filter=U | sed 's/^/  /'
    exit 1
  fi
  git -C "$DEV" merge --abort 2>/dev/null || true
  # 게이트가 실제로 돌았는지는 verify-<브랜치팁 sha>.log 존재로만 말할 수 있다. 없으면 머지를 시작조차 못 한 것이다.
  if [ -f "$TICKETS/$SLUG/verify-$SHA.log" ]; then
    echo "게이트 실패 — 머지 취소됨. verify 로그: $TICKETS/$SLUG/verify-$SHA.log"
  else
    echo "머지를 시작하지 못했다 — 게이트 실패가 아니다(verify 로그 없음). 위 git 메시지가 원인이다."
  fi
  exit 1
  ;;

send)
  BR=${2:-}; [ -n "$BR" ] || usage
  shift 2
  [ -n "${1:-}" ] || usage
  H=$(handle_of "$BR")
  [ -n "$H" ] || { echo "에이전트 터미널 없음: $BR  (이미 close 됐거나 브랜치명이 다르다 — 'orca terminal list --json | jq .result.terminals[].branch')"; exit 1; }
  # 재요청도 발사와 같은 경로(task-create → dispatch --inject)를 쓴다.
  #   옛 구현은 `terminal send`(TUI 에 타이핑)였다 — 여러 줄 재요청은 빈 줄에서 조기 전송돼 앞부분만 들어간다.
  #   --inject 는 worker_done 규칙을 다시 주입한다. 재요청 결과도 통지로 돌아와야 dev 가 깨어난다.
  # 인자가 읽을 수 있는 파일이면 그 내용을, 아니면 나머지 인자 전체를 본문으로 쓴다(긴 재요청은 파일이 안전).
  if [ -f "$1" ] && [ -r "$1" ]; then BODY=$(cat "$1"); else BODY=$*; fi
  # 이 라운드 통지만 다음 wait 에 잡히게 — 직전 라운드 worker_done 이 미읽음으로 남아 있다.
  drain_notices
  TJ=$(orca_ok orchestration task-create --spec "$BODY" --task-title "재요청: $BR")
  T=$(printf '%s' "$TJ" | jq -r '.result.task.id // empty')
  [ -n "$T" ] || { echo "task id 없음: $TJ"; exit 1; }
  orca_ok terminal wait --terminal "$H" --for tui-idle --timeout-ms 60000 >/dev/null
  orca_ok orchestration dispatch --task "$T" --to "$H" --inject >/dev/null
  echo "재요청 전달: $BR  task=$T  terminal=$H  (다음: wait → merge)"
  ;;

close)
  BR=${2:-}; [ -n "$BR" ] || usage
  # 워크트리만 제거한다. .tickets/<slug>/ 는 남긴다 — 스펙·검증·보고서가 티켓 기록이다
  # orca_ok 를 쓰지 않는다: 이미 제거된 워크트리를 close 하는 것은 정상 흐름(재실행·수동 정리 후)이고,
  # 여기서 죽으면 아래 종합(review.html)이 돌지 않는다. 실패해도 안내만 하고 넘어간다.
  if orca worktree rm --worktree "branch:$BR" --json; then
    echo "워크트리 제거: $BR  (기록 유지: $TICKETS/$(slug_of "$BR")/)"
  else
    echo "  ⚠ 워크트리 제거 실패(이미 없을 수 있다) — 'orca worktree ps --json' 확인. 종합은 계속한다"
  fi
  rm -f "$TICKETS/$(slug_of "$BR")/terminal"   # 핸들은 워크트리와 함께 죽는다. 남기면 다음 티켓이 죽은 핸들을 집는다
  # 라운드 리뷰 N개 → review.html 하나. 워크트리를 없앤 뒤에 도는 이유: 지금 dev 가 티켓의 최종 코드다.
  # 종합이 실패해도 close 는 실패가 아니다(워크트리는 이미 제거됐다) — 안내만 하고 넘어간다.
  sh "$SELF_DIR/dev-sync.sh" consolidate "$BR" || echo "  ⚠ 종합 실패 — 'sh $SELF_DIR/dev-sync.sh consolidate $BR' 로 다시 시도"
  ;;

*) usage ;;
esac
