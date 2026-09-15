#!/bin/sh
# ============================================================================
# 머지 게이트. pre-merge-commit / pre-commit 훅이 워크트리 안에서 실행한다.
# 종료코드 0 = 머지 진행 / 0 아님 = 머지 안 함.
#
# 선언은 LLM, 판정은 기계 — 여기서 실행되는 것만 사실이다.
# 게이트는 이 파일 하나뿐. 리뷰 에이전트는 게이트가 아니다(지목만 한다).
#
# ★ 이 파일은 **교체 필수**다. 기본 상태는 "미설정"으로 머지를 막는다(fail closed).
#   예시 커맨드를 그대로 두면 스택이 다른 프로젝트에서 엉뚱한 에러가 나고,
#   원인이 "워커 코드"인지 "게이트 설정"인지 구분하는 데 라운드를 쓴다.
#   ⚠ 기존 에러가 0 인 도구만 넣는다. 실패 중인 검사를 넣으면 게이트가 차단기가 되고
#     곧 --no-verify 우회를 부른다. 못 켜는 검사는 주석으로 남기고 이유를 적어라.
# ============================================================================
set -e

# 훅은 로그인 셸이 아니라 PATH 가 최소다. 런타임 경로를 명시적으로 얹는다.
PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
export PATH

# --- 여기부터 프로젝트별 (아래 3줄을 지우고 실제 커맨드를 넣어라) -----------

echo "verify.sh 가 아직 교체되지 않았다 — $0 을 이 프로젝트의 typecheck·test 커맨드로 바꿔라" >&2
echo "  (게이트가 미설정이면 머지를 막는다. 통과시키려면 실제 검사를 넣어야 한다)" >&2
exit 1

# ⚠ cwd 는 **워크트리 루트**다. 검사할 프로젝트가 하위 폴더에 있으면 반드시 내려가라.
#   서브셸로 감싸 이후 줄의 cwd 를 오염시키지 않는다:
#     (cd crawler && uv run pytest -q)
#     (cd frontend && npm run typecheck && npm test)
#
# ⚠ 설치 안 된 의존을 가드로 막을 때는 그 폴더 기준으로 본다:
#   루트에 없는 node_modules 를 루트에서 확인하면 항상 실패한다(실제로 그렇게 막힌 사례).
#     [ -d frontend/node_modules ] || { echo "frontend/node_modules 없음"; exit 1; }
#
# 스택별 예:
#   node:    npm run typecheck && npm test
#   python:  uv run pytest -q          # 또는 .venv/bin/mypy src && .venv/bin/pytest -q
#   go:      go vet ./... && go test ./...
#   rust:    cargo clippy -- -D warnings && cargo test
#
# 문자열·설정만 바꾸는 티켓은 typecheck 에 안 걸린다. 그때 넣을 것:
#   "바뀐 값이 실제로 그 값인가" + "옛 값이 어디에도 안 남았는가" 를 파일을 읽는 테스트로.
