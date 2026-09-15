---
name: writing-ticket-specs
description: Use when a 티켓 스펙 for the Orca 티켓 워크플로 is being drafted or checked in the dev 워크트리 — before `ticket.sh new`, when a spec draft exists, or when a 재요청 traces back to the spec.
---

# 티켓 스펙 작성

## Overview

스펙 파일 하나가 워크트리 하나의 **유일한 입력**이다 (그 외 입력은 Orca 프리앰블 + 상위 CLAUDE.md 뿐).
재요청의 원인은 대부분 코딩 실패가 아니라 **빈 슬롯**이다.

**스펙은 HTML 한 장이다** (`.tickets/<slug>/spec.html`). 사람이 브라우저에서 열어 읽는 문서이고,
워크트리 에이전트도 같은 파일을 읽는다. 빌드도 서버도 없이 더블클릭으로 열리는 단일 파일을 유지한다.

## 역할 경계

- **초안은 사람이 쓴다.** 이 스킬은 초안을 받아 **빈 슬롯을 지적**한다. 대신 쓰면 계획이 위임된다
- **되물을 것은 한 번에 모아서 1회.** 질문을 나눠 던지면 사람이 한 건을 끝까지 생각할 시간을 잃는다
- 사람이 "네가 채워"라고 하면 채운다. 단 채운 자리에 `<span class="guess">(추정)</span>` 을 붙여 검증 대상임을 남긴다
- **되묻기 전에 코드를 먼저 확인한다.** "그 문구가 어디 있나"는 사람에게 물을 것이 아니라 grep 할 것이다.
  사실(파일·현재 값·개수)은 조사해서 제시하고, 판단(무엇으로 바꿀지·어디까지 할지)만 되묻는다

## 스펙 파일 (5슬롯 — 전부 필수)

`.tickets/<slug>/spec.html` 로 복사되는 파일. 슬롯 5개는 비워두지 않는다.
아래 골격을 그대로 복사해 내용만 채운다 — `<style>` 블록은 손대지 않는다.

```html
<!doctype html>
<meta charset="utf-8">
<title>(티켓 한 줄 제목)</title>
<style>
  :root { color-scheme: light dark; }
  body { max-width: 46rem; margin: 3rem auto; padding: 0 1.5rem;
         font: 16px/1.75 -apple-system, system-ui, sans-serif; }
  h1 { font-size: 1.5rem; margin: 0 0 2.5rem; }
  section { border-top: 1px solid rgba(128,128,128,.3); margin-top: 2rem; padding-top: 1rem; }
  h2 { font-size: .9rem; letter-spacing: .04em; opacity: .6; margin: 0 0 .75rem; }
  ul { margin: 0; padding-left: 1.2rem; }
  li { margin-bottom: .4rem; }
  code { font-size: .9em; background: rgba(128,128,128,.18);
         padding: .1em .35em; border-radius: 3px; }
  .tbd { background: #fde68a; color: #000; padding: .05em .3em; border-radius: 3px; }
  .guess { opacity: .55; font-size: .85em; }
  .keep { border-left: 3px solid #ef4444; padding-left: 1rem; border-top: none; }
</style>

<h1>(티켓 한 줄 제목)</h1>

<section>
  <h2>목적</h2>
  <p>(끝났을 때 화면·데이터가 무엇이 달라지는가. 1~2문장)</p>
</section>

<section>
  <h2>요구사항</h2>
  <ul>
    <li>(N하면 M이 된다 — 관찰 가능한 동작 단위로)</li>
  </ul>
</section>

<section>
  <h2>실행환경·제약</h2>
  <ul>
    <li>건드릴 파일·계층: <code>src/...</code></li>
    <li>계약 변경(API·외부 인터페이스): 있음/없음 — 있으면 무엇을</li>
    <li>의존 티켓: </li>
  </ul>
</section>

<section>
  <h2>테스트 시나리오</h2>
  <ul>
    <li>코드로 검증(verify.sh 대상): </li>
    <li>사람이 직접 돌려서 확인: </li>
  </ul>
</section>

<section class="keep">
  <h2>손대지 말 것</h2>
  <ul>
    <li>(기존 동작 유지 범위. 리팩토링 금지 구역)</li>
  </ul>
</section>
```

## 마크업 규칙

태그는 위 골격에 있는 것만 쓴다. HTML 로 바꾼 이유는 **읽는 사람이 슬롯을 한눈에 구분**하기 위해서지
문서를 꾸미기 위해서가 아니다. 워커가 읽을 신호가 마크업에 묻히면 스펙이 제 역할을 못 한다.

| 표시 | 쓰는 자리 |
|---|---|
| `<mark class="tbd">미정: …</mark>` | 아직 모르는 것. 노랗게 떠서 발사 전에 눈에 걸린다 |
| `<span class="guess">(추정)</span>` | 사람이 "네가 채워"라 해서 스킬이 채운 자리 |
| `<code>` | 파일 경로·식별자·실제 문자열 값 |
| `class="keep"` | `손대지 말 것` 섹션 하나뿐. 빨간 줄이 금지 구역 표시다 |

- `<h1>` 은 티켓 한 줄 제목이다. 큐(`queue.md`)가 이 줄을 읽어 티켓을 식별한다
- 새 `class`·인라인 `style`·스크립트·외부 폰트·이미지를 추가하지 않는다
- 표가 필요하면 `<table>` 그대로 쓴다. 스타일은 없어도 읽힌다

