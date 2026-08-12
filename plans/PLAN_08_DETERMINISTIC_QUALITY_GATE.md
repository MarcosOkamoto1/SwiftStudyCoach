# PLAN_08 — Checks determinísticos + prioridade adaptativa do upgrade

## Objetivo

Implementar `DeterministicCodeChecks` — uma camada de checks
estáticos/regex barata sobre o código gerado pelo FM-only da Fase 1 — e
usar o resultado para decidir a PRIORIDADE (não a execução) do upgrade
MLX de `PLAN_07`: se algum check falhar, a prioridade sobe de
`.poolFill` para `.nextSession`.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F30/§20/D1 (parte final): a Estratégia D combina B
(tirar MLX do síncrono, `PLAN_06`) com um elemento de C (gate
determinístico) que não decide SE a crítica roda (ela sempre roda, isso é
`PLAN_07`), mas decide a prioridade — captura o benefício de C (recursos
de background gastos com mais urgência onde o risco é maior) sem o
principal risco de C isolado (heurística sintática deixando passar um
erro semântico sem que ninguém mais olhe, porque a crítica MLX nunca é
pulada).

## Estado esperado antes de começar

`PLAN_07` implementado: upgrade MLX em background funcionando com
prioridade fixa `.poolFill`. Este plano só adiciona a lógica de decisão
de prioridade — não muda o fato de que o upgrade sempre roda.

## Dependências

`PLAN_07` (dependência real — o gate de prioridade só faz sentido depois
que existe um upgrade de verdade para priorizar; sem `PLAN_07`, não há
nada para reordenar).

## Arquivos provavelmente afetados

- Novo: `Services/DeterministicCodeChecks.swift`
- `Services/TopicRepository.swift` e/ou `Services/StudyGenerator.swift`
  (aplicar o resultado do gate na chamada que enfileira o upgrade no
  `GenerationOrchestrator`)

## Mudanças a implementar

### 1. `DeterministicCodeChecks.evaluate(_:) -> Result`

```swift
enum DeterministicCodeChecks {
    struct Result { let passed: Bool; let flags: [String] }

    static func evaluate(_ code: String) -> Result {
        var flags: [String] = []
        if StudyGenerator.looksTruncated(code) { flags.append("truncamento") }
        if Self.hasActionlessControl(code) { flags.append("controle sem action") }
        if Self.hasNavigationDestinationValueLiteral(code) { flags.append("navigationDestination com valor") }
        if Self.hasStateObjectOnValueType(code) { flags.append("StateObject em tipo de valor") }
        return Result(passed: flags.isEmpty, flags: flags)
    }
}
```

Reusa `StudyGenerator.looksTruncated` (já existe, `StudyGenerator.swift:479-509`
— não duplicar). Implementa 3 checks novos baseados no
`commonCodeMistakesChecklist` já existente como PROMPT
(`StudyGenerator.swift:618-628`), convertidos para regex/string onde
mecanicamente verificável (ver tabela abaixo).

### 2. Implementar os 3 checks regex (ver tabela de viabilidade)

| Check | Regex/heurística |
|---|---|
| `hasActionlessControl` | `Button`/`Toggle`/`NavigationLink` sem `action:`/closure — `Button\("([^"]*)"\)\s*$` ou seguido de `\n\s*[A-Z}]` sem `{` logo após (heurística sintática, não 100% — pode ter falso positivo com multi-linha complexo, aceitável) |
| `hasNavigationDestinationValueLiteral` | `navigationDestination\(for:\s*\d` (literal numérico) ou `for:\s*"` (literal string) — tipo válido nunca começa com dígito/aspas |
| `hasStateObjectOnValueType` | `@StateObject.*var \w+:\s*(Int\|Bool\|String\|NavigationPath\|Double)\b` — cobre os casos citados explicitamente no checklist atual |

### 3. Aplicar o gate no ponto de enfileiramento do upgrade

No ponto onde `PLAN_07` enfileira `upgradeCodeExampleViaMLX` no
`GenerationOrchestrator` com prioridade `.poolFill` fixa: rodar
`DeterministicCodeChecks.evaluate(example.code)` sobre o resultado da
Fase 1 primeiro; se `passed == false`, enfileirar com `.nextSession` em
vez de `.poolFill`. A lógica de prioridade em si já existe no
`GenerationOrchestrator` (F7, não alterar) — só a ESCOLHA de qual
prioridade passar muda.

## O que NÃO alterar nesta etapa

