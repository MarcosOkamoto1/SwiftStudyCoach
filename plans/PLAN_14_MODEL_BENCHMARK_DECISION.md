# PLAN_14 — Decisão final de modelo MLX (7B vs. 14B) sob topologia TARGET

## Objetivo

Rodar a suíte de benchmark construída em `PLAN_05` (18 prompts + rubrica
ponderada + veto duro de hallucination) contra o modelo atual
(`Qwen2.5-Coder-7B-Instruct-4bit`) e o candidato de qualidade
(`Qwen2.5-Coder-14B-Instruct-4bit`), agora sob a **topologia TARGET
completa** (MLX fora do caminho síncrono, batching, cache de prefixo,
pool sob demanda já implementados) — e registrar uma decisão explícita:
**KEEP CURRENT MODEL** ou **RECOMMENDED REPLACEMENT**.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` D2/§8.3: a recomendação por default é **KEEP CURRENT
MODEL** (7B) — é o único modelo, além do 14B, com evidência real de
funcionar bem DENTRO deste projeto (sem relato de swap, já validado em
produção). O 14B tem evidência real e própria do projeto de funcionar
(commit `5f1305a`) e de ser qualitativamente melhor em
instruction-following, mas com uma lacuna: nunca rodou sob a carga
combinada MLX+FM residentes simultaneamente, com cache de prefixo também
residente — exatamente a topologia que este documento introduz. A
decisão só é válida "sob a topologia TARGET completa (não isolado)"
(§8.3) — por isso este plano só faz sentido depois que essa topologia
existe de verdade, ao contrário de `PLAN_05` (que só constrói a
ferramenta e mede a baseline, sem decidir nada).

## Estado esperado antes de começar

`PLAN_05` implementado (ferramenta de benchmark + baseline do 7B sob a
topologia ANTIGA já registrada, para comparação histórica). Fortemente
recomendado: `PLAN_06`, `PLAN_07`, `PLAN_09`, `PLAN_10`, `PLAN_11`
implementados — juntos constituem a "topologia TARGET completa" que
`SOLUTIONS_PLAN.md` §8.3/§28 (Stage 5) exigem para esta decisão ser
válida. `PLAN_12` (GPU tuning), se implementado, também deveria estar
ativo durante a medição de memória.

## Dependências

`PLAN_05`. Recomendado fortemente (não tecnicamente bloqueante, mas a
decisão não é válida sem isso, per §8.3): `PLAN_06`, `PLAN_07`, `PLAN_09`,
`PLAN_10`, `PLAN_11`.

## Arquivos provavelmente afetados

- Nenhuma mudança de código de produção — este plano só CONSOME a suíte
  de `PLAN_05` e o app já reestruturado pelos planos anteriores.
- Novo: relatório/documento da decisão (JSON exportado via
  `GenerationMetricsStore.exportJSON()` + um resumo legível, não
  necessariamente um arquivo de código).

## Mudanças a implementar

### 1. Baixar e configurar o candidato 14B para teste

`mlx-community/Qwen2.5-Coder-14B-Instruct-4bit` (~8.3 GB, confirmado no
histórico do projeto, commit `5f1305a`) — usar a mesma infraestrutura de
download/carga já existente em `MLXService`, apontando temporariamente
para o `modelID` do 14B (sem alterar a constante de produção ainda — isso
é `PLAN_15`, condicional ao resultado deste plano).

### 2. Rodar a suíte dos 18 prompts contra AMBOS os modelos, sob a topologia TARGET completa

Capturar `load time`, `memory footprint` (via `GPU.snapshot()`, de
`PLAN_12`), `TTFT`, `prompt tokens`, `output tokens`, `tokens/sec` (via
`GenerateCompletionInfo`, `PLAN_00`), e as avaliações qualitativas da
rubrica — para cada um dos 18 prompts, para cada modelo.

### 3. Aplicar a rubrica ponderada + veto duro (§9.3/§9.4)

Calcular o score ponderado (API real 30, instruction-following 25,
grounding 20, correção Swift 15, latência 7, memória 3) para cada modelo.
**Veto duro**: qualquer modelo com ≥1 ocorrência de API inventada nos
prompts 4-7 fica automaticamente abaixo de qualquer modelo com zero
ocorrências, independentemente do score total.

### 4. Verificar pressão de memória sob carga combinada

`GPU.snapshot()` mostrando `cacheMemory`+`activeMemory` dentro do
`memoryLimit` reportado por `GPU.deviceInfo()`, **sem crescimento
sustentado** ao longo de uma sessão de geração de pool completo — este é
o sinal específico que preencheria a lacuna de evidência do 14B (nunca
testado sob MLX+FM residentes simultaneamente + cache de prefixo).

### 5. Registrar a decisão explicitamente

**KEEP CURRENT MODEL** (7B) se: o 14B não superar o veto duro, OU o
ganho de qualidade não for claro o suficiente para justificar o download
adicional de 8,3 GB, OU houver qualquer sinal de pressão de memória
sustentada. **RECOMMENDED REPLACEMENT** (14B) se: zero ocorrências de API
inventada nos prompts 4-7 para ambos os modelos (ou só o 14B tiver zero,
se o 7B tiver alguma), score ponderado do 14B for maior, E
`GPU.snapshot()` não mostrar pressão de memória sustentada.

## O que NÃO alterar nesta etapa

- **Não trocar `MLXService.modelID`/`estimatedModelBytes`** — isso é
  `PLAN_15`, e só acontece SE este plano recomendar a troca.
- **Não reabrir a hipótese do MoE 30B** — `SOLUTIONS_PLAN.md` D2 é
  explícito: "Não reabrir a hipótese de MoE 30B sem evidência nova de que
  a pressão de memória foi resolvida (nenhuma evidência nova foi
  encontrada nesta sessão)." Este plano não muda essa constatação — nada
  neste plano gera evidência sobre o MoE 30B.
- **Não escolher o vencedor só por tokens/s** — regra explícita do
  documento-fonte; o veto duro de hallucination sempre tem precedência
  sobre o score de latência.
- **Não considerar a Performance Alternative (3B)** como parte da decisão
  principal deste plano — o 3B é uma alternativa para hardware mais fraco
  ou pressão térmica/bateria, avaliada separadamente se necessário, não
  parte do par de comparação 7B-vs-14B deste plano.

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §8.0 (por que a análise de modelo muda com a
Estratégia D — qualidade passa a pesar mais que velocidade bruta, porque
o usuário não sente mais o MLX diretamente), §8.1 (Model Requirements, em
ordem de importância real para este produto), §8.2 (tabela completa de
candidatos, com os números de download/RAM já confirmados no histórico do
projeto), §8.3 (Recommended MLX Model — recomendação padrão e a
justificativa exata de por que a lacuna de evidência do 14B existe),
"Quality Alternative" (mesma seção, com o sinal exato de `GPU.snapshot()`
a observar), §9.2-§9.4 (métricas, rubrica, regra do veto duro).

## Instrumentação necessária

Usa `GenerationMetricsStore` de `PLAN_00` e `GPU.snapshot()` de
`PLAN_12`. Nenhuma instrumentação nova.

## Testes

A própria corrida do benchmark é o teste — não há `XCTest`
determinístico aplicável (geração de modelo real, probabilística).

## Benchmark, se aplicável

**SIM — este plano é inteiramente o benchmark decisivo**, explicitamente
gated pela suíte do §9 rodada sob a topologia TARGET completa (§24, PR10;
§28, Stage 5).

## Success Criteria

- Os 18 prompts rodaram contra ambos os modelos (7B, 14B) sob a topologia
  TARGET completa, com métricas reais capturadas para cada um.
- O veto duro foi aplicado corretamente (nenhuma ocorrência de API
  inventada nos prompts 4-7 é ignorada no cálculo final).
- `GPU.snapshot()` foi verificado sob carga combinada real (não isolada)
  para o 14B.
- Uma decisão explícita e não ambígua foi registrada: **KEEP CURRENT
  MODEL** ou **RECOMMENDED REPLACEMENT**, com a justificativa baseada nos
  dados coletados, não em preferência a priori.

## Rollback

N/A diretamente — este plano não altera código de produção, só produz uma
decisão. Se a decisão for `RECOMMENDED REPLACEMENT` e `PLAN_15` for
executado, o rollback correspondente está descrito em `PLAN_15`.

## Resultado esperado

Modelo final decidido por dado real, não por hipótese ou preferência —
consistente com o princípio geral do documento-fonte de nunca trocar o
que funciona sem provar que a alternativa é melhor.

## Commit boundary

Um commit (ou nenhum, se a decisão for puramente documental sem mudança
de código) cobrindo o relatório da decisão + os dados brutos exportados
(JSON de `GenerationMetricsStore`).

Suggested commit: `docs: record MLX model decision (7B vs 14B) under target topology benchmark`

## Próximo plano desbloqueado

`PLAN_15` (troca condicional de modelo — só executa se este plano
recomendar).

## Claude Model Recommendation

Model:
Claude Opus 5 (`claude-opus-5`)

Reasoning level:
Medium

Why this model:
A execução mecânica do benchmark (rodar prompts, capturar métricas) é
simples, mas a SÍNTESE da decisão final combina múltiplos sinais
concorrentes (score ponderado, veto duro de hallucination, pressão de
memória sob carga combinada, custo de download vs. benefício de
qualidade) numa única recomendação não ambígua — exatamente o perfil de
"decisões condicionais" e "análise de benchmark" citado como caso de uso
de Opus na diretriz de escolha de modelo. Reasoning "medium" (não "high")
porque a estrutura de decisão já está inteiramente especificada em
`SOLUTIONS_PLAN.md` §8.3/§9.4 — o trabalho é aplicar critérios já
definidos a dados novos, não inventar novos critérios.
