#!/usr/bin/env sh
# ============================================================================
# 티켓 워크플로 설치 — 다른 프로젝트에 이식할 때 이것만 돌린다.
#
#   sh install.sh <레포루트> <dev워크트리> <Orca레포이름> [훅폴더]
#
# 예:
#   sh install.sh ~/proj/myapp ~/proj/myapp-dev myapp
#
# 훅폴더 기본값 = <레포루트>/../.githooks (워크트리들을 담는 프로젝트 컨테이너 폴더).
# 부모 폴더를 여러 프로젝트가 공유하고 있으면 4번째 인자로 직접 지정한다.
#
# 하는 일 (전부 멱등 — 여러 번 돌려도 안전):
#   1) githooks/ 를 <레포루트>/../.githooks 로 복사 + 실행권한
#   2) CLAUDE_BIN·REPO 플레이스홀더 채움
#   3) git config core.hooksPath (절대경로) + dev 워크트리 merge.ff=false
#   4) dev 워크트리에 .tickets/ 생성 + .gitignore 에 한 줄
#   5) dev 워크트리에 skills/ 전부 + ticket.sh 권한 allowlist (있으면 건너뜀)
#   6) selftest
# ============================================================================
set -eu

SRC=$(cd "$(dirname "$0")" && pwd)
ROOT=${1:-}; DEVWT=${2:-}; ORCAREPO=${3:-}; HOOKS=${4:-}
[ -n "$ROOT" ] && [ -n "$DEVWT" ] && [ -n "$ORCAREPO" ] || {
  echo "사용: sh install.sh <레포루트> <dev워크트리> <Orca레포이름> [훅폴더]"; exit 1; }
[ -d "$ROOT/.git" ] || [ -f "$ROOT/.git" ] || { echo "git 레포 아님: $ROOT"; exit 1; }
[ -d "$DEVWT" ] || { echo "dev 워크트리 없음: $DEVWT"; exit 1; }
[ "$(git -C "$DEVWT" rev-parse --abbrev-ref HEAD)" = "dev" ] \
  || { echo "경고: $DEVWT 의 브랜치가 dev 가 아니다 — dev-sync.sh 의 DEV_BRANCH 를 맞춰라"; }

# Orca 레포 이름 검증 — 여기서 안 잡으면 첫 `ticket.sh new` 가 repo_not_found 로 죽는다.
# 3번째 인자는 **Orca 에 등록된 레포의 displayName** 이다. 워크트리 이름도, 브랜치 이름도 아니다.
# (실제로 dev 워크트리 이름을 넣어 발사가 세 번 실패한 사례가 있다 — 에러도 안 보였다)
if command -v orca >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  NAMES=$(orca repo list --json 2>/dev/null | jq -r '.result.repos[]?.displayName' || true)
  if [ -n "$NAMES" ]; then
    printf '%s\n' "$NAMES" | grep -qxF "$ORCAREPO" || {
      echo "Orca 에 '$ORCAREPO' 레포가 없다 — 지금 멈춘다(안 멈추면 첫 발사에서 repo_not_found)."
      echo "등록된 레포 이름:"
      printf '%s\n' "$NAMES" | sed 's/^/  /'
      echo "3번째 인자에 위 목록의 이름을 그대로 넣어라 (워크트리·브랜치 이름 아님)."
      exit 1; }
  else
    echo "경고: 'orca repo list' 가 빈 응답 — Orca 런타임이 꺼졌나? '$ORCAREPO' 를 검증하지 못했다"
    echo "  → 발사 전에 확인: orca repo list --json | jq -r '.result.repos[].displayName'"
  fi
else
  echo "경고: orca 또는 jq 를 PATH 에서 못 찾아 '$ORCAREPO' 를 검증하지 못했다"
fi

# 훅 폴더는 워크트리 바깥(레포 부모)에 둔다 — 브랜치마다 파일이 생기면 꼬인다
DEST=${HOOKS:-$(cd "$ROOT/.." && pwd)/.githooks}
mkdir -p "$DEST"
for f in dev-sync.sh pre-merge-commit pre-commit post-merge post-commit ticket.sh verify.sh \
         reviewer-prompt.md closing-prompt.md; do
  [ -e "$DEST/$f" ] && { echo "건너뜀(이미 있음): $DEST/$f"; continue; }
  cp "$SRC/githooks/$f" "$DEST/$f"
done
chmod +x "$DEST"/dev-sync.sh "$DEST"/pre-merge-commit "$DEST"/pre-commit \
         "$DEST"/post-merge "$DEST"/post-commit "$DEST"/ticket.sh "$DEST"/verify.sh

# 플레이스홀더 채우기 — 훅은 로그인 셸이 아니라 PATH 가 최소다. 절대경로가 필수.
CB=$(command -v claude || true)
[ -n "$CB" ] || { echo "claude 를 PATH 에서 못 찾음 — $DEST/dev-sync.sh 의 CLAUDE_BIN 을 직접 적어라"; CB=@@CLAUDE_BIN@@; }
sed -i '' "s|@@CLAUDE_BIN@@|$CB|" "$DEST/dev-sync.sh" 2>/dev/null || \
  sed -i "s|@@CLAUDE_BIN@@|$CB|" "$DEST/dev-sync.sh"