## 슬롯 판정 기준

각 슬롯은 **관찰 가능한 조건**으로 판정한다. 미달이면 오른쪽 질문을 그대로 되묻는다.

| 슬롯 | 통과 조건 | 미달이면 되물을 것 |
|---|---|---|
| 목적 | 완료 상태를 화면·데이터로 말한다 | "끝난 걸 무엇을 보고 확인하나?" |
| 요구사항 | 각 줄이 조건→결과 형태다. "잘 동작"류 없음 | "0건일 때? 실패했을 때? 권한 없을 때?" |
| 실행환경·제약 | 파일·계층이 적혀 있고 계약 변경 유무가 명시됐다 | "계약이 바뀌나? 바뀌면 상대 팀 확인 필요한가?" |
| 테스트 시나리오 | **verify.sh에 넣을 수 있는 줄이 1개 이상** + 사람 확인분이 분리됐다 | "이걸 typecheck·단위테스트로 어떻게 잡나?" |
| 손대지 말 것 | 유지할 동작·파일이 적혀 있다 | "이 작업이 건드리면 안 되는 기존 동작은?" |

테스트 시나리오가 목표문("정상 동작해야 함")이면 게이트에 넣을 것이 없다 —
**구현 전에 쪼개는 것이 이 슬롯의 목적**이다.

문자열·설정만 바꾸는 티켓은 typecheck 에 안 걸린다. 그때 게이트에 넣을 것:
"바뀐 값이 실제로 그 값인가" + "옛 값이 어디에도 안 남았는가" 를 파일을 직접 읽는 테스트로.

## 자주 비는 자리 (프로젝트마다 갱신할 표)

| 자리 | 확인 |
|---|---|
| 실패 케이스 | 케이스가 N종이어도 **UI 분기는 1개**. 에러 코드로 흡수한다. 케이스 수만큼 UX를 만들지 않는다 |
| 데이터 소스 | 한 화면은 **단일 소스**. 여러 API 조합은 구현은 빠르지만 이해 비용이 크다 |
| 서버 필드 요청 | 그 값으로 **분기가 하나라도 생기는가**. '있으면 유용'은 계약만 무겁게 한다 |
| 남의 시스템에 요청 | 그 시스템이 **그 사실을 아는 위치인가**. 모르는 쪽에 요청하면 없는 상태를 지어낸다 |
| 복구 수단(재처리·삭제) | **기존 동작(재시도·재업로드)이 그 역할을 하면 만들지 않는다** |
| 같은 값이 두 곳에 | 표시 문자열·상수가 2곳 이상이면 **단일화가 티켓의 일부인지** 먼저 정한다. 아니면 다음 티켓에서 또 어긋난다 |

## 모르는 것이 남았을 때

빈칸으로 두지 말고 그 자리에 `<mark class="tbd">미정: <무엇을 모르는지></mark>` 를 적는다.
모른다는 사실이 스펙에 남아야 재요청·설계 변경의 근거가 된다.
노랗게 뜨므로 브라우저에서 훑기만 해도 발사 전에 남은 빈칸이 보인다.

## 완성 후

```sh
.githooks/ticket.sh new feat/<브랜치> <스펙파일>.html   # 워크트리 생성 + dispatch. 출력의 '실제 브랜치'를 받아적어라
.githooks/ticket.sh wait                               # worker_done 대기 (빈손 복귀 = 체크포인트, 다시 wait)
#   대기는 이 명령으로만 한다 — orca orchestration check 를 직접 부르면 --terminal 이 빠져 영원히 빈손이다
.githooks/ticket.sh merge <실제브랜치>                  # ★ 판정(verify.sh) + 리뷰 보고서
```

`new feat/x` 로 발사해도 orca 가 브랜치를 `feat-x` 로 정규화한다 — `merge`·`send`·`close` 는 그 이름을 쓴다.
슬러그(`.tickets/<slug>/`)도 실제 브랜치 기준이다.

**판정은 발사 시점이 아니라 머지 시점에 일어난다.** `[done]` 커밋은 선언일 뿐이고,
`pre-merge-commit` 훅이 머지 결과 트리에서 `verify.sh` 를 돌려 통과분만 dev 에 넣는다.
라운드 보고서는 `.tickets/<slug>/review-<sha>.md`, 실패 로그는 `verify-<sha>.log`.
`close` 가 라운드 보고서들을 `review.md` 한 장으로 접는다(원본은 `rounds/`) — **`spec.html` 의 `요구사항`·`미정` 슬롯이 그 종합의 기준선**이 된다.
슬롯을 비워두면 종합이 "무엇을 하려던 티켓인지"를 판정할 근거를 잃는다.

## Common Mistakes

- **스펙을 요구사항 한 줄로 줄인다** → 워크트리가 되묻거나 임의 결정한다
- **테스트 시나리오를 "테스트 통과"로 쓴다** → 게이트에 넣을 것이 없다
- **손대지 말 것을 비운다** → 요청 안 한 리팩토링이 diff에 섞인다
- **스킬이 초안을 다 써준다** → 사람이 이해하지 못한 계획이 발사된다
- **조사 없이 되묻는다** → 사람이 답한 전제가 코드와 다르면 스펙 전체가 틀어진다
- **마크업을 늘린다** → 워커가 읽을 유일한 입력이 태그에 묻힌다. 골격 밖의 태그·클래스는 쓰지 않는다
