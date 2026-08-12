# PLAN_13 — Registro de decisão (Runtime Experiments)

Status: **PENDENTE DE EXECUÇÃO NO DEVICE** — o harness está implementado e
os critérios de decisão estão fixados abaixo; falta rodar no hardware real
(Foundation Models exige Apple Intelligence ativo; MLX exige a GPU Metal da
máquina-alvo) e preencher os resultados. Nenhuma mudança de produção foi
feita — por design, este plano só produz uma decisão registrada.

## Como rodar

Ambos os experimentos vivem na tela de debug `TopicRepositoryTestView`:

- **Parte 1 (concorrência FM)** — seção "8) Concorrência FM". Um toque roda
  N=2,3,4 × 10 rodadas (serial + concorrente, ordem alternada por rodada),
  ≈180 chamadas FM. Rodar com o app ocioso (sem pool crescendo em
  background) e o device na tomada. Exportar o JSON ao final
  (`Documents/fm-concurrency-<ts>.json`).
- **Parte 2 (warm-up MLX)** — seção "9) Warm-up MLX". Protocolo por sessão:
  reiniciar o app → gerar 1 tópico e deixar o background rodar (≥2 chamadas
  MLX depois da 1ª) → tocar "Registrar sessão atual" → repetir em ≥5
  sessões. As amostras acumulam em `Documents/mlx-warmup-sessions.json`.

Código: `Services/FMConcurrencyExperiment.swift` (Parte 1, isolado — não
passa pelo `GenerationOrchestrator` nem grava na `GenerationMetricsStore`) e
`Services/MLXWarmupAnalyzer.swift` (Parte 2, só LÊ as métricas do PLAN_00;
`warmUp()` não foi implementado).

## Parte 1 — Concorrência FM (§15.4)

### Critérios (fixados antes de medir)

| Resultado para N=2 | Decisão |
| --- | --- |
| Taxa de erro `concurrentRequests`/`rateLimited` > 5% | **Não implementar** — manter fila serial, encerrar aqui |
| Erro ~0% (≤1%) E speedup mediano ≥ 1.5x | Registrar **plano futuro separado**: fila `.poolFill` com profundidade 2 (nunca `.userBlocking`). NÃO implementado por este plano |
| Speedup real mas erro não-trivial (1–5%) | Registrar a opção "profundidade 2 + retry automático" como possibilidade — só vale se o ganho for grande |
| Speedup < 1.5x mesmo sem erro | **Não implementar** — ganho marginal não é a melhora "proporcional" exigida |

Interpretações numéricas ("~0%" = ≤1%; "proporcional" = ≥1.5x para N=2)
documentadas também em `FMConcurrencyReport.recommendation`.

### Resultados (preencher após rodar)

| N | Chamadas concorrentes | Taxa erro concorrência | Mediana serial | Mediana concorrente | Speedup mediano | Outros erros |
| --- | --- | --- | --- | --- | --- | --- |
| 2 | _ | _ | _ | _ | _ | _ |
| 3 | _ | _ | _ | _ | _ | _ |
| 4 | _ | _ | _ | _ | _ | _ |

JSON exportado: `_` · Device/OS: `_` · Data: `_`

### Decisão registrada

> _(preencher — a `recommendation` do relatório é a leitura sugerida; a
> decisão final é humana. "Não implementar nada" é um resultado válido e
> esperado, não uma falha do plano.)_

## Parte 2 — Warm-up de inferência MLX (§12)

### Critérios (fixados antes de medir)

- Métrica de comparação: **throughput**, não TTFT bruto — prefill
  (`inputTokenCount / promptTime`) e decode (`tokensPerSecond`). TTFT bruto
  é confundido pelo tamanho do prompt e pelo cache de prefixo do PLAN_11
  (num HIT, a 2ª chamada processa só o sufixo). Ver cabeçalho de
  `MLXWarmupAnalyzer.swift`.
- Amostra mínima: **5 sessões** do app (reiniciando entre elas).
- **Diferença pequena** (razão quente/frio mediana < 1.3 em prefill E
  decode) → **não implementar** warm-up: a 1ª chamada já roda em background
  (D1/D5), o custo não é sentido pelo usuário, e o warm-up custaria uma
  geração real de energia a cada launch (§12.4).
- **Diferença grande** (razão mediana ≥ 1.3 em prefill OU decode) →
  implementar `warmUp()` conforme §12.3: prompt mínimo = o MESMO prefixo
  que o PLAN_11 já prima (nunca um prompt "fake"), rodando imediatamente
  após `loadModel()` completar dentro do `Task.detached(priority: .utility)`
  de `prewarmIfCached`, com a mesma guarda "só com pesos em cache local".
  O PLAN_11 já está implementado, então a nota de sequência do PLAN_13 não
  se aplica — usar o cache de prefixo formal.

### Resultados (preencher após ≥5 sessões)

| Sessões | Razão prefill quente/frio (mediana) | Razão decode quente/frio (mediana) |
| --- | --- | --- |
| _ | _ | _ |

Arquivo acumulado: `Documents/mlx-warmup-sessions.json` · Device/OS: `_` · Data: `_`

### Decisão registrada

> _(preencher. Se justificar warm-up, a implementação de `warmUp()` em
> `MLXService.performLoad`/`prewarmIfCached` entra no MESMO commit boundary
> deste plano — é a única mudança de produção que o PLAN_13 autoriza, e
> SOMENTE se este critério for satisfeito.)_

## Rollback

- Parte 1: remover `Services/FMConcurrencyExperiment.swift` + a seção 8 da
  `TopicRepositoryTestView` (zero risco — nada de produção).
- Parte 2 (analisador): remover `Services/MLXWarmupAnalyzer.swift` + a
  seção 9. Se `warmUp()` vier a ser implementado: remover a chamada de
  `warmUp()` (mudança pequena e contida).
