# PLAN_04 — Desacoplar `ensureReady()` do caminho crítico de abertura de tela

## Objetivo

Fazer com que a abertura de `TopicStudyView` para um tópico com correspondência
exata no dataset não espere mais por `DocumentIndex.ensureReady()`
(construção do índice de embeddings) — só o caminho fuzzy (recomendação
de próximo tópico, busca livre) continua dependendo dele.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F12/D6/§18: `ensureReady()` bloqueia a entrada na tela
(`TopicStudyView.swift:121-127`) mesmo quando a geração de conteúdo do
tópico usa filtro EXATO (`chunks(forExactTopic:)`), que não depende de
embedding nenhum. Hoje o impacto é baixo (dataset pequeno, 3 tópicos/8
chunks), mas cresce se o dataset voltar a crescer (já foi 21 tópicos,
`PlaceholderDocs.swift:8-17`). Classificado como **Safe Win** (§25): sem
dependência de benchmark, risco baixo, mudança aditiva (adiciona um
caminho síncrono novo, não remove o caminho assíncrono existente).

## Estado esperado antes de começar

`DocumentIndex.swift`, `StudyGenerator.swift`, `TopicStudyView.swift`,
`ContentView.swift`, `TopicRepositoryTestView.swift` no estado auditado —
`ensureReady()` chamado antes da construção do repositório nos ~3 pontos
documentados em `SOLUTIONS_PLAN.md` §22.

## Dependências

`PLAN_00` (o grafo de dependência de `SOLUTIONS_PLAN.md` §23 lista esta
etapa como filha de "Instrumentação" — não há uma razão de implementação
que bloqueie tecnicamente este plano sem `PLAN_00`, mas medir o impacto
real de latência de abertura de tela antes/depois desta mudança precisa
da instrumentação existir; se `PLAN_00` ainda não foi feito, este plano
pode ser implementado sem medição formal, só validação manual).

## Arquivos provavelmente afetados

- `Services/DocumentIndex.swift` (novo `static func
  rawChunks(forExactTopic:)`)
- `Services/StudyGenerator.swift` (`retrieveContext`,
  `StudyGenerator.swift:89-96`)
- `Views/TopicStudyView.swift` (`load()`, linhas 116-133)
- `Views/ContentView.swift` (qualquer chamada de `ensureReady()` antes de
  construir o repositório — confirmar exatamente onde antes de editar)
- `Views/TopicRepositoryTestView.swift` (mesmo padrão, se aplicável)

## Mudanças a implementar

### 1. `DocumentIndex.rawChunks(forExactTopic:)` — novo, síncrono

Acesso síncrono aos chunks crus (topic+text, SEM embedding), direto do
dataset estático (`PlaceholderDocs.rawChunks`, já uma constante estática
sem I/O nem processamento assíncrono, `PlaceholderDocs.swift:60`) — não
depende de `ensureReady()` de forma alguma.

### 2. `StudyGenerator.retrieveContext` — caminho exato não aguarda mais embeddings

Tenta primeiro `DocumentIndex.rawChunks(forExactTopic:)`; se não vazio,
retorna direto (síncrono). Só se vazio (caminho fuzzy) é que aguarda
`documentIndex.ensureReady()` como hoje.

### 3. `TopicStudyView.load()` — não aguarda mais `ensureReady()`

Dispara `ensureReady()` em paralelo (fire-and-forget,
`Task.detached(priority: .utility)`) só para cobrir os casos raros que
precisarem do caminho fuzzy mais tarde na mesma sessão — não bloqueia a
construção do repositório nem o `fetchOrCreate`.

## O que NÃO alterar nesta etapa

- Não alterar `DocumentIndex.hybridSearch`, os pesos calibrados, nem
  nenhuma lógica de busca fuzzy — a arquitetura híbrida permanece intacta
  (decisão D6/§17, Opção B: manter, só tirar do caminho crítico de
  abertura).
- Não alterar `RAGTestView` nem `StudyResultView.resolveRecommendedTopic`
  — ambos continuam usando o caminho fuzzy, que continua aguardando
  `ensureReady()` normalmente (comportamento correto e esperado).
