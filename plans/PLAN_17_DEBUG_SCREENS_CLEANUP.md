# PLAN_17 — Limpeza de telas de debug da navegação de produção

## Objetivo

Mover (ou remover) as 3 telas de debug hoje presentes na navegação de
produção (`RAGTestView`, `TopicRepositoryTestView`, e a terceira listada
em `RootTabView.swift:13-27`) para um scheme/target de desenvolvimento,
conforme os próprios comentários do código já autorizam
(`RAGTestView.swift:9-10`).

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F18: 3 telas de debug na navegação de produção —
baixo impacto de performance, impacto médio de manutenção/profissionalismo
do produto final. Prioridade explicitamente baixa (P3) em todo o
documento-fonte.

## Estado esperado antes de começar

**Recomendado fortemente executar este plano por ÚLTIMO**, depois de
`PLAN_04`, `PLAN_06`, `PLAN_09`, `PLAN_10`, `PLAN_11`, `PLAN_14`
implementados e validados — essas telas de debug (especialmente
`TopicRepositoryTestView` e `RAGTestView`) são a ferramenta de validação
MANUAL usada explicitamente por vários planos anteriores (cenário de
race test, status de pool, teste de paridade de RAG). Removê-las cedo
elimina a rede de segurança de validação desses planos antes que eles
tenham sido confirmados estáveis em uso real.

## Dependências

Nenhuma dependência técnica dura — mas fortemente recomendado executar
por último na sequência deste diretório (ver acima).

## Arquivos provavelmente afetados

- `Views/RootTabView.swift` (linhas 13-27, remoção das entradas de
  navegação)
- `Views/ContentView.swift` (qualquer referência às telas removidas)
- `Views/RAGTestView.swift` (mover para target de debug ou remover)
- `Views/TopicRepositoryTestView.swift` (mover para target de debug ou
  remover)

## Mudanças a implementar

### 1. Decidir: mover para scheme de debug vs. remover completamente

Se `PLAN_16` (integration tests) já portou a lógica de
`TopicRepositoryTestView.runRaceTest` para testes automatizados, e se
`PLAN_04` já tem um unit test de paridade para o caminho fuzzy de RAG, a
remoção completa é mais segura (a validação manual já foi substituída por
automatizada). Se algum desses ainda depender só da validação manual via
essas telas, preferir MOVER (não remover) para um scheme de debug,
preservando a capacidade de inspeção manual.

### 2. Remover as entradas de navegação de produção

`RootTabView.swift:13-27` — remover as 3 entradas da navegação principal.

### 3. Mover ou remover os arquivos de view

Conforme a decisão do passo 1.

## O que NÃO alterar nesta etapa

- **Não remover nenhuma lógica de teste/validação que ainda não tenha
  sido portada para automatizado** — se `PLAN_16` não cobriu 100% dos
  cenários que essas telas validavam manualmente, preservar essa
  capacidade (mover, não deletar) até que exista cobertura equivalente.
- **Não remover `DocumentIndex.hybridSearch` nem nenhuma lógica de RAG**
  — isso não faz parte deste plano (decisão D6/Opção B: manter a
  arquitetura, só remover a UI de debug que a exercita manualmente).
- **Não remover a exportação de métricas de `GenerationMetricsStore`**
  (`PLAN_00`) mesmo que o botão de disparo estivesse em
  `TopicRepositoryTestView` — se esse for o caso, mover o botão para
  outro lugar acessível (ex.: um menu de debug condicionado a build
  configuration), não deletar a funcionalidade.

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §22, seção final ("Views/RootTabView.swift,
ContentView.swift, RAGTestView.swift, TopicRepositoryTestView.swift"):
"mover as 3 telas de debug para um scheme/target de desenvolvimento, ou
remover conforme os próprios comentários do código já autorizam".

## Instrumentação necessária

Nenhuma nova.

## Testes

Validação manual: confirmar que `StudyHomeView`→`TopicStudyView` continua
funcionando sem depender de nada exclusivo dessas telas. Se `PLAN_16` já
existir, rodar a suíte completa de testes de integração para confirmar
que nenhuma lógica de produto dependia acidentalmente de código dessas
views.

## Benchmark, se aplicável

N/A.

## Success Criteria

- Navegação de produção não mostra mais as 3 telas de debug.
- `StudyHomeView`→`TopicStudyView`→quiz/análise/resultado continuam
  funcionando normalmente.
- Nenhuma funcionalidade de validação foi perdida sem substituto
  automatizado equivalente.

## Rollback

Reverter — as telas voltam para `RootTabView` (se movidas, não
deletadas, o rollback é trivial; se deletadas, restaurar do histórico de
git).

## Resultado esperado

Navegação de produção limpa, sem telas de debug visíveis ao usuário
final.

## Commit boundary

Um commit cobrindo a remoção/movimentação das 3 telas + ajuste de
`RootTabView`/`ContentView`.

Suggested commit: `chore: remove debug screens from production navigation`

## Próximo plano desbloqueado

Nenhum — este é o último plano da sequência.

## Claude Model Recommendation

Model:
Claude Haiku 4.5 (`claude-haiku-4-5-20251001`)

Reasoning level:
Low

Why this model:
Remoção/movimentação mecânica de views da navegação, sem lógica de
produto envolvida — a única decisão não trivial (mover vs. remover) já
está resolvida neste plano com um critério claro baseado no estado dos
planos anteriores. Tarefa de limpeza bem delimitada, apropriada para
Haiku.
