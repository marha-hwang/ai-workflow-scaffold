---
name: ticket-hub
description: Use when the dev 워크트리 세션 acts as the 허브(메인 dev 세션) for a 묶음 작업 — 하위 티켓들을 bundles/<묶음>/plan.tsv로 발사·현황 확인·사람 결정 전달할 때. 트리거 예: "허브로 티켓 돌려", "다음 티켓 발사", "티켓 현황", "T7 마무리해", "T3 재요청". 티켓 하나만 돌릴 때는 쓰지 않는다(ticket.sh new를 직접).
---

# 티켓 허브

허브는 **사람과 이야기하는 유일한 세션**이다. 티켓마다 따로 뜬 티켓 dev 세션이 발사·대기·머지·요약을 하고, 허브는 발사·현황·결정 전달만 한다.

```
사람 ⇄ 허브(이 세션) ── spawn ──→ 티켓 dev 세션 (티켓 하나, new→wait→merge→요약→notify)
                     ←─ notify ──            └─→ 워커 워크트리 (판정은 verify.sh)
```

## 허브가 하지 않는 것

허브가 판단을 시작하면 코디네이터가 되고 두 번째 게이트가 생긴다. 그래서 아래는 금지다.

- **다음 티켓 발사를 판단하지 않는다.** 발사 가능 여부는 `ticket.sh ready`가 계산한다(의존 close + 스펙 미정 표시 0 + 동시 실행 < `TICKET_WIP`). 허브는 그 목록을 발사만 한다
- **리뷰 보고서·verify 로그 본문을 읽지 않는다.** 읽는 것은 티켓 세션이 쓴 티켓 폴더의 `summary.md`뿐이다. 허브 컨텍스트가 티켓 수만큼 불어나지 않게 하기 위해서다
- **재요청 본문을 쓰지 않는다.** 사람의 말을 그대로 `tell`로 넘긴다. 본문은 티켓 세션이 쓴다
- **close를 스스로 하지 않는다.** 사람이 "마무리"라고 말한 티켓만 close한다. close가 다음 티켓의 발사 조건이기 때문이다
- **상태를 기억에 두지 않는다.** 매번 `board`로 파일에서 읽는다. 허브 세션은 언제 닫고 새로 열어도 같아야 한다

## 시작

```sh
sh ../.githooks/ticket.sh hub      # 이 터미널을 허브로 등록 (세션을 새로 열 때마다)
sh ../.githooks/ticket.sh board    # 상태표
```

`.tickets/`는 단일 작업과 묶음 작업이 폴더부터 갈린다. 티켓 하나의 정보는 그 티켓 폴더 하나에만 있다.

```
.tickets/
  queue.md · hub.terminal          공용
  single/<slug>/                   단일 작업 (허브 밖, ticket.sh new 를 직접)
  bundles/<묶음>/plan.tsv           묶음 작업의 하위 티켓 목록: id<TAB>브랜치<TAB>의존(쉼표, 없으면 -)<TAB>제목
  bundles/<묶음>/<브랜치>/           하위 티켓: spec.html(사람) · review-*·verify-*(훅) · session · summary.md · inbox.md · closed
```

묶음이 없으면 사람에게 계획 문서의 티켓 표를 `bundles/<묶음>/plan.tsv`로 옮겨도 되는지 묻는다. 브랜치는 `/` 없이 쓰고 앞에 묶음 약칭을 붙인다(`feat-cfd-t01-…`). 스펙은 `bundles/<묶음>/<브랜치>/spec.html`이고 **사람이 쓴다**(`writing-ticket-specs`). 티켓은 `<묶음>/<id>`로 가리킨다. 묶음이 하나뿐이면 `<id>`만 써도 된다.

## 루프

1. `ready <묶음>`이 출력한 id를 남은 자리만큼 `spawn <묶음>/<id>`
2. `hub-wait` — 티켓 세션의 알림을 기다린다. 빈손은 실패가 아니다. 다시 기다린다
3. 알림(`<묶음>/<id> <상태>`)이 오면 그 티켓 폴더의 `summary.md`를 사람에게 보여 준다. 상태별로:
   - `decision`: 요약 그대로. 마지막 줄의 "재요청 / 마무리" 선택지를 사람에게 묻는다
   - `question`: 워커가 묻는 것이다. 사람의 답을 받는다
   - `failed`·`stalled`: 이유를 보여 주고 어떻게 할지 묻는다
4. 사람의 결정을 옮긴다:
   - 마무리 → `close <브랜치>`(브랜치는 plan.tsv 2열). 출력의 "새로 발사 가능"을 1로
   - 재요청·답 → 사람의 말을 파일로 써서 `tell <묶음>/<id> <파일>`. 판단을 보태지 않는다
5. 2로

## 보고 형식

사람에게 하는 보고는 `writing-korean-explainers`의 `규모가 작은 보고` 형식이다. 여러 티켓을 한 번에 알릴 때는 `board` 출력을 티켓당 한 줄로 줄이고, 결정을 기다리는 티켓을 맨 위에 둔다.

## 막혔을 때

| 증상 | 확인 |
|---|---|
| `spawn`이 "발사 불가 상태=spec-tbd" | 스펙에 `<mark class="tbd">`가 남았다. 사람이 정할 칸이다 |
| `spawn`이 "동시 실행 상한" | 정상. close를 기다린다. 사람이 원하면 `TICKET_WIP=4 sh ../.githooks/ticket.sh spawn <묶음>/<id>` |
| 티켓 세션이 알림 없이 오래 조용함 | `orca terminal show --terminal $(cat .tickets/bundles/<묶음>/<브랜치>/session)`로 화면을 본다. 허브가 대신 merge하지 않는다 |
| `tell`이 tui-idle 시간 초과 | 티켓 세션이 아직 일하는 중이다. 알림을 받은 뒤에 보낸다 |
