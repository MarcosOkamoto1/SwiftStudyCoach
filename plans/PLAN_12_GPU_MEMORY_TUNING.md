# PLAN_12 — MLX GPU Memory Tuning

## Objetivo

Calibrar `MLX.GPU.set(cacheLimit:)` (e, só se necessário,
`memoryLimit`/`withWiredLimit`) por medição real, usando a suíte de
prompts existente, em vez de deixar o comportamento default do sistema
sem nenhuma medição.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F6/§11: nenhum tuning de `MLX.GPU.set(cacheLimit:)`
hoje (grep vazio, reconfirmado). A própria documentação da API MLX (lida
diretamente nesta análise) recomenda benchmark, não um valor fixo:
"the optimal cache size varies significantly by workload... developers
often find that relatively small cache sizes (e.g., 2MB) perform just as
well... The best approach is to experiment with different cache limits
and measure performance for your particular workload." Este plano segue
essa recomendação — não escolhe um valor "mágico".

## Estado esperado antes de começar

`PLAN_00` implementado (precisa de `tokensPerSecond` real via
`GenerateCompletionInfo`). Recomendado: `PLAN_06`, `PLAN_07` implementados
— medir sob a topologia TARGET (MLX rodando em background repetidamente)
é mais representativo do uso real do que medir isoladamente.

## Dependências

`PLAN_00`. Recomendado, não bloqueante: `PLAN_06`, `PLAN_07`.

## Arquivos provavelmente afetados

- `Services/MLXService.swift` (chamada de `GPU.set(cacheLimit:)` no ponto
  de carga do modelo, se o benchmark justificar um valor diferente do
  default)

## Mudanças a implementar

### 1. Adicionar captura de `GPU.snapshot()` na instrumentação

Se `PLAN_00` ainda não capturar `memoryBeforeBytes`/`memoryAfterBytes`
(campos já previstos no struct `GenerationMetrics`, mas deixados `nil` em
`PLAN_00`), popular esses campos agora usando `GPU.snapshot()` (API real:
`activeMemory`, `cacheMemory`, `peakMemory`) antes/depois de operações MLX
relevantes.

### 2. Rodar a suíte de prompts (de `PLAN_05`, se existir, ou os 3
tópicos do dataset) com `cacheLimit` em pelo menos 3 valores

Default (sem alterar), ~2MB (conforme sugestão da própria documentação da
API), e um valor intermediário (ex. 64MB) — medir `tokensPerSecond` (via
`GenerateCompletionInfo`, `PLAN_00`) e `GPU.cacheMemory` pico por valor.

### 3. Escolher o menor valor que não regride `tokensPerSecond`

Cache menor = memória devolvida ao sistema mais cedo, sem custo de
performance — esse é o critério de decisão, não "o maior cache possível"
nem um valor arbitrário.

## O que NÃO alterar nesta etapa

- **Não mexer em `memoryLimit`** a menos que `GPU.deviceInfo().maxRecommendedWorkingSetSize`
  sugira que o default (1.5x) está perto demais do limite físico ao
  rodar o modelo Quality Alternative (14B, `PLAN_14`) simultaneamente com
  Foundation Models residente — não ajustar preventivamente.
- **Não usar `withWiredLimit`** a menos que o benchmark do 14B
  (`PLAN_14`) mostre sinais de pressão de memória wired — mesma classe de
  problema que já causou swap com o MoE de 30B rejeitado
  (`MLXService.swift:7-15`).
- **Não aplicar KV cache quantizado (`kvBits`)** preventivamente — só se
  `PLAN_11` (cache de prefixo) mostrar footprint de memória relevante em
  `GPU.snapshot()`.
- **Não introduzir descarregamento automático do modelo entre usos** —
  decisão explícita de `SOLUTIONS_PLAN.md` §11.4: o modelo fica carregado
  na RAM indefinidamente após o primeiro `loadModel()`, e isso é correto
  para este produto (com MLX rodando repetidamente em background,
  descarregar/recarregar pagaria o custo de carga repetidamente). Só
  reconsiderar se houver pressão de memória sustentada em sessões longas
  com muitos tópicos abertos — nesse caso, a mitigação seria um TTL de
  inatividade, não descarregar a cada uso, e isso é um plano futuro
  separado, não parte deste.

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §11.1 (API real completa: `GPU.snapshot()`,
`GPU.cacheMemory`/`activeMemory`/`peakMemory`, `GPU.set(cacheLimit:)`,
`GPU.memoryLimit`/`GPU.set(memoryLimit:relaxed:)`,
`GPU.withWiredLimit(_:_:)`, `GPU.deviceInfo()`, `GPU.clearCache()` — todas
confirmadas por leitura direta do código-fonte pinado), §11.2 (por que
não escolher valores mágicos — citação direta da documentação oficial),
§11.3 (tabela completa de parâmetros, como medir cada um, critério de
decisão), §11.4 (por que não descarregar o modelo automaticamente).

## Instrumentação necessária

`GPU.snapshot()` capturado antes/depois de operações MLX relevantes,
integrado a `GenerationMetrics` (campos `memoryBeforeBytes`/
`memoryAfterBytes`, já previstos em `PLAN_00`).

## Testes

Não há `XCTest` determinístico aplicável — validação é o próprio
benchmark (medição real de `tokensPerSecond`/`GPU.cacheMemory` por valor
de `cacheLimit`).

## Benchmark, se aplicável

**SIM — todo este plano é benchmark-gated por design**: nenhum valor de
`cacheLimit` é fixado sem medição prévia (regra explícita da própria
documentação da API MLX, reforçada pela regra geral do documento-fonte de
não usar valores mágicos).

## Success Criteria

- `cacheLimit` escolhido é o menor valor testado que não regride
  `tokensPerSecond` de forma mensurável em relação ao default.
- `GPU.snapshot()` mostra `cacheMemory` reduzido (ou igual) ao valor
  default, sem regressão de `tokensPerSecond`.

## Rollback

Remover a chamada de `GPU.set(cacheLimit:)` — volta ao default do
sistema. Risco mínimo (é um parâmetro de tuning, não uma mudança
estrutural).

## Resultado esperado

Valor de `cacheLimit` calibrado por medição, não chute — reduz footprint
de memória sem custo de performance, SE o benchmark confirmar espaço para
essa redução (pode resultar em "manter o default" como conclusão válida).

## Commit boundary

Um commit cobrindo a chamada de `GPU.set(cacheLimit:)` (se justificada
pelo benchmark) + o resultado do benchmark documentado no PR.

Suggested commit: `perf: calibrate MLX GPU cacheLimit via benchmark (or document default is optimal)`

## Próximo plano desbloqueado

`PLAN_14` (benchmark decisivo de modelo — mede memória sob a topologia
TARGET completa, incluindo qualquer tuning deste plano).

## Claude Model Recommendation

Model:
Claude Sonnet 5 (`claude-sonnet-5`)

Reasoning level:
Low

Why this model:
É essencialmente um sweep de configuração + medição — mecânico o
suficiente para não precisar de raciocínio profundo, mas exige entender
corretamente a API real de `GPU.snapshot()`/`GPU.set(cacheLimit:)` e
interpretar os resultados numéricos para escolher o valor certo (não é
uma tarefa 100% mecânica de "copiar padrão existente", como PLAN_02).
Reasoning "low" porque a decisão final é aritmética simples sobre dados
medidos, não uma escolha de design.
