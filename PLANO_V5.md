# Plano V5 — O que falta pra fechar (pós-V4)

Não é um plano de implementação novo, é a lista do que ficou pendente depois
da sessão do Plano V4 + hotfixes. Curto de propósito.

---

## 1. Bloqueia fechar — fazer primeiro

**Commitar o que já está pronto e staged, mas ainda não commitado:**
- `MLXService.swift` — volta pro `Qwen2.5-Coder-7B-Instruct-4bit` (era o 3B)
- `StudyGenerator.swift` — `formatCodeExample` vira 2 passadas: `critiqueCodeDraft`
  (Foundation Models só aponta erro técnico, texto livre) → depois reformata
  pro schema já aplicando a crítica
- `TopicRepository.swift`, `ModelDownloadView.swift`, `TopicStudyView.swift` —
  comentários/tamanho de download atualizados pro 7B (4,3 GB)

Ficou pela metade quando a sessão foi interrompida — o `git add` rodou, tá
staged, só falta o `git commit` (usar o mesmo truque de `git write-tree` +
`git commit-tree` + `git update-ref` de antes, porque esse sandbox não
deixa `unlink`/`rm`, só `mv`).

**Aceite:** `git log` mostra o commit novo em cima do `9bcc359`.

---

## 2. Build + teste real (nunca rodei de verdade nesse ambiente)

Tudo que fiz até aqui foi validado só estruturalmente (chaves/parênteses
balanceados, contagem de chunks) — nunca compilei nem rodei o app de
verdade, porque não tenho Xcode neste sandbox.

- [ ] `xcodebuild ... build` sem erro
- [ ] Gerar um tópico novo (ex.: NavigationStack de novo) com o 7B e comparar
      o exemplo de código com o que deu os erros reportados
      (`Navigation.push`, `.navigationDestination(for: 1)`,
      `ContentView(selection:)`)
- [ ] Confirmar no log a linha `🔵 [exemplo de código] crítica técnica: ...`
      (prova que a 2ª passada rodou)
- [ ] Confirmar que o download do 7B (4,3 GB) completa — o teste anterior
      mostrou timeouts de rede durante download, e o 7B é maior

---

## 3. Se a alucinação no exemplo de código persistir mesmo assim

Próximo nível de defesa, mais caro: rodar o `swiftc` de verdade (via
`Process`) sobre o snippet gerado, em vez de confiar só em outro LLM pra
revisar. Só vale a pena investir nisso se o 2-pass não resolver — precisa
lidar com imports/contexto de um snippet solto, não é trivial.

---

## 4. Fases do V4 que nunca foram verificadas de ponta a ponta

Implementadas e revisadas estruturalmente, mas sem um teste real confirmando
o comportamento:
- Fase 1 (fluxo síncrono) — só vi 1 log parcial, nunca vi o final feliz
- Fase 3 (chunks auditados) — nunca vi resumo/quiz gerado comparado contra
  os chunks corrigidos
- Fase 4 (busca exata por tópico) — nunca vi confirmação de que o vazamento
  cross-topic sumiu num teste real
- `generateQuizPool`/`generateCodeAnalysisPool` (lotes ≤3 + desistência) —
  escrito depois do teste que mostrou o problema, nunca testado

---

## 5. Cosmético — não bloqueia nada

- Apagar `testfile_root_5` na raiz do projeto (arquivo vazio, sobrou de eu
  debugar o sandbox)
- `.git/index.lock.stale*` dentro de `.git/` — não são versionados, zero
  impacto, só estética; nem vale o esforço de tentar limpar
- Considerar `.gitignore` pro `UserInterfaceState.xcuserstate` — ele aparece
  "modificado" toda vez que o Xcode abre o projeto, é ruído em todo
  `git status`/commit daqui pra frente

---

## 6. Decisão seu

- Push pro `origin/Bugs-TelasMLX`: ainda não fiz, só commitei local
  (`9bcc359` + o pendente do item 1). Avisa quando quiser subir.
