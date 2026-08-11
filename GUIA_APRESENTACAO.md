# Guia de apresentação — SwiftStudyCoach

## O pitch (30 segundos)

> "O SwiftStudyCoach é um coach de estudos de Swift que roda **100% no dispositivo**: zero servidor, zero custo por requisição, funciona offline e nenhum dado do usuário sai do aparelho. Ele combina **três tecnologias de IA da plataforma Apple** — RAG com embeddings nativos, o Foundation Models framework e um LLM local via MLX — cada uma fazendo o que faz de melhor. O usuário escolhe um tópico e recebe um artigo gerado com base na documentação oficial, um exemplo de código explicado passo a passo, e pratica com quiz e análise de código em três níveis de dificuldade, com feedback personalizado no final."

O gancho que diferencia: **não é um wrapper de API**. É engenharia de IA on-device, com os trade-offs reais que isso implica — e é aí que mora a profundidade técnica pra defender.

---

## A narrativa da arquitetura (contar como um fluxo, não como lista de arquivos)

Conte a jornada de um tópico, camada por camada:

**1. Grounding (RAG) — "o modelo não inventa"**
Dataset curado da documentação oficial (chunks de ~200-250 palavras) → `DocumentIndex` gera embeddings com o `NLContextualEmbedding` nativo (via pacote NaturalLanguageEmbeddings) → busca híbrida: score semântico (cosseno) + léxico (overlap de termos) + boost de tópico, com threshold adaptativo. Embeddings ficam **cacheados em disco** (hash SHA-256 do dataset) — indexa uma vez, abre instantâneo depois.

**2. Geração estruturada (Foundation Models) — "schema é contrato"**
O `StudyGenerator` usa `@Generable`/`@Guide`: o modelo é **obrigado** a devolver structs tipadas — nada de parsear texto livre. O walkthrough do exemplo é o melhor argumento: pedir "comente o código" no prompt era ignorado; **forçar pelo schema** (`ExplainedCodeExample` com passos snippet + explicação) funciona sempre. Prompt engineering ≤ schema engineering.

**3. O pipeline de dois modelos — "cada um no que é bom"**
Perguntas difíceis e análise de código: o modelo do sistema é otimizado pra tarefas rápidas, não pra profundidade técnica. Então um **Qwen2.5-Coder 3B roda localmente via MLX** e gera o *rascunho* técnico (em lote — um prefill para N perguntas), e o Foundation Models *formata* o rascunho no schema de múltipla escolha. Rascunho especialista + formatação estruturada = o melhor dos dois, ainda 100% local.

**4. Persistência e economia (SwiftData) — "gerar é caro, cachear é grátis"**
`TopicRepository`: primeira visita gera e persiste; da segunda em diante é cache HIT sem nenhuma chamada de modelo. `DatasetVersion` invalida o cache quando a base muda. O pool de questões cresce em **background, em duas trilhas paralelas** (FM: fácil/média; MLX: download → difícil/análise), sem travar a UI — escrita atômica pra nunca deixar cache quebrado.

**5. Resiliência — "IA local falha, o app não"**
Erros do Foundation Models são diagnosticados por etapa e causa (janela de contexto, truncamento, rate limit) com **degradação automática**: contexto excedeu → refaz com menos contexto; resposta truncada → retry; orçamento de tokens **escala com o tamanho do lote**. Tela de download com progresso real, velocidade e ETA pro modelo de 1,7 GB.

---

## As 5 decisões que mais impressionam (e o porquê de cada uma)

1. **On-device em vez de API** — privacidade por design, offline, custo marginal zero, latência previsível. E é o caminho que a própria Apple está apontando com Apple Intelligence.
2. **RAG em vez de confiar no modelo** — modelo pequeno alucina API; grounding na doc oficial + instrução conservadora ("não invente o que não está no contexto") controla isso na fonte.
3. **Dois modelos em pipeline em vez de um** — demonstra que você entende os *limites* de cada ferramenta, não só o uso feliz.
4. **Saída estruturada via schema** — elimina parsing frágil; o tipo é o contrato.
5. **Decisões guiadas por evidência** — vocês debugaram por logs (decodingFailure → orçamento de tokens; sequencial → paralelo), e existe um plano de evolução priorizado (PLANO_V2.md). Engenharia iterativa, não achismo.

---

## Perguntas prováveis dos mentores — e como responder

