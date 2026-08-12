# PLAN_03 — Migração do chat template MLX (UserInput/Chat.Message)

## Objetivo

Substituir a string ChatML manual construída à mão em `MLXService.generate`
por `UserInput(chat: [Chat.Message])`, a API real e correta do
`mlx-swift-examples` (`MLXLMCommon`) para aplicar o template do modelo.
Corrige um provável duplo-template (achado novo desta análise).

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` F5/D7/§19: `MLXService.swift:321` monta manualmente
uma string `<|im_start|>system\n...<|im_end|>\n<|im_start|>user\n...` e
passa isso como conteúdo de UMA mensagem `.user` via `UserInput(prompt:)`.
Achado confirmado nesta sessão por leitura direta de
`UserInput.swift` (linha ~186-198): `UserInput(prompt:)` internamente
converte a string em `.chat([.user(prompt, ...)])` — ou seja, mesmo o
"caminho simples" passa pelo mecanismo de chat/template. Isso significa
que o processor do modelo aplica o template REAL por cima da string
ChatML já escrita à mão, resultando em marcadores duplicados/aninhados
(`HIGHLY LIKELY`, não confirmado em runtime nesta sessão — por isso este
plano inclui um teste de equivalência obrigatório antes de remover a
string manual). Classificado como **Safe Win** (§25): não depende de
benchmark de decisão, mas depende de um teste de equivalência de
CORREÇÃO (§19.4).

## Estado esperado antes de começar

`PLAN_00` (`GenerationMetrics`) já implementado e funcional —
especificamente, `promptTokenCount` via `GenerateCompletionInfo` precisa
estar disponível para o teste de equivalência deste plano (passo 2 abaixo)
comparar contagem de tokens de entrada antes/depois. Se `PLAN_00` ainda
não foi feito, implementá-lo primeiro (é uma dependência real, não
apenas recomendada — ver `SOLUTIONS_PLAN.md` §23).

## Dependências

`PLAN_00` (precisa de `GenerateCompletionInfo.promptTokenCount` real para
o teste de equivalência).

## Arquivos provavelmente afetados

- `Services/MLXService.swift` (função `generate`, linhas 316-342)

## Mudanças a implementar

### 1. Substituir a construção manual de string ChatML

Remover a montagem de `fullPrompt` como string `<|im_start|>...` manual.
Construir em vez disso `UserInput(chat: [.system(systemPrompt),
.user(promptContext)])`, usando `Chat.Message.system(_:)` e
`Chat.Message.user(_:)` (API real confirmada, `Chat.swift`). Processar via
`context.processor.prepare(input: userInput)` — mesmo ponto de entrada já
usado hoje (`MLXService.swift:326`), só muda o que é passado para ele.

### 2. Rodar o teste de equivalência (§19.4) ANTES de remover o caminho antigo

Rodar os 18 prompts de `PLAN_05` (ou, se `PLAN_05` ainda não existir,
pelo menos os 3 tópicos reais do dataset com variações de tarefa) nos DOIS
caminhos (string manual atual vs. `UserInput(chat:)` novo) no mesmo
modelo. Comparar: (a) `promptTokenCount` — hipótese: o caminho novo tem
MENOS tokens de entrada por eliminar a duplicação; (b) qualidade da saída
por inspeção manual — não deveria piorar.

### 3. Remover a string manual só se o teste de equivalência passar

Success criteria do teste (ver seção própria abaixo) precisa passar antes
do commit final. Se não passar, ver Rollback.

## O que NÃO alterar nesta etapa

- Não mexer em `GenerateParameters` (`temperature: 0.3,
  repetitionPenalty: 1.1`) — isso é um assunto separado (F28,
  explicitamente de prioridade P3 em `SOLUTIONS_PLAN.md`, não faz parte
  deste plano).
- Não adicionar suporte a `cache:` externo aqui — isso é `PLAN_11` (KV
  cache), que depende deste plano estar concluído primeiro é FALSO — na
  verdade `PLAN_11` é independente deste na cadeia formal, mas ambos
  tocam `MLXService.generate`; recomenda-se implementar este plano
  primeiro para reduzir conflito de merge, mesmo sem dependência dura.
- Não mudar o `itemSeparator`/parsing de lote (`MLXService.swift:52,
  230-233`) — fora de escopo.

## Implementação detalhada

Ver `SOLUTIONS_PLAN.md` §19.1 (API real confirmada via fetch do commit
pinado: `UserInput.init(chat:)`, `Chat.Message.system/user/assistant`),
§19.2 (achado do duplo-template, detalhado), §19.3 (assinatura aproximada
da função `generate` migrada — NÃO implementação completa, usar como
referência de estrutura), §19.4 (protocolo exato do teste de
equivalência), §19.5 (fallback).

```swift
// Estrutura aproximada (não copiar literalmente sem adaptar ao restante
// da função, que também precisa da instrumentação de PLAN_00):
let userInput = UserInput(chat: [
    .system(systemPrompt),
    .user(promptContext),
])
let input = try await context.processor.prepare(input: userInput)
return try MLXLMCommon.generate(input: input, cache: nil, parameters: generateParams, context: context)
```

## Instrumentação necessária

Usa a instrumentação já criada por `PLAN_00` (`promptTokenCount` via
`GenerateCompletionInfo`) — não cria nenhuma instrumentação nova, só
consome a existente para o teste de equivalência.

## Testes

O teste de equivalência do passo 2 acima É o teste deste plano — não é um
`XCTest` automatizado (envolve geração real de modelo, não determinística
o suficiente para um assert de igualdade — mesma razão de
`SOLUTIONS_PLAN.md` §21 sobre não transformar geração probabilística em
unit test). Documentar os resultados (tokens antes/depois, observações de
qualidade) em um comentário de PR ou anexo, não em código.

## Benchmark, se aplicável

Teste de equivalência (§19.4), não um benchmark de decisão de arquitetura
— a migração em si não é opcional/gated: é uma correção de bug (duplo
template desperdiça tokens). O teste serve para CONFIRMAR que a correção
não introduz regressão de qualidade, não para decidir SE fazer a
migração.

## Success Criteria

- `promptTokenCount` do caminho novo é igual ou menor que o do caminho
  antigo, para os prompts testados (hipótese: menor, por eliminar
  duplicação).
- Qualidade da saída (inspeção manual, ou rubrica de `PLAN_05` se já
  existir) igual ou melhor — nenhuma regressão perceptível.
- Nenhum crash ou erro de parsing introduzido pela mudança de API.

## Rollback

Reverter para a string manual — mudança isolada de uma função
(`MLXService.generate`), fácil de reverter sem afetar nenhuma outra parte
do sistema. Acionar rollback se o teste de equivalência mostrar qualquer
regressão de qualidade (improvável, já que a mudança remove ruído, não
adiciona).

## Resultado esperado

F5 corrigido: template real aplicado uma única vez pela biblioteca, sem
duplicação. Prompts de entrada mais curtos (menos tokens desperdiçados) e,
potencialmente, saída de melhor qualidade (menos ruído de marcadores
duplicados confundindo o modelo).

## Commit boundary

Um commit cobrindo a função `generate` migrada, com o resultado do teste
de equivalência documentado na mensagem do PR/commit.

Suggested commit: `fix: use real UserInput(chat:) template API, remove manual ChatML duplication`

## Próximo plano desbloqueado

Nenhum plano depende estritamente deste, mas reduz o desperdício de
tokens em TODAS as chamadas MLX subsequentes (`PLAN_06` em diante).

## Claude Model Recommendation

Model:
Claude Sonnet 5 (`claude-sonnet-5`)

Reasoning level:
Medium

Why this model:
Exige entender e usar corretamente uma API real, mas não trivial, do
`MLXLMCommon` (`UserInput`, `Chat.Message`, `MessageGenerator`) que não é
óbvia por convenção — errar aqui reintroduziria o próprio bug que está
sendo corrigido. Também exige interpretar corretamente o resultado do
teste de equivalência (comparação de tokens/qualidade) antes de decidir
remover o caminho antigo. Não é mecânico o suficiente para Haiku, mas
também não envolve concorrência, lifecycle ou decisão arquitetural que
justifique Opus.
