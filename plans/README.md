# Execution Map — SOLUTIONS_PLAN.md decomposto em planos executáveis

> Este diretório decompõe `SOLUTIONS_PLAN.md` (fonte de decisão técnica,
> não reavaliada aqui) em unidades de trabalho pequenas, independentes e
> ordenadas pela **ordem real de dependência** — não pela ordem de
> prioridade (§28 do `SOLUTIONS_PLAN.md`, "Final Priority Matrix", é sobre
> VALOR; a ordem abaixo é sobre O QUE PODE SER FEITO QUANDO, derivada do
> grafo de dependência real em §23 + as notas de sequenciamento de §24/§28).
>
> Uso pretendido: `Implemente PLAN_04_X.md` para uma sessão de Claude Code
> que só tem acesso ao repositório + esse arquivo específico (e,
> opcionalmente, `SOLUTIONS_PLAN.md` só para consulta, nunca como fonte de
> redesenho).

## Como a ordem foi determinada

A numeração dos arquivos é uma **ordem topológica válida** do grafo de
dependências real (nenhum plano depende de um número maior). Isso não
significa execução estritamente linear — vários planos são
tecnicamente paralelos entre si (marcados abaixo e na árvore). A ordem
numérica favorece, dentro do espaço de ordens topológicas válidas, a
sequência de VALOR descrita em §28 do `SOLUTIONS_PLAN.md` (medir → safe
wins → remover o maior gargalo → reduzir chamadas/otimizar → decisão de
modelo → testes/limpeza), mas nunca viola uma dependência real para
manter essa preferência.

Duas correções feitas em relação à leitura literal (não redesenho — apenas
reconciliação de uma inconsistência interna) do §23 de `SOLUTIONS_PLAN.md`:

1. **PR 6a + PR 6b tratados como um único plano** (`PLAN_06`) — o próprio
   §28 do `SOLUTIONS_PLAN.md` observa explicitamente que "PR 6b precisa
   ser implementado ANTES ou JUNTO de PR 6a, porque a Fase 1 de PR 6a
   precisa de um lugar pra persistir incrementalmente" e recomenda
   "tratar PR 6a+6b como uma unidade de entrega única na prática". Esta
   decomposição segue essa recomendação literalmente.
2. **Benchmark de modelo dividido em duas etapas temporalmente distantes**
   (`PLAN_05` = construir a ferramenta + baseline do 7B atual;
   `PLAN_14` = rodar a decisão real sob a topologia TARGET) — o §23
   desenha "Model benchmark suite → Seleção de modelo" como um bloco
   logo após o chat template, mas o próprio §8.3 e §24 (PR 10) e §28
   (Stage 5: "sob a topologia já otimizada pelos Stages 2-4") deixam
   explícito que a decisão FINAL de modelo só é válida depois que a
   arquitetura TARGET (MLX fora do caminho síncrono, batching, cache,
   pool sob demanda) já está implementada. `PLAN_05` é a construção da
   ferramenta (não depende de arquitetura, só de instrumentação — pode
   avançar cedo); `PLAN_14` é a corrida decisiva (depende da topologia
   TARGET). Isso não é uma reavaliação da decisão de arquitetura — é
   seguir a própria justificativa mais detalhada do documento em vez da
   versão simplificada do diagrama de §23.

## Execution Map