sed -i '' "s|@@REPO@@|$ORCAREPO|" "$DEST/ticket.sh" 2>/dev/null || \
  sed -i "s|@@REPO@@|$ORCAREPO|" "$DEST/ticket.sh"

# core.hooksPath 는 repo 단위 공통 config = 모든 워크트리에 자동 적용. 절대경로로.
git -C "$ROOT" config core.hooksPath "$DEST"
# ff 머지는 pre-merge-commit 을 건너뛴다 = 게이트 우회. 반드시 끈다.
git -C "$DEVWT" config merge.ff false

mkdir -p "$DEVWT/.tickets"
grep -qx '.tickets/' "$DEVWT/.gitignore" 2>/dev/null || echo '.tickets/' >> "$DEVWT/.gitignore"

# 스킬은 dev 워크트리에만 둔다 — 스펙 쓰기와 보고서 요약이 dev 세션의 일이다.
# skills/ 아래 폴더 전부를 깐다(하나씩 적지 않는다 — 새 스킬을 추가할 때 여기를 또 고치게 된다)
mkdir -p "$DEVWT/.claude/skills"
for s in "$SRC"/skills/*/; do
  s=${s%/}   # ⚠ 트레일링 슬래시를 떼야 한다. BSD cp 는 `cp -R dir/ dest/` 를 "dir 의 내용을 dest 로"
             #   로 해석해서 SKILL.md 가 skills/ 밑에 그대로 떨어진다(스킬로 인식 안 됨)
  n=$(basename "$s")
  [ -e "$DEVWT/.claude/skills/$n" ] && { echo "건너뜀(이미 있음): $DEVWT/.claude/skills/$n"; continue; }
  cp -R "$s" "$DEVWT/.claude/skills/"
done

# 권한 allowlist — 없으면 ticket.sh 호출마다 승인 프롬프트가 뜬다(티켓 한 개에 4~6회).
# 이미 파일이 있으면 건드리지 않는다 — 사람이 쓴 설정을 덮는 것이 프롬프트보다 나쁘다.
SETTINGS=$DEVWT/.claude/settings.local.json
if [ -e "$SETTINGS" ]; then
  echo "건너뜀(이미 있음): $SETTINGS"
  echo "  → permissions.allow 에 다음을 직접 넣어라: \"Bash($DEST/ticket.sh:*)\", \"Bash(../.githooks/ticket.sh:*)\""
else
  cat > "$SETTINGS" <<JSON
{
  "permissions": {
    "allow": [
      "Bash($DEST/ticket.sh:*)",
      "Bash(../.githooks/ticket.sh:*)",
      "Bash(orca worktree list:*)",
      "Bash(orca worktree ps:*)",
      "Bash(orca terminal list:*)"
    ]
  }
}
JSON
fi

echo "--- selftest"
# cwd 가 대상 레포 안이어야 한다 — selftest 가 `git worktree list` 로 dev 워크트리를 찾는다
cd "$DEVWT"
sh "$DEST/dev-sync.sh" --selftest || {
  echo "selftest 실패 — 위 항목을 채워라 (verify.sh 커맨드·CLAUDE_BIN 등)"; exit 1; }

cat <<EOF

설치 끝: $DEST

설치된 것: 훅 4개 + dev-sync.sh + ticket.sh + reviewer-prompt.md(머지별) + closing-prompt.md(close 종합)
           $DEVWT/.claude/skills/ 에 스킬 2개 (writing-ticket-specs, writing-korean-explainers)
           $DEVWT/.claude/settings.local.json (ticket.sh 권한 allowlist)
           core.hooksPath, merge.ff=false, .tickets/

남은 수동 작업 2개 (스크립트가 못 정한다):
  1) $DEST/verify.sh — 이 프로젝트의 typecheck·test 커맨드로 교체.
     ⚠ 기존 에러가 0 인 도구만 넣는다. 실패 중인 검사를 넣으면 게이트가 차단기가 되고
       곧 --no-verify 우회를 부른다.
  2) 워크트리 상위 CLAUDE.md 에 templates/CLAUDE-workflow-section.md 내용을 붙인다.
     ⚠ Orca GUI 설정에만 두면 워크트리 에이전트가 못 읽는다.

첫 티켓:
  cp $SRC/templates/spec.html /tmp/my-ticket.html # 5슬롯 채우기 (초안은 사람이 쓴다)
  cd $DEVWT && $DEST/ticket.sh new fix/my-ticket /tmp/my-ticket.html
  # ⚠ orca 가 브랜치명을 정규화한다(fix/my-ticket → fix-my-ticket).
  #   이후 wait → merge <실제브랜치> → close <실제브랜치>. new 출력에 실제 이름이 찍힌다.
EOF