- Não mudar a chave de cache/invalidação de embeddings (F20, "NÃO
  ALTERAR agora" em `SOLUTIONS_PLAN.md`).
- Não remover o dedup de `ensureReady()` já existente
  (`DocumentIndex.swift:53-67`, `buildTask` compartilhada) — o
  `Task.detached` fire-and-forget deste plano ainda se beneficia desse
  dedup automaticamente, sem mudança adicional.

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §18.1 (lifecycle atual, problema), §18.2
(lifecycle proposto), §18.3 (assinaturas aproximadas completas dos 3
pontos de mudança — usar como referência direta de estrutura, não
copiar literalmente sem revisar o contexto exato do arquivo atual),
§18.4 (efeito colateral já coberto pelo dedup existente, sem mudança
adicional necessária).

```swift
// DocumentIndex.swift — novo
static func rawChunks(forExactTopic topic: String) -> [(topic: String, text: String)] {
    PlaceholderDocs.rawChunks
        .filter { $0.topic == topic }
        .map { (topic: $0.topic, text: $0.text) }
}
```

```swift
// StudyGenerator.swift — retrieveContext modificado
func retrieveContext(for topic: String, topK: Int = 3) async -> String {
    let exact = DocumentIndex.rawChunks(forExactTopic: topic)
    if !exact.isEmpty {
        return exact.prefix(topK).map(\.text).joined(separator: "\n\n")
    }
    try? await documentIndex.ensureReady()
    return (try? await documentIndex.retrieveContext(for: topic, topK: topK)) ?? ""
}
```

## Instrumentação necessária

Se `PLAN_00` já existir, confirmar que `ragChunkCount`/`ragContextChars`
continuam sendo capturados corretamente pelo novo caminho síncrono (mesma
métrica, origem diferente). Não é uma instrumentação nova, é validação de
que a existente continua funcionando com o novo código.

## Testes

Unit test de paridade (`DocumentIndex`, ver `PLAN_01` se já implementado,
ou adicionar aqui se `PLAN_01` ainda não existir): `rawChunks(forExactTopic:)`
devolve exatamente os mesmos textos que `DocumentIndex.shared.chunks(forExactTopic:)`
devolveria depois de `ensureReady()` completar — garante que os dois
caminhos ficam consistentes. Validação manual: confirmar que
`RAGTestView`/recomendação de próximo tópico (caminho fuzzy) continuam
funcionando normalmente (aguardando `ensureReady()` internamente, como
documentado).

## Benchmark, se aplicável

N/A — Safe Win. Opcionalmente, se `PLAN_00` existir, medir tempo de
abertura de tela antes/depois para quantificar o ganho (hoje pequeno, dado
o tamanho do dataset, mas crescente).

## Success Criteria

- Abrir um tópico com correspondência exata no dataset não aguarda mais
  `ensureReady()` — validável observando que a tela aparece mesmo se
  `ensureReady()` for artificialmente atrasado (ex.: `Task.sleep`
  temporário para teste manual, removido depois).
- `RAGTestView` e a recomendação de próximo tópico continuam funcionando
  sem regressão.
- Unit test de paridade passa.

## Rollback

Reverter as poucas chamadas alteradas (`retrieveContext`,
`TopicStudyView.load()`) — mudança pequena e contida a 3-4 arquivos, sem
mudança de schema ou de dado persistido.

## Resultado esperado

F12 corrigido: abertura de tela não depende mais do índice de embeddings
quando o caminho exato resolve.

## Commit boundary

Um commit cobrindo os 3-4 arquivos alterados + o unit test de paridade.
Compila, `RAGTestView` continua funcional, tela abre sem aguardar
`ensureReady()`.

Suggested commit: `perf: decouple exact-match RAG path from ensureReady(), only fuzzy path waits`

## Próximo plano desbloqueado

Nenhum plano depende estritamente deste, mas reduz a superfície de
"esperas desnecessárias" antes de `PLAN_06` (que já reduz um espera muito
maior — a de MLX).

## Claude Model Recommendation

Model:
Claude Sonnet 5 (`claude-sonnet-5`)

Reasoning level:
Medium

Why this model:
Toca 4-5 arquivos diferentes e precisa preservar cuidadosamente o
comportamento do caminho fuzzy (que não deve mudar) enquanto introduz um
caminho síncrono novo para o caso exato — exige entender a interação
entre os dois caminhos e o mecanismo de dedup existente
(`buildTask` compartilhada) para não introduzir uma race condition nova.
Não é puramente mecânico (Haiku erraria a sutileza do efeito colateral em
§18.4), mas também não é uma mudança arquitetural que justifique Opus.