| Ordem | Plano | Objetivo | Depende de | Desbloqueia | Risco | Modelo Claude |
|---:|---|---|---|---|---|---|
| 00 | `PLAN_00_INSTRUMENTATION` | `GenerationMetrics` — tokens/TTFT/tokens-por-segundo reais (F9/F23, §10) | — | 03, 04, 05, 06, 08(indireto), 09, 11, 12, 13, 14 | Baixo | Sonnet 5 / medium |
| 01 | `PLAN_01_UNIT_TESTS_PURE_FUNCTIONS` | Testes unitários de funções puras já existentes (§21, unit tests) | — | — (cobre regressão do resto, mas não bloqueia nada) | Baixo | Haiku 4.5 / low |
| 02 | `PLAN_02_FIX_FORMAT_HARD_QUESTION_BUDGET` | Corrigir `formatHardQuestion` sem orçamento de token (F8, §13) | — | — | Baixo | Haiku 4.5 / low |
| 03 | `PLAN_03_MLX_CHAT_TEMPLATE_MIGRATION` | Migrar para `UserInput(chat:)`, corrigir duplo template (F5/D7, §19) | 00 | — | Baixo-Médio | Sonnet 5 / medium |
| 04 | `PLAN_04_DECOUPLE_ENSURE_READY` | Desacoplar `rawChunks` de `ensureReady()` no caminho de abertura de tela (F12/D6, §18) | 00 | — | Baixo | Sonnet 5 / medium |
| 05 | `PLAN_05_MODEL_BENCHMARK_HARNESS` | Construir a suíte de 18 prompts + rubrica; rodar baseline contra o 7B atual (§9, PR5) | 00 | 14 | Baixo (ferramenta aditiva) | Sonnet 5 / medium |
| 06 | `PLAN_06_CRITICAL_PATH_PHASED_PERSISTENCE` | Tirar MLX do caminho síncrono; exemplo de código vira FM-only; persistência em Fase 1/Fase 2 + `GenerationStage` (D1 parte 1, D9, PR6a+6b) | 00; recomendado após 02, 03, 04 | 07, 09, 10, 11, 12(seq), 14, 16 | **Alto** (maior mudança arquitetural do documento) | Opus 5 / high |
| 07 | `PLAN_07_MLX_BACKGROUND_UPGRADE_PIPELINE` | Reintroduzir MLX→crítica→formatação como upgrade em background com patch reativo (D1 parte 2, §5 passos 3-8) | 06 | 08, 14, 16 | Alto | Opus 5 / high |
| 08 | `PLAN_08_DETERMINISTIC_QUALITY_GATE` | `DeterministicCodeChecks` + prioridade adaptativa do upgrade (§20, D1 completo) | 07 | 16 | Médio | Sonnet 5 / medium |
| 09 | `PLAN_09_FM_BATCHING` | Batching de formatação FM para quiz difícil e análise de código (D3, §6) | 00; recomendado após 06 | 14 | Médio (benchmark-gated na decisão de manter) | Sonnet 5 / medium |
| 10 | `PLAN_10_ON_DEMAND_CODE_ANALYSIS_POOL` | Análise de código muda de especulativa para `generate-on-first-open` (D8, §14) | 06 | 14, 16 | Médio (decisão de produto) | Sonnet 5 / medium |
| 11 | `PLAN_11_MLX_KV_CACHE` | Cache de prefixo MLX entre as 3 chamadas de um tópico, protótipo + benchmark (D4, §7) | 06, 00 | 14 | Médio-Alto (HYPOTHESIS, padrão de clone não documentado) | Opus 5 / high |
| 12 | `PLAN_12_GPU_MEMORY_TUNING` | Calibrar `GPU.set(cacheLimit:)` por medição, não valor mágico (§11) | 00; recomendado após 06, 07 | 14 (parcialmente) | Baixo | Sonnet 5 / low |
| 13 | `PLAN_13_RUNTIME_EXPERIMENTS` | Experimento de concorrência FM>1 (medição only, sem implementar) + decisão de warm-up de inferência (§12, §15.4) | 00 | — | Baixo (não toca produção sem gate) | Sonnet 5 / medium |
| 14 | `PLAN_14_MODEL_BENCHMARK_DECISION` | Rodar a suíte do `PLAN_05` sob a topologia TARGET completa (7B vs. 14B) e registrar a decisão (D2, §8, §9) | 05; recomendado após 06, 07, 09, 10, 11 | 15 | Médio (decisão de produto/qualidade) | Opus 5 / medium |
| 15 | `PLAN_15_CONDITIONAL_MODEL_SWITCH` | Trocar `modelID` para 14B — **SOMENTE SE** `PLAN_14` recomendar | 14 (condicional — pode resultar em "não executar") | — | Baixo (1 linha, reversível) | Haiku 4.5 / low |
| 16 | `PLAN_16_INTEGRATION_TESTS` | Testes de integração: Fase1/Fase2, dedup, top-up, invalidação (§21, PR11 parte integration) | 06, 07, 10 | — | Baixo | Sonnet 5 / medium |
| 17 | `PLAN_17_DEBUG_SCREENS_CLEANUP` | Remover/mover as 3 telas de debug da navegação de produção (F18) | — (tecnicamente livre; recomendado por ÚLTIMO — essas telas validam 04/06/09/10/11) | — | Baixo | Haiku 4.5 / low |

