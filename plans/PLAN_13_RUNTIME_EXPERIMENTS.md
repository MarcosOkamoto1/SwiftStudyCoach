# PLAN_13 — Runtime Experiments: concorrência Foundation Models + warm-up MLX

## Objetivo

Dois experimentos de medição, isolados da produção, que produzem uma
DECISÃO registrada mas não implementam nenhuma mudança de produção a
menos que o próprio experimento a justifique explicitamente:

1. Determinar se o Foundation Models aceita ≥2 sessões
   `LanguageModelSession` concorrentes sem erro, e se o throughput
   agregado melhora o suficiente para justificar aumentar a profundidade
   da fila `.poolFill` do `GenerationOrchestrator` além de 1.
2. Medir se a 1ª chamada MLX de uma sessão do app é significativamente
   mais lenta que a 2ª/3ª (compilação/JIT de kernels Metal), para decidir
   se vale a pena implementar um warm-up de inferência.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F22/§15.4 (concorrência): a resposta padrão do
documento é manter 1 worker FM + 1 worker MLX — mas o documento é
explicitamente convidado a considerar concorrência FM>1 para
`.poolFill`, com a condição clara de **não implementar sem o experimento
rodar primeiro**. F24/§12 (warm-up): `HYPOTHESIS` não confirmável sem
medir — `prewarmIfCached` (`MLXService.swift:299-314`) só carrega pesos,
não há warm-up de inferência real hoje. Ambos são agrupados neste plano
por serem investigações pequenas, isoladas, que produzem uma decisão sem
tocar produção por padrão.

## Estado esperado antes de começar

`PLAN_00` implementado (`GenerationMetrics` necessário para medir TTFT/
tokens-por-segundo da 1ª vs. 2ª/3ª chamada MLX, e para caracterizar taxa
de erro nas chamadas FM concorrentes).

## Dependências

`PLAN_00`.

## Arquivos provavelmente afetados

- Novo, isolado de produção: um harness de experimento (build de debug
  separada, NÃO integrado ao `GenerationOrchestrator` de produção) para
  a Parte 1 (concorrência FM).
- `Services/MLXService.swift` — SOMENTE se a Parte 2 (warm-up) for
  justificada pela medição: adicionar `warmUp()` chamado ao final de
  `performLoad` (ver critério de decisão abaixo). Se não for justificada,
  este plano não altera nenhum arquivo de produção.

## Mudanças a implementar

### 1. Experimento de concorrência FM (medição, NÃO implementação em produção)

Numa build de debug isolada (não no `GenerationOrchestrator` de
produção), disparar N `LanguageModelSession(...).respond(to:...)`
simultâneas (`Task` paralelas, sem passar pela fila) para N = 2, 3, 4.
Registrar, por N: taxa de erro `concurrentRequests`/`rateLimited`
(`LanguageModelSession.GenerationError`, já tratado em
`StudyGeneratorError.describe`, `StudyGenerator.swift:39-65` — não
precisa de código novo para RECONHECER o erro, só para provocá-lo de
propósito), tempo total até todas completarem vs. o mesmo N de chamadas
rodando em série (baseline atual). Repetir em pelo menos 10 rodadas por N
(comportamento sob carga costuma ser não-determinístico).

### 2. Medir 1ª vs. 2ª/3ª chamada MLX de uma sessão do app

Usando a instrumentação de `PLAN_00` (`promptTime`/`tokensPerSecond`
reais via `GenerateCompletionInfo`), comparar a 1ª chamada MLX real de
uma sessão do app com a 2ª/3ª. Rodar várias sessões (reiniciar o app
entre medições) para ter uma amostra representativa.

### 3. Aplicar os critérios de decisão (não implementar além do que os
dados justificarem)

Ver seção "Success Criteria" abaixo para os critérios exatos de cada
experimento.

## O que NÃO alterar nesta etapa

- **Não implementar concorrência FM>1 no `GenerationOrchestrator` de
  produção** a menos que o experimento mostre taxa de erro ~0% E ganho de
  tempo proporcional (não marginal) — e mesmo assim, isso viraria um
  PLANO FUTURO SEPARADO (fora do escopo de execução deste plano, que é só
  o experimento + decisão registrada), nunca implementado como parte
  deste mesmo commit.
- **Não implementar warm-up de inferência com um prompt "fake"** (ex.
  "oi") — se o warm-up for justificado, o prompt mínimo deve ser
  literalmente o mesmo prefixo que `PLAN_11` (cache de prefixo) já primeia
  na primeira chamada MLX real de qualquer tópico — não introduzir um
  mecanismo novo, só adiantar um que já existe no design (se `PLAN_11` já
  estiver implementado; se não, ver nota de sequência abaixo).
