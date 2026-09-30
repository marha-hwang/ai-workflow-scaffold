---
name: building-project-llm-wiki
description: Use when a project's documents have grown hard to navigate or keep in sync and the user wants them organized as an LLM wiki inside the repo (raw/wiki, index, ingest), when agents should read a compiled wiki before raw docs, or when raw documents change and the wiki must follow automatically. 트리거 예: "LLM 위키 방식으로", "문서를 raw로 모아", "ingest로 자동 반영", "CLAUDE.md에서 위키로 라우팅".
---

# 프로젝트 LLM 위키 구성

## 핵심

문서를 세 층으로 나눈다. **raw**(모든 문서의 원본, `docs/raw/`), **정본**(코드와 함께 바뀌는 계약: 루트 `CLAUDE.md`, 소스 옆 `spec.md`), **위키**(LLM이 raw와 정본을 컴파일한 층, `docs/index.md`·`docs/log.md`·`docs/wiki/`). 기계는 "원천이 바뀌었다"를 알리고, LLM은 그 알림을 받아 위키를 다시 컴파일한다.

## 구성 절차

1. **git 기준선부터.** 해시 대장은 "바뀌었다"만 알고 이전 내용은 git에만 있다. 이동 전에 커밋이나 저장 지점(`git stash create` → `git update-ref refs/savepoints/<이름>`)을 만든다.
2. **문서의 소비자를 먼저 센다.** `grep -rnE "['\"\`/]docs/"`로 문서 경로를 코드에 고정한 스크립트·설정을 찾는다. 레포 전체를 훑는 코드 검사(링크, 스펙 ID, 비밀 스캔)도 찾는다. 이것들이 옮긴 뒤 깨지거나 raw 안의 옛 사본을 훑어 가짜 실패를 낸다.
3. **`git mv`로 `docs/*` → `docs/raw/`.** 상대 링크는 손으로 고치지 않는다. 옮기기 전 트리에서 링크마다 대상 파일을 풀어 두고, 옮긴 뒤 새 위치 기준으로 다시 상대화하는 스크립트로 바꾼다. 스크립트의 경로 상수도 고치고, 고친 파일을 `CLAUDE.md`에 목록으로 남긴다.
4. **`scripts/lint.py`를 `docs/lint.py`로 복사**하고 맨 위 설정 상수만 맞춘다. `python3 docs/lint.py`가 자체 검사부터 돈다.
5. **훅**: `.claude/settings.json`
   ```json
   {"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","timeout":10,
     "command":"python3 \"$CLAUDE_PROJECT_DIR/docs/lint.py\" --pending 2>&1 || echo \"[위키] lint --pending 실패. 대기 0건으로 보지 말고 python3 docs/lint.py로 원인을 먼저 확인한다\""}]}]}}
   ```
   세션 도중 `.claude/`를 처음 만들었으면 `/hooks`를 한 번 열거나 재시작해야 적용된다.
6. **루트 `CLAUDE.md`에 [claude-md-section.md](claude-md-section.md)를 붙인다.** 규칙 파일은 루트 한 장이다. `AGENTS.md`는 "CLAUDE.md를 읽는다" 한 단락만 둔다.
7. **첫 ingest.** 시작 페이지는 overview · architecture · status · risks(조용한 실패) · source-conflicts(원천끼리 어긋난 곳) · decisions/. 문서가 많으면 주제별 서브에이전트에게 **고칠 페이지를 겹치지 않게 배정**하고, 공용 페이지(index, log, status, risks, source-conflicts)는 직접 통합한다. 큰 파일은 청크로 끝까지 읽게 하고 마지막 줄 번호를 보고받는다. 끝나면 `python3 docs/lint.py --mark docs/raw`.
8. **검증.** lint가 문제 0건, 대기 0건. raw 파일 하나를 수정·추가·삭제해서 `--pending`이 그 파일과 **다시 대조할 페이지**를 내는지 본다. 대장을 일부러 깨뜨려 훅이 실패 문구를 내는지 본다. 원래대로 되돌린다.

## 하기 쉬운 실수

| 실수 | 대신 |
|---|---|
| 한글 파일명을 그대로 비교 | NFC로 맞춘다. macOS 사본은 NFD, git clone은 NFC라 "삭제+새 파일"로 오탐한다 |
| 변경 파일만 알림 | 페이지 `sources:`로 "다시 대조할 페이지"까지 알린다 |
| 변경 감지만 만들고 위키 검사 없음 | 깨진 링크, index 누락, 없는 근거도 문제로 보고한다 |
| "LLM은 raw를 고치지 않는다" | 사람과 LLM이 모두 고친다. LLM이 고쳤으면 같은 작업 안에서 ingest까지 끝낸다 |
| SessionStart·Stop 훅만 | UserPromptSubmit로 메시지마다 본다. 세션 중 사람이 고친 raw도 다음 메시지에 잡힌다 |
| 훅이 `\|\| true`로 오류를 버림 | 실패 문구를 출력한다. 빈 출력은 "대기 0건"과 구별되지 않는다 |
| mtime·log 기록으로 낡음 판정 | sha256 해시 대장. 복사·압축 해제에 흔들리지 않고 수정·삭제도 잡는다 |
| 위키가 raw 링크만 가짐 | raw 내용은 요약·분류해 담는다. 코드와 함께 바뀌는 계약 값(금액식, 상태 전이, API 필드)만 가리킨다 |
| 위키 반영 전에 `--mark` | 반영한 파일만 기록한다. mark는 "다시 컴파일했다"는 표시다 |
| 규칙을 `docs/CLAUDE.md`에 둠 | CLAUDE.md는 작업 위치에서 위로만 읽힌다. 루트 한 장에 둔다 |
| 레포 전체 코드 검사가 `docs/`까지 훑음 | raw 안의 옛 소스 사본(spec.md·테스트)이 ID 중복을 만든다. 코드 검사는 `docs/`를 제외하고, 문서 링크는 `lint.py`의 `LINKED_RAW`가 맡는다 |
| 인수·발주 기록까지 "현재"로 고침 | 당시 모습을 남겨야 하는 기록(무결성 manifest, 발행된 발주서)은 고치지 않고 status 페이지에 적는다 |

## 페이지 규칙

머리말에 `updated:`(근거와 대조한 날짜)와 `sources:`(레포 루트 기준 경로, 폴더도 된다). "~가 없다" 같은 단정에는 확인 날짜를 붙인다. 링크는 상대경로 markdown. 카테고리를 미리 만들지 않는다. `log.md`는 append-only다.
