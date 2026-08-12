# PLAN_05 — MLX Model Benchmark Suite (ferramenta + baseline do 7B)

## Objetivo

Construir a ferramenta de avaliação de modelo MLX (18 prompts + rubrica
ponderada de qualidade) como um script/target de desenvolvimento separado
do app principal, e rodá-la contra o modelo atual (`Qwen2.5-Coder-7B-Instruct-4bit`)
para estabelecer uma baseline. Este plano NÃO decide trocar de modelo —
essa decisão é `PLAN_14`, que roda a MESMA ferramenta sob a topologia
TARGET completa.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` §9/§24 (PR 5): hoje não existe nenhuma forma
sistemática de comparar modelos candidatos além de anedota/histórico de
commits. A suíte é necessária tanto para a baseline atual quanto,
futuramente, para qualquer avaliação de modelo (incluindo re-testar o 7B
se o `mlx-swift-examples` for atualizado de versão). Construir a
ferramenta cedo (dependendo só de `PLAN_00`) permite estabelecer a
baseline do 7B o quanto antes, sem esperar a arquitetura TARGET —
importante porque a baseline sob a topologia ATUAL também é um dado
útil de comparação histórica.

## Estado esperado antes de começar

`PLAN_00` (`GenerationMetrics`) implementado — a suíte depende de
`GenerateCompletionInfo` real (via `PLAN_00`) para métricas de
tokens/TTFT/tokens-por-segundo.

## Dependências

`PLAN_00`.

## Arquivos provavelmente afetados

- Novo: um target de linha de comando separado (ex.
  `SwiftStudyCoachBenchmark`) OU uma extensão da `TopicRepositoryTestView`
  existente — decisão de implementação a tomar no início deste plano
  (ver "Implementação detalhada"), não redesenhada aqui.
- Novo: arquivo(s) com os 18 prompts + rubrica (dados, não lógica de
  produto).
- Nenhuma mudança nos arquivos de produção (`MLXService.swift`,
  `StudyGenerator.swift`, etc.) — este plano só CONSOME as APIs
  existentes, não as modifica.

## Mudanças a implementar

### 1. Definir os 18 prompts representativos

Implementar a tabela exata de `SOLUTIONS_PLAN.md` §9.1 — cobre os 3
tópicos reais do dataset (NavigationStack, Property Wrappers,
async/await) + casos fora do dataset para testar hallucination em
terreno não coberto pelo RAG. Cada prompt deve usar o MESMO formato de
instrução que o código de produção usa hoje (reaproveitar os prompts
reais de `StudyGenerator.swift:243-266,528-536,713-727` como referência
literal, não recriar um formato de benchmark artificial).

### 2. Implementar a rubrica de qualidade ponderada

Ver `SOLUTIONS_PLAN.md` §9.3: API real (peso 30), instruction following
(peso 25), grounding/RAG (peso 20), correção Swift (peso 15), latência
(peso 7), memória (peso 3) — pesos derivados da arquitetura TARGET
(MLX em background, §9.3 nota explícita). Implementar também o **veto
duro** do §9.4: qualquer modelo com ≥1 ocorrência de API inventada nos
prompts 4-7 fica automaticamente abaixo de qualquer modelo com zero
ocorrências, independente do score total.

### 3. Rodar a suíte contra o 7B atual e registrar a baseline

Capturar, por prompt: `load time`, `memory footprint` (deixar como
`Needs runtime measurement` se `PLAN_12`/GPU.snapshot() ainda não
existir — não é bloqueante para este plano), `TTFT`, `prompt tokens`,
`output tokens`, `tokens/sec` (via `GenerateCompletionInfo`, já real
por `PLAN_00`), e as avaliações qualitativas da rubrica (podem exigir
avaliação humana/manual para os critérios não puramente mecânicos —
"API real" e "grounding" tipicamente precisam de revisão humana do
texto gerado, não são checáveis por regex de forma confiável o
suficiente para serem 100% automáticos nesta suíte).

## O que NÃO alterar nesta etapa

- Não trocar `MLXService.modelID`/`estimatedModelBytes` — isso é
  `PLAN_15`, e só acontece SE `PLAN_14` recomendar.
- Não rodar a suíte contra o 14B ainda como parte da DECISÃO final — pode
  ser rodada contra o 14B aqui só como teste exploratório opcional (a
  ferramenta deveria suportar qualquer `modelID`), mas o resultado NÃO é
  a decisão — a decisão formal precisa da topologia TARGET (`PLAN_14`).
- Não modificar nenhum código de produção — este plano é estritamente uma
  ferramenta de desenvolvimento, isolada do app principal.

## Implementação detalhada

Decisão de implementação a tomar no início deste plano (ambas as opções
são válidas per `SOLUTIONS_PLAN.md` §24 PR5): (a) um target de linha de
comando separado que importa os módulos de serviço necessários
diretamente; (b) uma extensão da `TopicRepositoryTestView` existente
(já tem um padrão de log em tela, `TopicRepositoryTestView.swift:295-312`).
Recomenda-se (a) se o projeto suportar um executable target adicional
com baixo esforço de configuração; (b) é mais rápido de integrar mas
mistura ferramenta de benchmark com a navegação de debug do app (que é
candidata a remoção em `PLAN_17`) — se optar por (b), isolar claramente
o código do benchmark de forma que sobreviva à limpeza de `PLAN_17` (ex.:
mover a lógica para um arquivo de serviço separado, só a UI de disparo
fica na `TopicRepositoryTestView`).

Ver `SOLUTIONS_PLAN.md` §9.1 (tabela completa dos 18 prompts), §9.2
(métricas exatas a capturar), §9.3 (rubrica com pesos e justificativas),
§9.4 (regra do veto duro e como declarar um vencedor).

## Instrumentação necessária

Usa `GenerationMetricsStore` de `PLAN_00` diretamente — não cria uma
instrumentação paralela. Se a suíte precisar de uma vista agregada por
modelo (não só por chamada individual), pode estender
`GenerationMetricsStore.summary()` com um filtro por `modelID`, mas isso
é opcional e não bloqueia o plano.

## Testes

A suíte rodando com sucesso contra o 7B é o próprio teste deste plano —
não há um `XCTest` determinístico aplicável (geração de modelo real,
probabilística).

## Benchmark, se aplicável

Este plano É a construção do benchmark. A baseline do 7B resultante deste
plano é o dado de comparação para qualquer avaliação futura, incluindo
`PLAN_14`.

## Success Criteria

- A suíte roda os 18 prompts contra o 7B sem erro, capturando métricas
  reais (não `nil`/`NaN`) para cada prompt.
- O veto duro está implementado e testável (verificar manualmente
  injetando uma resposta simulada com API inventada nos prompts 4-7 e
  confirmando que o modelo cairia abaixo de qualquer concorrente sem
  ocorrências).
- A baseline do 7B fica registrada (arquivo JSON exportado, reaproveitando
  `GenerationMetricsStore.exportJSON()` de `PLAN_00`, ou um relatório
  equivalente) para consulta futura por `PLAN_14`.

## Rollback

É uma ferramenta aditiva, isolada do app principal — reverter é remover
o target/arquivo novo, sem risco para o app.

## Resultado esperado

Capacidade de rodar o benchmark contra qualquer modelo candidato,
baseline real do 7B estabelecida — dados prontos para `PLAN_14` decidir
sobre o 14B sob a topologia TARGET.

## Commit boundary

Um commit cobrindo a ferramenta de benchmark + os 18 prompts + rubrica +
o relatório de baseline do 7B.

Suggested commit: `feat: add MLX model benchmark suite (18 prompts, weighted rubric), baseline 7B`

## Próximo plano desbloqueado

`PLAN_14` (decisão final de modelo, roda esta mesma suíte sob a topologia
TARGET).

## Claude Model Recommendation

Model:
Claude Sonnet 5 (`claude-sonnet-5`)

Reasoning level:
Medium

Why this model:
É majoritariamente construção de ferramenta e dados estruturados (prompts,
rubrica, agregação) — mecânico o suficiente para não precisar de Opus,
mas exige integração cuidadosa com `GenerationMetricsStore` e decisões de
estrutura de projeto (target separado vs. extensão de view de debug) que
vão além de um refactor trivial, então Haiku não é suficiente.
