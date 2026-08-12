# PLAN_15 — Troca condicional de modelo MLX para 14B

## ⚠️ Execução condicional

**Este plano só deve ser executado SE `PLAN_14` tiver registrado a
decisão `RECOMMENDED REPLACEMENT` (14B).** Se `PLAN_14` registrou `KEEP
CURRENT MODEL`, este plano NÃO deve ser executado — encerrar aqui sem
mudança de código. Não implementar "por precaução" ou "já que estamos
aqui" — a troca só é válida com a decisão explícita de `PLAN_14`.

## Objetivo

Trocar `MLXService.modelID`/`estimatedModelBytes` de
`Qwen2.5-Coder-7B-Instruct-4bit` para `Qwen2.5-Coder-14B-Instruct-4bit`.

## Por que esta etapa existe

`SOLUTIONS_PLAN.md` §24 (PR10): "SE o PR 5 (benchmark) + medição sob a
topologia TARGET completa (pós PR 6-9) justificar trocar pra 14B." A
troca em si é trivial (constante) — o trabalho real e a decisão já
aconteceram em `PLAN_14`; este plano é só a execução mecânica da
decisão já tomada. `SOLUTIONS_PLAN.md` §25 (Product Decisions) também
classifica a promoção do 14B a modelo padrão como uma decisão de produto
("vale o download de 8,3 GB adicional pro usuário final") — a
recomendação técnica é fazer, SE o benchmark confirmar, porque o download
de algum modelo grande já é obrigatório de qualquer forma.

## Estado esperado antes de começar

`PLAN_14` concluído com decisão `RECOMMENDED REPLACEMENT` registrada e
documentada (dados do benchmark disponíveis para referência).

## Dependências

`PLAN_14` (condicional — este plano só avança se a decisão for de troca).

## Arquivos provavelmente afetados

- `Services/MLXService.swift:44,49` (`modelID`, `estimatedModelBytes`)

## Mudanças a implementar

### 1. Atualizar `modelID`

Trocar a constante para `mlx-community/Qwen2.5-Coder-14B-Instruct-4bit`.

### 2. Atualizar `estimatedModelBytes`

Trocar para o valor confirmado no histórico do projeto (~8,3 GB, commit
`5f1305a`) — não estimar um novo valor, usar o já confirmado.

### 3. Confirmar que o resto do código é agnóstico ao modelo

Por design (`MLXService.swift:40-44`), o resto do código não deveria
precisar de nenhuma mudança adicional — validar isso é o próprio teste
deste plano.

## O que NÃO alterar nesta etapa

- **Nenhuma outra linha de código** — este plano é deliberadamente
  restrito a uma troca de constante. Qualquer ajuste adicional (ex.
  parâmetros de geração específicos para o 14B) é fora de escopo e, se
  necessário, deveria ser um plano futuro separado com sua própria
  justificativa.
- **Não ajustar `GPU.set(cacheLimit:)`/`memoryLimit`** aqui — se
  `PLAN_12` já rodou, os valores calibrados devem ter sido validados
  contra o 14B em `PLAN_14`; se não, isso é uma lacuna a resolver
  ANTES deste plano, não dentro dele.

## Implementação detalhada

Mudança de 2 constantes em `MLXService.swift`. Ver
`SOLUTIONS_PLAN.md` §24, PR10, e §27 (Plano de rollback, linha "Troca de
modelo") para o contexto completo.

## Instrumentação necessária

Nenhuma nova — a instrumentação de `PLAN_00` já cobre `modelID` como
campo do `GenerationMetrics`, então as métricas pós-troca já ficam
automaticamente rastreadas e comparáveis às do 7B.

## Testes

Rodar um tópico novo completo (síncrono + background) e confirmar que
tudo funciona normalmente com o 14B carregado — sem erro de
compatibilidade, sem crash, sem regressão visível de comportamento.

## Benchmark, se aplicável

Já realizado em `PLAN_14` — este plano não repete o benchmark, só executa
a decisão já tomada.

## Success Criteria

- App compila e roda normalmente com o 14B.
- Um tópico novo é gerado com sucesso ponta a ponta.
- `GenerationMetrics` registra `modelID` como o 14B corretamente.

## Rollback

Reverter a constante — **1 linha**, o resto do código já é agnóstico ao
`modelID` por design (`MLXService.swift:40-44`). Acionar rollback se:
o benchmark do §9 (via `PLAN_14`, se rodado novamente em produção) mostrar
hallucination (veto duro), OU `GPU.snapshot()` mostrar pressão de memória
sustentada em uso real (não só no ambiente de benchmark de `PLAN_14`).
Cache de embeddings e pool já gerado com o modelo anterior NÃO precisam
ser invalidados num rollback — o conteúdo persistido não referencia o
modelo que o gerou (`DatasetVersion` não muda).

## Resultado esperado

Modelo de produção atualizado para o 14B, com qualidade superior
confirmada por dado real (não hipótese), sem regressão de memória.

## Commit boundary

Um commit trivial cobrindo as 2 constantes alteradas.

Suggested commit: `feat: switch MLX model to 14B (benchmark-approved, see PLAN_14)`

## Próximo plano desbloqueado

Nenhum.

## Claude Model Recommendation

Model:
Claude Haiku 4.5 (`claude-haiku-4-5-20251001`)

Reasoning level:
Low

Why this model:
É literalmente a troca de 2 valores de constante, com a decisão e
justificativa já completamente resolvidas em `PLAN_14`. Não há nenhuma
ambiguidade ou julgamento a fazer aqui — é execução mecânica de uma
decisão já tomada.
