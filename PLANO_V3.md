# Plano V3 — Consolidado executável (substitui o PLANO_V2)

Decisões de produto fechadas nas discussões:

- **Busca livre sai; lista curada entra** — todo caminho passa pelo RAG com grounding garantido; o motor de busca (`hybridSearch`) fica, só o TextField morre
- **Walkthrough fica** (diferencial de aprendizado); **flashcards saem** (redundantes com o quiz)
- **Dataset cresce de 3 → 21 tópicos** em trilha de 3 blocos
- **Gerar menos, gerar na hora certa** — pools reduzidos + reabastecimento por uso

---

## Fase 1 — Fluxo de geração enxuto (constantes + remoção)

### 1.1 Metas de pool: 53 → 24 questões

Em `TopicRepository`: `targetEasy/Medium/Hard/CodeAnalysis` = **6 / 6 / 6 / 6**. Duas sessões sem repetição perceptível; corte de ~55% na geração.

### 1.2 Lote inicial = o que a 1ª sessão consome

Caminho síncrono: **3 fácil + 4 média** (era 4+4). Difícil chega do MLX em background; `sampleQuiz` já repete enquanto não chega.

### 1.3 Remover flashcards

Apagar: `generateFlashcards` (StudyGenerator), `Flashcard`/`FlashcardBatch` (StudyModels), `PersistedFlashcard` + relationship no `StudyTopic` + registro nos `modelContainer` (App e Previews), `FlashcardsView`, case `.flashcards` do `ActiveSheet`, pill e actionRow na `TopicStudyView`. Caminho síncrono final: resumo → exemplo com walkthrough → 2 lotes de quiz.

---

## Fase 2 — Home curada + dataset de 21 tópicos

### 2.1 StudyHomeView sem busca livre

Trocar o TextField por **cards/chips de tópicos derivados do dataset** (`PlaceholderDocs.rawChunks` → tópicos únicos, na ordem dos blocos). Nada hardcoded na view: adicionar chunk novo ao dataset = tópico aparece sozinho na home. Manter a seção "tópicos já estudados" (`@Query` existente).

### 2.2 Estrutura de trilha

Adicionar metadado de bloco ao dataset (ex: `(topic, block, text)` ou enum `TrackBlock`). Home agrupa em 3 seções:

**Bloco 1 — Fundamentos (9):** Guard *(já existe)*, Optionals, Closures, Structs vs Classes, Enums e Pattern Matching, Protocolos, Tratamento de Erros, Coleções (Array/Dictionary/Set), Property Observers e Computed Properties

**Bloco 2 — Intermediário (5):** Generics, Extensions, ARC e Gerenciamento de Memória, async/await, Actors

**Bloco 3 — SwiftUI (7):** Property Wrappers *(já existe)*, NavigationStack *(já existe)*, Ciclo de vida e identidade de Views, Listas e ForEach, Modificadores e Layout, Sheets e Navegação Modal, Animações

### 2.3 Escrita dos 18 tópicos novos (o maior esforço — ~1 dia)

Padrão por tópico: **2-3 chunks de 200-250 palavras**, parafraseados da documentação oficial, com ângulos distintos — (a) conceito, (b) API/uso, (c) erros comuns/pegadinhas. O campo `topic` usa o nome EXATO da lista acima (é o que o boost da busca híbrida casa). Priorizar chunks "ricos em código descritível" — alimentam walkthrough, quiz difícil e análise de código.

### 2.4 `DatasetVersion` → v4

Um único bump ao final da fase (invalida os 3 tópicos antigos junto com a remoção dos flashcards da Fase 1 — fazer as duas fases antes de subir a versão).

### 2.5 `recommendedNextTopic` restrito à base

Hoje o feedback pode recomendar tópico que não existe. Corrigir: passar a lista de tópicos válidos no prompt do `generateFeedback` ("recomende um destes: ...") e, na `StudyResultView`, só tornar a recomendação clicável se ela existir no dataset (match normalizado; senão, mostrar sem link ou mapear pro mais próximo via `hybridSearch`).