- **A crítica MLX/upgrade NUNCA deixa de rodar**, mesmo se
  `passed == true` — os checks determinísticos só REORDENAM o trabalho,
  nunca substituem a crítica por modelo. Pelo menos 2 causas de bug
  documentadas (parâmetro de inicializador inexistente, walkthrough
  dessincronizado) não são verificáveis sem modelo (ver
  `SOLUTIONS_PLAN.md` §20.2, tabela) — implementar um gate que PULE a
  crítica quando os checks passarem seria uma regressão de segurança não
  autorizada por este documento.
- **Não implementar `swiftc` real via `Process`** — decisão explícita já
  tomada em `SOLUTIONS_PLAN.md` §20.4: não fazer agora (dificuldade real
  de sintetizar um harness de compilação para fragmentos soltos; ganho
  marginal não evidenciado sobre os checks + crítica já propostos).
  Revisitar só se, depois deste plano, o histórico de bugs mostrar uma
  nova classe de erro que as camadas atuais não cobrem.
- **Não tocar em `GenerationOrchestrator.swift`** — a lógica de fila e
  prioridade já existe e funciona (F7, "NÃO ALTERAR"); este plano só
  escolhe QUAL prioridade passar, no lado de quem chama.

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §20.1 (camadas de defesa completas: RAG grounding
→ generation → deterministic checks → optional model critique → schema
validation → persistence), §20.2 (tabela completa de viabilidade de cada
erro conhecido — inclui os 2 casos explicitamente NÃO verificáveis sem
modelo, que devem continuar dependendo da crítica), §20.3 (onde entra no
pipeline, pseudocódigo do `DeterministicCodeChecks`), §20.4 (por que não
`swiftc` real, registrado para não reabrir a discussão sem evidência
nova).

## Instrumentação necessária

Registrar (via `GenerationMetricsStore` de `PLAN_00`, ou um contador
simples) a distribuição de resultados dos checks (quantos tópicos passam
limpo vs. quantos disparam algum flag) — útil para calibrar os regex no
futuro e para entender se a heurística está pegando casos reais.

## Testes

Unit tests (`DeterministicCodeChecksTests.swift`, pode ser adicionado
aqui ou consolidado em `PLAN_01`/`PLAN_16` se ainda não existir o target
de testes) com fixtures REAIS dos bugs já documentados no histórico do
projeto: `Button("Salvar")` sem `action:`, `.navigationDestination(for: 1)`,
`@StateObject` em `Bool` — cada um deve disparar o flag correspondente.
Também testar casos negativos (código correto não deve disparar nenhum
flag) para evitar falsos positivos excessivos.

## Benchmark, se aplicável

N/A diretamente — não é benchmark-gated no sentido de aprovação/rejeição.
Opcionalmente, medir (via instrumentação) a taxa de flags disparados em
uso real para calibrar os regex depois de um período de uso, mas isso não
bloqueia a conclusão deste plano.

## Success Criteria

- `DeterministicCodeChecks.evaluate` detecta corretamente os 3 bugs
  históricos documentados nos testes de fixture.
- O upgrade MLX é enfileirado com `.nextSession` quando algum check falha,
  e `.poolFill` quando todos passam — verificável por teste unitário do
  ponto de decisão (com um `GenerationOrchestrator` fake/mock, se
  necessário) ou por inspeção de log.
- A crítica MLX continua rodando para 100% dos tópicos, independente do
  resultado dos checks (nunca é pulada).

## Rollback

Reverter o gate (upgrade sempre roda com prioridade fixa `.poolFill`,
como estava depois de `PLAN_07`) — degrada só a priorização, não a
correção (a crítica continua rodando de qualquer forma).

## Resultado esperado

Estratégia D completa (D1 totalmente implementada): upgrade em background
mais eficiente, priorizando recursos onde o risco heurístico é maior, sem
nunca sacrificar a defesa real contra hallucination.

## Commit boundary

Um commit cobrindo `DeterministicCodeChecks.swift` + o ponto de aplicação
do gate + os unit tests de fixture.

Suggested commit: `feat: add deterministic code checks to prioritize (not gate) MLX upgrade`

## Próximo plano desbloqueado

`PLAN_16` (integration/unit tests consolidados). Nenhum outro plano
depende estritamente deste.

## Claude Model Recommendation

Model:
Claude Sonnet 5 (`claude-sonnet-5`)

Reasoning level:
Medium

Why this model:
É lógica determinística bem delimitada (regex + contagem + escolha de
prioridade) sobre uma estrutura de fila que já existe e não deve ser
tocada — bem mais contido que `PLAN_06`/`PLAN_07`. Ainda exige cuidado
para não introduzir falsos positivos/negativos nos regex e para garantir
que a crítica MLX nunca seja pulada (uma regressão de segurança sutil se
mal implementado), o que justifica Sonnet sobre Haiku.
