# PLAN_10 — Geração sob demanda para análise de código

## Objetivo

Mudar `codeAnalysisPool` de geração especulativa (sempre disparada junto
com o resto do pool em background) para `generate-on-first-open`: só
começa a gerar quando o usuário toca o botão "Análise de código" pela
primeira vez.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F16/D8/§14: geração especulativa do pool completo
(24 quiz + 6 análise) na criação do tópico gasta GPU/bateria/tokens em
conteúdo que pode nunca ser visto. Análise de código é identificada como
a parte mais claramente especulativa (`PLAN.md` §16.3) porque fica atrás
de um botão, ao contrário do quiz (ação primária de "Praticar"). Quiz
(fácil/média/difícil) NÃO muda — o padrão "minimum viable pool" que já
existe é considerado razoavelmente eficiente e não precisa de mudança.

## Estado esperado antes de começar

`PLAN_06` implementado (`TopicRepository.generateAndPersist` já
reestruturado em Fase 1/Fase 2 — este plano modifica onde o gatilho de
"análise de código" entra nesse fluxo, então precisa da estrutura de
`PLAN_06` existir primeiro).

## Dependências

`PLAN_06`.

## Arquivos provavelmente afetados

- `Services/TopicRepository.swift` (remove `growCodeAnalysis` do disparo
  automático em `startBackgroundGrowthIfNeeded`/`growPoolInBackground`,
  linhas 320-440 originais; adiciona `ensureCodeAnalysisPool(topicName:)`)
- `Views/TopicStudyView.swift` (botão de análise de código dispara o novo
  gatilho na primeira interação)

## Mudanças a implementar

### 1. Remover `growCodeAnalysis` do disparo automático

`startBackgroundGrowthIfNeeded`/`growPoolInBackground` deixam de chamar
`growCodeAnalysis` como parte do crescimento automático de pool — quiz
(fácil/média/difícil) continua sendo gerado normalmente com o
`targetEasy/Medium/Hard` atual (6/6/6, sem mudança). Quantidade inicial de
análise de código passa a ser **0**.

### 2. Novo gatilho `ensureCodeAnalysisPool(topicName:)`

Chamado quando o usuário toca o botão de Análise de código pela primeira
vez (`TopicStudyView`). Usa prioridade **`.userBlocking`** na primeira
geração (o usuário está literalmente esperando o botão liberar) — mesma
prioridade já usada para outros fluxos síncronos, só aplicada a um
gatilho novo. Reposições seguintes (top-up pós-sessão) continuam com
`.nextSession`/`.poolFill`, sem mudança.

### 3. Estado de loading para a primeira abertura da seção

O padrão visual já existe: botão desabilitado com `.opacity(0.4)`
enquanto o pool está vazio (`TopicStudyView.swift:303-304`). A mudança é
que esse estado "vazio, aguardando" passa a ser o NORMAL na primeira
visita (hoje é raro). Reforça a importância de `GenerationStage`
(`PLAN_06`) acompanhar esse estado para não parecer quebrado — adicionar
`.generatingCodeAnalysis` (já previsto no enum de `PLAN_06`) como o
estado ativo durante essa espera.

## O que NÃO alterar nesta etapa

- **Não mudar o comportamento do quiz** (fácil/média/difícil) — continua
  com o padrão "minimum viable pool" atual (`targetEasy/Medium/Hard`
  6/6/6, gerado em background logo após a criação). Esta é uma decisão
  explícita: o código já faz isso razoavelmente bem, não decidido mudar
  (`SOLUTIONS_PLAN.md` §14.2).
- **Não mudar o threshold de refill nem o padrão de top-up** —
  `replenishAfterSession` (`TopicRepository.swift:273-293`,
  `TopicStudyView.replenishAfterSession`,
  `TopicStudyView.swift:376-383`) permanecem como estão.