---

## Fase 3 — Qualidade das questões

### 3.1 `QuestionValidator` (novo, `Services/`)

Aplicado a TODA questão antes de persistir (quiz e análise de código):

**Sanitização** (corrige silenciosamente): remove resíduos ```` ``` ````, `PERGUNTA:`, `RESPOSTA CORRETA:`, `CODIGO:`, prefixos "1)" / "Alternativa X:" nas opções; trim geral.

**Validação** (rejeita): 4 opções (5 na análise), não-vazias e distintas entre si; `correctOptionIndex` no range; enunciado ≥ 15 chars sem terminar cortado; detecção de fallback genérico (comparação com os textos fixos conhecidos) → **fallback nunca entra no pool**.

**Política**: 1 regeneração; se falhar de novo, descarta (o top-up da Fase 4 repõe).

### 3.2 Gate de contexto com sinal duplo (endurecimento barato)

No `hybridSearch`, o corte relaxado (score ≥ 0.30) só aceita chunk que tenha **também** sinal léxico (overlap > 0) ou boost de tópico ativo. Racional: contexto errado é pior que vazio — semântica sozinha entre textos do mesmo domínio gera falso positivo. Com a home curada isso é cinto de segurança, não feature; 3 linhas de mudança.

---

## Fase 4 — Evolução do crescimento (depois de validar 1-3)

### 4.1 Top-up pós-sessão

Trocar "encher pool até a meta na 1ª visita" por repor o consumido ao fim de cada quiz (`replenishAfterSession(topic:consumed:)` chamado no fechamento do sheet), mantendo buffer de 1-2 sessões. O pool cresce com uso real.

### 4.2 `GenerationOrchestrator` (actor)

Fila serial por motor (FM e MLX separados, paralelos entre si) com 3 prioridades: user-blocking > próxima sessão > pool-fill. Elimina `rateLimited` por design, substitui os retries de contenção, dá ponto único de cancelamento. Maior refactor do plano — por último, com o fluxo já estável.

### 4.3 Pré-aquecimento MLX

No launch: se o modelo já está no cache do Hugging Face (checagem FileManager, sem rede), `loadModel()` em background. Sem download não-solicitado.

---

## Ordem de execução e critérios de aceite

| # | Item | Esforço | Aceite |
|---|------|---------|--------|
| 1 | Fase 1 completa (pools, lote, flashcards fora) | Baixo | Tópico novo abre só com resumo + exemplo + quiz; sem rastro de flashcard no projeto |
| 2 | 2.1 + 2.2 — home curada por blocos | Baixo | Zero texto livre; tópicos vêm do dataset |
| 3 | 2.3 + 2.4 — dataset 21 tópicos + v4 | Alto (escrita) | Todos os tópicos geram com contexto não-vazio e log de cache MISS→salvo |
| 4 | 2.5 — recomendação restrita | Baixo | Feedback nunca recomenda tópico fora da base |
| 5 | Fase 3 — validador + gate | Médio | Nenhuma questão com resíduo de formatação ou fallback no pool |
| 6 | 4.1 — top-up pós-sessão | Médio | Pool repõe após quiz; não gera além do buffer |
| 7 | 4.2 — orchestrator | Alto | Zero `rateLimited` nos logs em uso normal |
| 8 | 4.3 — prewarm | Baixo | 1ª pergunta difícil sem custo de carga |

Itens 1-5 são o pacote da apresentação (produto coeso, dataset real, qualidade consistente). 6-8 são evolução estrutural — valem menção na defesa como roadmap consciente.

Observação de execução: os chunks do item 3 podem ser escritos por IA e **revisados por vocês** (conteúdo técnico precisa de validação humana antes de virar fonte de verdade do RAG).