## Árvore de dependências (fluxo)

```text
PLAN_00 (Instrumentação)
├── PLAN_01 (Unit tests)                          [paralelo, sem dependência real]
├── PLAN_02 (Fix formatHardQuestion)               [paralelo, sem dependência real]
├── PLAN_03 (Chat template)                        [paralelo a 02/04]
├── PLAN_04 (Decouple ensureReady)                 [paralelo a 02/03]
├── PLAN_05 (Model benchmark harness + baseline)   [paralelo a 02/03/04/06+ — só precisa de 00]
│   └── PLAN_14 (Model benchmark decision) ────────┐
├── PLAN_13 (Runtime experiments)                  [paralelo a tudo — só precisa de 00]
└── PLAN_06 (Critical path + phased persistence)   ← maior mudança, depende de 00
    │        (sequenciar depois de 02/03/04 por conflito de arquivo, não por dependência dura)
    ├── PLAN_07 (MLX background upgrade)
    │   └── PLAN_08 (Deterministic quality gate)
    ├── PLAN_09 (FM batching)                      [paralelo a 07/08/10/11]
    ├── PLAN_10 (On-demand code analysis pool)      [paralelo a 07/08/09/11]
    ├── PLAN_11 (MLX KV cache)                      [paralelo a 07/08/09/10]
    ├── PLAN_12 (GPU memory tuning)                 [paralelo, recomendado após 07]
    ├── PLAN_16 (Integration tests) ← também depende de 07 e 10
    └── (07, 09, 10, 11 alimentam) ──────────────→ PLAN_14 (Model benchmark decision)
                                                          │
                                                          ▼
                                                   PLAN_15 (Conditional model switch)
                                                   [SOMENTE SE PLAN_14 recomendar 14B]

PLAN_17 (Debug screens cleanup) — sem dependência técnica dura, mas
executar por ÚLTIMO (as telas de debug são a ferramenta de validação
manual usada em 04, 06, 09, 10, 11, 14 — removê-las cedo elimina a rede
de segurança de validação desses planos).
```

**Paralelizável com múltiplas sessões, se desejado**: `{01, 02, 03, 04, 05,
13}` podem rodar todos em paralelo logo após `PLAN_00`. Depois de
`PLAN_06`, o grupo `{07→08, 09, 10, 11, 12}` é internamente paralelo
(exceto 08 que depende de 07). `PLAN_16` espera 07 e 10. `PLAN_14` espera
o conjunto relevante de otimizações (05, 06, 07, 09, 10, 11) ter pousado.
O fluxo default recomendado, no entanto, é sequencial
(`PLAN_00 → validar → commit`, `PLAN_01 → validar → commit`, ...),
seguindo a ordem numérica — que já é uma ordem topológica válida.

## Convenção de rótulos preservada de SOLUTIONS_PLAN.md

Cada plano abaixo preserva literalmente os rótulos de evidência do
documento-fonte: **CONFIRMED** / **HIGHLY LIKELY** / **HYPOTHESIS**,
**NÃO ALTERAR**, **benchmark-gated**, **decisão de produto**. Nenhum plano
transforma uma hipótese em decisão definitiva, nem implementa uma
otimização condicional antes do experimento que a justifica.