- **Não implementar geração preditiva** (a 4ª opção da comparação em
  §14.1, "Predictive background generation") — descartada por falta de
  dado de uso real para calibrar a predição.

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §14.1 (comparação completa das 4 estratégias:
pre-generate everything, minimum viable pool, generate-on-first-open,
predictive), §14.2 (escolha híbrida e a justificativa completa — nota
importante: esta mudança é classificada explicitamente como **decisão de
produto com recomendação técnica**, não puramente técnica — "vale a pena
o usuário esperar alguns segundos na primeira vez que abre Análise de
código, em troca de nunca gastar processamento com conteúdo não visto" é
uma escolha de experiência), §14.3 (parâmetros exatos: quantidade
inicial, threshold de refill, prioridade no `GenerationOrchestrator`,
comportamento se o usuário pedir antes do background terminar).

## Instrumentação necessária

Usa `GenerationMetricsStore` de `PLAN_00`. Registrar o tempo entre o
usuário tocar o botão e o pool de análise de código ficar disponível
(latência percebida do novo fluxo) — útil para validar se a experiência
de espera na primeira abertura é aceitável.

## Testes

Validação manual: confirmar que abrir um tópico novo NÃO dispara análise
de código até o botão ser tocado (verificável via `GenerationMetrics`,
nenhum registro de `codeAnalysisDraft`/`codeAnalysisCritique`/
`codeAnalysisFormat` antes do toque); confirmar que tocar o botão gera
com prioridade `.userBlocking` e mostra loading adequado
(`GenerationStage.generatingCodeAnalysis`). Se `PLAN_16` (integration
tests) já existir, adicionar um caso cobrindo esse fluxo com um generator
fake.

## Benchmark, se aplicável

N/A como benchmark de aprovação — é uma **decisão de produto com
recomendação técnica dada** (`SOLUTIONS_PLAN.md` §25, seção "Product
Decisions"). A recomendação técnica é fazer a troca; a palavra final é de
produto. Medir (via `PLAN_00`) o tempo de espera real na primeira
abertura para informar essa decisão de produto, se necessário revisitar.

## Success Criteria

- Abrir um tópico novo não gera nenhum item de análise de código até o
  botão ser tocado pela primeira vez.
- Tocar o botão pela primeira vez dispara geração com prioridade
  `.userBlocking` e a tela mostra um estado de loading claro
  (`GenerationStage`), não uma tela quebrada/vazia sem explicação.
- Reposições subsequentes (top-up pós-sessão) continuam funcionando com a
  prioridade normal, sem mudança de comportamento.

## Rollback

Reverter para o disparo automático em `generateAndPersist`/
`startBackgroundGrowthIfNeeded` — mudança pequena e contida (remove um
gatilho novo, restaura a chamada automática antiga que não foi deletada,
só desativada).

## Resultado esperado

Elimina geração especulativa da análise de código — trabalho de GPU/FM só
acontece para conteúdo que o usuário efetivamente pediu para ver.

## Commit boundary

Um commit cobrindo a remoção do disparo automático + o novo gatilho +
ajuste de `TopicStudyView`.

Suggested commit: `feat: generate code analysis pool on first open instead of speculatively (D8)`

## Próximo plano desbloqueado

`PLAN_14` (benchmark decisivo de modelo — parte da topologia TARGET
completa), `PLAN_16` (integration tests cobrindo este fluxo).

## Claude Model Recommendation

Model:
Claude Sonnet 5 (`claude-sonnet-5`)

Reasoning level:
Medium

Why this model:
Mudança de fluxo moderada envolvendo `TopicRepository` (remoção de
disparo automático, novo gatilho) e `TopicStudyView` (UI reagindo a um
estado novo de "vazio, aguardando primeira geração") — exige entender a
interação entre pool/threshold/prioridade do `GenerationOrchestrator` já
existente, mas não introduz concorrência nova nem mexe em lifecycle
complexo. Bem delimitado o suficiente para Sonnet, não trivial o
suficiente para Haiku.
