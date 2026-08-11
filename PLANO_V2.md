# Plano V2 — Fluxo de geração, menos questões e qualidade

Decisão de produto: **o passo a passo (walkthrough) fica como está** — é o diferencial de aprendizado do exemplo. Os **flashcards saem** (mecânica redundante com o quiz).

## Diagnóstico do fluxo atual

Cada tópico novo gera hoje: resumo + exemplo com walkthrough + 8 flashcards + pool de **53 questões** (14 fácil, 13 média, 13 difícil, 13 análise de código). São ~60 gerações por tópico, sendo que uma sessão de quiz consome só 10 (3+4+3) e a análise de código nem sempre é aberta. A maior parte do custo é especulativa — gerar conteúdo que talvez nunca seja usado.

---

## 1. Arquitetura — gerar menos, gerar na hora certa

### 1.1 Metas de pool reduzidas (ganho imediato, mudança trivial)

| Pool | Hoje | Proposto |
|------|------|----------|
| Fácil | 14 | 6 |
| Média | 13 | 6 |
| Difícil | 13 | 6 |
| Análise de código | 13 | 6 |
| Flashcards | 8 | 0 (removidos — ver §2) |

24 questões dão ~2 sessões sem repetição perceptível (o sorteio já embaralha e repete quando falta). Corte de ~55% no volume gerado.

### 1.2 Lote inicial = exatamente o necessário pra 1ª sessão

Hoje o caminho síncrono gera 4 fácil + 4 média. Reduzir para **3 fácil + 4 média** (o que `sampleQuiz` consome; difícil chega do MLX em background e o sorteio repete enquanto não chega). Com flashcards removidos, o caminho síncrono vira: resumo → exemplo com walkthrough → 2 lotes de quiz. Tópico abre ~30-40% mais rápido.

### 1.3 Reabastecimento por uso, não especulativo

Trocar "encher o pool até a meta na 1ª visita" por **top-up pós-sessão**: ao fim de cada quiz, repor em background só o que foi consumido (mantendo o buffer de 1-2 sessões à frente). O pool cresce com o uso real do tópico. Implementação: `TopicRepository.replenishAfterSession(topic:consumed:)` chamado quando o sheet do quiz fecha.

### 1.4 GenerationOrchestrator — fila central com prioridades

Hoje a contenção entre trilhas (FM formatando rascunho MLX × FM gerando quiz) é resolvida com retries espalhados. Arquitetura melhor: um `actor GenerationOrchestrator` com **uma fila serial por motor** (uma pro Foundation Models, uma pro MLX) e 3 níveis de prioridade:

1. **user-blocking** — o que o usuário está esperando na tela (resumo, exemplo, lote da 1ª sessão)
2. **next-session** — buffer da próxima sessão do tópico aberto
3. **pool-fill** — reabastecimento de tópicos não abertos

Elimina `rateLimited` por design (nunca há duas chamadas FM simultâneas), remove os retries de contenção e dá um ponto único pra cancelamento (usuário saiu do tópico → cancela pool-fill pendente). As trilhas FM e MLX continuam paralelas entre si — a serialização é só dentro de cada motor.

### 1.5 Pré-aquecimento do MLX

No launch do app, se o modelo já estiver no cache do Hugging Face (checagem por FileManager, sem rede), chamar `loadModel()` em background — a primeira pergunta difícil não paga a carga na memória. Sem download automático não-solicitado.

---

## 2. Remover flashcards (o walkthrough fica)

Justificativa: flashcards e quiz são a mesma mecânica (retrieval practice) — redundantes entre si — e o quiz é superior no app (tem feedback, dificuldade progressiva e alimenta o resultado da sessão). O par resumo + exemplo com walkthrough cobre o papel de aprendizado; o quiz cobre a prática.

Remoção: `generateFlashcards` e `FlashcardBatch`/`Flashcard` (DTOs), `PersistedFlashcard` (+ relationship no `StudyTopic` e registro no `modelContainer` do App/Previews), `FlashcardsView`, o case `.flashcards` do `ActiveSheet`, o pill e a actionRow de flashcards na `TopicStudyView`. Uma chamada FM a menos no caminho síncrono. Remover propriedade/entidade é migração leve no SwiftData; ainda assim, bump `DatasetVersion` → v4 para regenerar limpo.

*(Alternativa se bater arrependimento: gerar flashcards localmente a partir dos `keyPoints` — pergunta = "Explique: {keyPoint}" — custo zero de geração. Não recomendado agora; só registrar a opção.)*

---

## 3. Qualidade das questões — validação e sanitização

Erros de formatação observados vêm de três fontes: resíduos de markdown/labels do rascunho MLX vazando pro texto final, fallbacks genéricos entrando no pool, e respostas do formatador com estrutura inválida. Correção em camada determinística, sem depender do modelo:

### 3.1 `QuestionValidator` (novo, `Services/`)

Aplicado a TODA questão antes de persistir:

**Sanitização** (corrige silenciosamente):
- Remover resíduos: ```` ``` ````, `PERGUNTA:`, `RESPOSTA CORRETA:`, `CODIGO:`, `Alternativa X:`, numeração "1)" no início de opções
- Trim de espaços/quebras em todos os campos
- Normalizar aspas tipográficas quebradas

**Validação** (rejeita a questão):
- Exatamente 4 opções (5 na análise de código), todas não-vazias e **distintas entre si**
- `correctOptionIndex` dentro do range
- Enunciado com ≥ 15 caracteres e terminando coerentemente (sem cortes)
- Opções sem sobreposição total com o enunciado
- Detectar fallback genérico (comparar com os textos fixos conhecidos) → rejeitar em vez de persistir

**Política de rejeição**: 1 regeneração; se falhar de novo, descarta (pool fica 1 menor — o top-up repõe depois). **Nunca** persistir questão inválida ou fallback.

### 3.2 Fallbacks fora do pool

Hoje o fallback genérico entra no pool persistido e reaparece pra sempre. Com o validador, fallback vira "questão descartada" — o usuário nunca vê alternativas que não têm relação com o enunciado.

---

## 4. Ordem de execução

| # | Item | Esforço | Observação |
|---|------|---------|------------|
| 1 | §1.1 + §1.2 — metas e lote inicial reduzidos | Trivial | Só constantes |
| 2 | §2 — remover flashcards | Baixo | Simplifica caminho síncrono; bump v4 |
| 3 | §3 — QuestionValidator | Médio | Maior impacto na qualidade percebida |
| 4 | §1.3 — top-up pós-sessão | Médio | Muda o modelo de crescimento |
| 5 | §1.4 — GenerationOrchestrator | Alto | Refactor; fazer por último, remove os retries de contenção |
| 6 | §1.5 — pré-aquecimento MLX | Baixo | Qualquer hora |

Itens 1-3 juntos: tópico abre mais rápido, ~55% menos geração e fim das questões quebradas — com o walkthrough intacto. Itens 4-5 são a evolução estrutural.