- **Não rodar warm-up se os pesos não estiverem em cache local** — mesma
  guarda condicional que já existe em `prewarmIfCached`
  (`MLXService.swift:299-314`, "sem download não-solicitado").
- **Não competir por CPU com o launch inicial** — manter qualquer warm-up
  em `Task.detached(priority: .utility)`, nunca no caminho de
  `RootTabView.task`.

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §15.4 (desenho completo do experimento de
concorrência: objetivo, desenho, critério de decisão, por que não fazer
isso já), §12.1-§12.5 (warm-up: o que já existe vs. o que não existe,
se é necessário, qual prompt mínimo, quando executar, quando NÃO
executar, impacto energético, como não deixar a inicialização do app mais
lenta).

**Nota de sequência para a Parte 2 (warm-up)**: se `PLAN_11` (KV cache)
ainda não tiver sido implementado quando este plano rodar, o warm-up
justificado por este experimento pode usar um prompt mínimo genérico
(ex.: o mesmo prefixo de RAG do primeiro tópico do dataset) em vez do
cache de prefixo formal de `PLAN_11` — não bloquear este plano esperando
`PLAN_11`, mas preferir reusar a infraestrutura de `PLAN_11` se ela já
existir.

## Instrumentação necessária

Usa `GenerationMetricsStore` de `PLAN_00` para ambas as partes. Nenhuma
instrumentação nova além da já prevista.

## Testes

Não há `XCTest` determinístico aplicável — ambos são experimentos de
medição sob condições reais/simuladas de carga, não comportamento
determinístico.

## Benchmark, se aplicável

**SIM, os dois — este plano é inteiramente benchmark-gated por design**:
nenhuma mudança de produção acontece sem o experimento correspondente
rodar primeiro e satisfazer o critério de decisão.

## Success Criteria

**Parte 1 (concorrência FM)**:
- Se taxa de erro para N=2 for materialmente >0% em uso realista (ex. >5%
  das tentativas): **não implementar** — documentar a decisão de manter
  serial e encerrar esta parte do plano aqui.
- Se taxa de erro for ~0% E o tempo total melhorar de forma proporcional
  (não apenas marginal) em relação à execução serial: registrar a
  recomendação de elevar a fila `.poolFill` para profundidade 2 como um
  PLANO FUTURO separado (não implementado por este plano).
- Se melhorar mas com taxa de erro não-trivial: registrar a opção de
  profundidade 2 com retry automático como possibilidade, mas sinalizar
  que só vale se o ganho for grande (complexidade real adicional).

**Parte 2 (warm-up)**:
- Se a diferença 1ª-vs-2ª-chamada for pequena (compilação de grafo Metal
  já rápida o suficiente): não implementar warm-up — aceitar que a
  primeira chamada MLX de cada sessão é um pouco mais lenta (já roda em
  background, D1/D5, custo extra não sentido diretamente pelo usuário).
- Se a diferença for grande e mensurável: implementar `warmUp()` conforme
  §12.3, rodando imediatamente após `loadModel()` completar, com as
  guardas condicionais descritas.

## Rollback

Parte 1: nenhuma mudança de produção foi feita (experimento isolado) —
não há o que reverter, exceto remover o harness de experimento em si
(zero risco). Parte 2, se implementada: remover a chamada de `warmUp()` —
mudança pequena e contida.

## Resultado esperado

Uma decisão registrada e fundamentada em dado real para cada experimento
— possivelmente "não implementar nada" para um ou ambos, o que é um
resultado válido e esperado, não uma falha do plano.

## Commit boundary

Um commit cobrindo o harness de experimento (Parte 1, isolado) + a
decisão registrada de ambas as partes (documentação, não necessariamente
código de produção) + `warmUp()` SE E SOMENTE SE a Parte 2 justificar.

Suggested commit: `chore: run FM concurrency + MLX warm-up experiments, record decision`

## Próximo plano desbloqueado

Nenhum plano depende estritamente deste. Se a Parte 1 justificar
concorrência FM>1, isso vira um plano futuro separado (fora deste
diretório, a ser criado só se os dados justificarem).

## Claude Model Recommendation

Model:
Claude Sonnet 5 (`claude-sonnet-5`)

Reasoning level:
Medium

Why this model:
Desenhar um harness de experimento isolado (que precisa evitar
interferir com a fila de produção) e interpretar corretamente a taxa de
erro/timing sob carga não-determinística exige mais cuidado que uma
tarefa mecânica — mas o escopo é pequeno e bem delimitado (não é uma
mudança arquitetural, é uma medição isolada), não justificando Opus.