**"Por que não usar a API da OpenAI/Claude? Seria mais simples e melhor."**
> Seria — e foi uma decisão consciente não usar. O objetivo era explorar o stack de IA da plataforma Apple e as restrições reais de on-device: privacidade total, offline, custo zero recorrente. As técnicas que isso exigiu (RAG, orçamento de tokens, pipeline de dois modelos, validação) são exatamente o aprendizado do projeto. Com API, o projeto seria um cliente HTTP.

**"Como você garante a qualidade do conteúdo gerado?"**
> Em camadas: grounding via RAG (o modelo cita a doc, não a memória), schema forçando estrutura, instruções conservadoras, detecção de truncamento com retry, e fallbacks pra degradar com elegância. O próximo passo já está planejado: um validador determinístico que sanitiza e rejeita questões malformadas antes de persistir.

**"E se o modelo de 1,7 GB não baixar / o usuário estiver offline?"**
> O app degrada por design: resumo, exemplo, quiz fácil/média são 100% Foundation Models (sem rede). Só difícil e análise de código dependem do MLX — nascem vazios, crescem em background quando o download conclui, e a UI mostra progresso real com ETA. Nada trava esperando rede.

**"Isso escala pra mais tópicos?"**
> O dataset é a única coisa que cresce — o pipeline é agnóstico. O índice re-embeda só quando o hash muda, a busca é O(n) sobre embeddings em memória (ok até milhares de chunks) e cada tópico é gerado on-demand e cacheado. O gargalo futuro seria o tamanho do índice, e a resposta seria um índice vetorial — mas seria over-engineering pro escopo atual.

**"Por que Qwen-Coder 3B? Por que não maior/menor?"**
> Trade-off medido: o 7B (4,3 GB) era 2,5x o download e ~metade da velocidade; como o rascunho é reformatado pelo Foundation Models depois, a perda de qualidade do 3B é tolerável. O ID do modelo é uma constante — trocar pra A/B é uma linha.

**"Qual a maior limitação hoje?"** (nunca fingir que não há)
> A janela de contexto pequena do modelo on-device — foi nosso bug mais difícil (lotes truncados quebrando o parse do schema). Resolvido com orçamento por item e lotes menores. E o volume de geração especulativa, que já tem plano de correção (top-up pós-sessão, fila com prioridades — PLANO_V2).

**"O que você faria diferente?"**
> Começaria pelo validador de questões e pela fila central de geração desde o dia 1 — os retries espalhados foram remendo pra contenção que uma fila serial por motor elimina por design.

---

## Roteiro de demo (5-7 min)

1. **Console aberto ao lado** — os logs são seu aliado: mostre o `cache de embeddings HIT` no launch (arquitetura visível).
2. Abrir um tópico **novo** → narrar o que está acontecendo em cada fase enquanto gera (RAG → resumo → exemplo → quiz). Mostrar o log `generateAndPersist CHAMADO — só na 1ª visita`.
3. Mostrar o artigo: resumo, pontos-chave, **exemplo com walkthrough numerado** (destaque: "isso é schema, não prompt").
4. Se for primeira execução: **banner de download** com progresso/ETA no próprio artigo.
5. Jogar um quiz rápido → tela de resultado com **feedback gerado** sobre o desempenho real.
6. Sair e reabrir o tópico → **instantâneo** (cache HIT no log). Fechar com: "geramos uma vez, servimos pra sempre".
7. Colinha de segurança: se algo falhar ao vivo, a mensagem de erro diz etapa + causa — mostre isso como feature ("até a falha é diagnosticável").

**Antes da apresentação:** rode o fluxo completo uma vez no mesmo device (modelo baixado, cache quente) e tenha um tópico já gerado como plano B da demo.

---

## Postura de defesa

- **Lidere com o problema** (estudar Swift com conteúdo confiável, privado e offline), não com a tecnologia.
- **Cada "por quê" tem uma resposta de trade-off** — mentores testam se a decisão foi consciente, não se foi perfeita.
- **Admita limitações com plano** — "sabemos, está priorizado no PLANO_V2" vale mais que perfeição fingida.
- **Mostre a evidência** — o debug por logs (decodingFailure → orçamento) é uma história curta e forte de engenharia real.
- Se perguntarem algo que não sabe: "não medimos isso ainda — mediria assim...". Honestidade técnica convence mais que resposta inventada.
