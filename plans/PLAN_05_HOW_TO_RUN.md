# PLAN_05 — Como rodar a suíte e gerar a baseline do 7B

A ferramenta (`Services/BenchmarkPrompts.swift` + `Services/ModelBenchmarkSuite.swift`)
está pronta e integrada na tela de debug já existente. A CAPTURA da baseline
em si — rodar os 18 prompts de verdade contra o `Qwen2.5-Coder-7B-Instruct-4bit`
— exige o modelo MLX carregado e inferência real via Metal, o que só roda em
hardware Apple Silicon dentro do Xcode/simulador/device. Esta sessão não tem
acesso a esse hardware, então a baseline em si (o JSON exportado com outputs
reais) precisa ser gerada por você, uma única vez, seguindo os passos abaixo.

## Passo a passo

1. Abra o projeto no Xcode e rode o app num Mac Apple Silicon (o MLX não
   roda em simulador nem em Mac Intel).
2. Navegue até a tela "Teste — Fluxo completo" (`TopicRepositoryTestView`,
   já linkada em `RootTabView`).
3. Aguarde a seção "Setup" mostrar "✅ Pronto".
4. Role até a seção **"6) Model Benchmark Suite (PLAN_05)"**.
5. Toque em **"Rodar suíte de benchmark"**. Isso vai:
   - Carregar o modelo MLX (`MLXService.modelID`, hoje
     `Qwen2.5-Coder-7B-Instruct-4bit`) se ainda não estiver carregado.
   - Rodar os 18 prompts em sequência, um a um (log de progresso visível
     na seção "Log de execução").
   - Capturar métricas mecânicas reais por prompt (tokens, TTFT,
     tokens/s, tempo total) via `GenerationMetrics`/PLAN_00 — automático,
     sem intervenção manual.
6. Depois que a suíte terminar, abra cada `DisclosureGroup` de prompt (1 a
   18), leia o `rawOutput` gerado, e preencha a rubrica manualmente:
   - **API real (0-30)**: a resposta usa só APIs reais? Para os prompts
     4-7 especificamente, marque o toggle "API inventada" se encontrar
     qualquer hallucination — isso alimenta o veto duro de §9.4.
   - **Instruction following (0-25)**: seguiu o formato pedido
     (`CODIGO:`/`PASSO A PASSO:`, separador `=====` nos lotes, etc.)?
   - **Grounding (0-20)**: ficou fiel ao contexto RAG fornecido, sem
     inventar além dele (prompt 16 é o teste mais direto disso)?
   - **Correção Swift (0-15)**: o código compilaria?
   - **Latência (0-7)** e **Memória (0-3)**: use as métricas mecânicas
     já capturadas (tokens/s, TTFT) como referência objetiva.
   - Toque em "Salvar pontuação" após preencher cada prompt.
7. Quando os 18 prompts estiverem pontuados ("Pontue todos os 18
   prompts..." some), toque em **"Exportar relatório JSON (Documents/)"**.
   O arquivo fica em `Documents/benchmark-report-qwen2.5-coder-7b-instruct-4bit-<timestamp>.json`
   no container do app — essa é a baseline do 7B citada no Success
   Criteria do PLAN_05.
8. Guarde esse JSON (ex.: copie para o repositório, fora do container do
   simulador/device) — é o dado de comparação que `PLAN_14` vai usar
   contra o candidato rodado sob a topologia TARGET.

## Verificação do veto duro sem rodar o modelo

`SwiftStudyCoachTests/ModelBenchmarkSuiteTests.swift` cobre a regra de
§9.4 sem depender de geração real (dados sintéticos): confirma que um
modelo com score MAIOR mas com `hasInventedAPI == true` em qualquer
prompt 4-7 fica ranqueado ABAIXO de um modelo com score menor mas sem
nenhuma ocorrência — rode `Cmd+U` no Xcode ou `xcodebuild test` pra
confirmar antes de investir tempo rodando a suíte completa contra o
modelo de verdade.
