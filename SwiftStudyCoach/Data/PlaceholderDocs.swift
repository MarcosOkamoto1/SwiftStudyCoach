//
//  PlaceholderDocs.swift
//  SwiftStudyCoach
//
//  Dataset de documentação parafraseada, baseado nos conceitos reais da
//  documentação oficial da Apple.
//
//  Plano V5: reduzido de 21 pra 3 tópicos (NavigationStack, Property
//  Wrappers, async/await) — foco em ter poucas coisas funcionando bem e
//  fáceis de testar de ponta a ponta, em vez de 21 tópicos com qualidade
//  incerta. Os outros 18 tópicos (Guard, Optionals, Closures, Structs vs
//  Classes, Enums e Pattern Matching, Protocolos, Tratamento de Erros,
//  Coleções, Property Observers e Computed Properties, Generics,
//  Extensions, ARC, Actors, Ciclo de vida e identidade de Views, Listas e
//  ForEach, Modificadores e Layout, Sheets e Navegação Modal, Animações)
//  saíram do dataset por ora — o texto deles (já auditado na Fase 3 do
//  Plano V4) segue disponível no histórico do git se for reaproveitado.
//
//  Plano V4 Fase 3: cada tópico tem comentários `// Fonte:` apontando pra
//  página oficial usada na auditoria (docs.swift.org / developer.apple.com).
//  Os comentários não entram no RAG (só topic/text viram DocChunk).
//
//  Chunks de ~200-250 palavras, seguindo a recomendação do pacote de
//  embeddings para melhor qualidade de busca semântica. Cada tópico tem
//  2-3 chunks com ângulos distintos: (a) conceito, (b) API/uso, (c) erros
//  comuns/pegadinhas.
//
//  IMPORTANTE: ao trocar este dataset, incrementar DatasetVersion.current
//  (ver Persistence.swift) para invalidar o cache de tópicos já gerados.
//

import Foundation

/// Bloco da trilha de estudo — usado só pra agrupar a home (Plano V3 2.2);
/// não entra no RAG (DocChunk não guarda isso, só topic/text/embedding).
enum TrackBlock: Int, CaseIterable, Hashable {
    case fundamentals = 1
    case intermediate = 2
    case swiftUI = 3

    var title: String {
        switch self {
        case .fundamentals: return "Fundamentos"
        case .intermediate: return "Intermediário"
        case .swiftUI: return "SwiftUI"
        }
    }
}

enum PlaceholderDocs {

    // `nonisolated` (Plano V5, hotfix de build Swift 6): sem isso, o
    // isolamento padrão do projeto (MainActor) torna essa constante
    // inacessível como valor-padrão de parâmetro em
    // DocumentIndex.buildIndex, que roda fora do MainActor — erro real do
    // Swift 6 strict concurrency ("Main actor-isolated static property
    // 'rawChunks' can not be referenced from a nonisolated context"). É só
    // dado estático puro, sem estado de UI, então não precisa de
    // isolamento nenhum.
    nonisolated static let rawChunks: [(topic: String, block: TrackBlock, text: String)] = [

        // MARK: - NavigationStack (Bloco 3 — SwiftUI)
        // Fonte: https://developer.apple.com/documentation/swiftui/navigationstack
        // Fonte: https://developer.apple.com/documentation/swiftui/navigationpath
        (
            topic: "NavigationStack",
            block: .swiftUI,
            text: """
            NavigationStack é o mecanismo moderno de navegação do SwiftUI, \
            introduzido para substituir o antigo NavigationView. Ele gerencia \
            uma pilha de telas: cada nova view é empilhada (push) sobre a \
            anterior, e o usuário volta (pop) removendo o topo da pilha, seja \
            pelo botão de voltar, seja programaticamente. A grande mudança em \
            relação ao modelo antigo é que o NavigationStack separa claramente \
            "o que navegar" de "como exibir" — em vez de amarrar cada link a \
            uma view de destino fixa, você associa tipos de dados a destinos \
            usando o modificador navigationDestination(for:destination:). Isso \
            significa que múltiplos pontos da interface podem empurrar o mesmo \
            tipo de dado para a pilha, e todos vão parar na mesma tela de \
            destino, definida uma única vez. Um NavigationLink, ao ser \
            configurado com um valor (não mais uma view fixa como destino), \
            dispara essa navegação automaticamente quando o tipo do valor \
            corresponde a um navigationDestination declarado em algum ponto \
            da hierarquia acima dele. Esse desacoplamento facilita muito \
            cenários como deep linking e restauração de estado, já que a \
            navegação passa a ser dirigida por dados (data-driven), não por \
            uma sequência fixa de telas amarradas no código.
            """
        ),
        (
            topic: "NavigationStack",
            block: .swiftUI,
            text: """
            NavigationPath é uma coleção que representa o estado de navegação \
            de forma type-erased — ou seja, ela pode guardar valores de \
            tipos diferentes na mesma pilha, sem que você precise declarar \
            um enum ou union manualmente para cada combinação possível de \
            telas. Isso é útil quando a navegação de um app não segue uma \
            sequência única e previsível de tipos, mas pode alternar entre \
            vários tipos de dado dependendo do fluxo do usuário. Para ter \
            controle programático total sobre a pilha — como navegar \
            diretamente para uma tela específica, pular várias telas de uma \
            vez, ou voltar até a raiz —, o NavigationStack aceita um \
            parâmetro de inicialização que recebe uma Binding a uma \
            NavigationPath (ou a um array tipado, quando todos os destinos \
            são do mesmo tipo). Nesse modelo, basta manipular o array/path \
            diretamente no seu código — adicionando ou removendo elementos — \
            que a pilha de navegação reflete essa mudança automaticamente, \
            sem precisar dar tap em nenhum NavigationLink. Popular a pilha \
            de volta à raiz, por exemplo, é tão simples quanto limpar o \
            path (remover todos os elementos), já que o NavigationStack \
            observa esse estado e atualiza a interface de acordo.
            """
        ),
        (
            topic: "NavigationStack",
            block: .swiftUI,
            text: """
            A navegação por valor (value-based navigation) é o padrão \
            recomendado desde a introdução do NavigationStack: em vez de um \
            NavigationLink apontar diretamente para uma View concreta, ele \
            carrega um valor (de qualquer tipo que se conforme a Hashable), \
            e é o navigationDestination(for:) — declarado uma única vez, \
            geralmente próximo à raiz do NavigationStack — quem decide qual \
            tela mostrar para aquele tipo de valor. Isso resolve um problema \
            comum do modelo antigo, onde a lógica de qual tela mostrar ficava \
            espalhada e duplicada por vários pontos da interface. Também \
            facilita testes e permite reorganizar a estrutura do código sem \
            afetar o comportamento de navegação. Um mesmo NavigationStack \
            pode ter vários navigationDestination(for:) declarados, cada um \
            associado a um tipo de dado diferente — por exemplo, um para \
            exibir detalhes de um Produto e outro para exibir detalhes de um \
            Usuário —, e o framework escolhe automaticamente o destino \
            correto de acordo com o tipo do valor empurrado para a pilha. \
            Um cuidado importante: o modificador precisa estar posicionado \
            em algum ponto da hierarquia de views que seja visível e \
            acessível a partir de onde os NavigationLinks daquele tipo são \
            disparados, ou a navegação simplesmente não vai funcionar.
            """
        ),

        // MARK: - Property Wrappers (Bloco 3 — SwiftUI)
        // Fonte: https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro
        // Fonte: https://developer.apple.com/documentation/swiftui/state
        // Fonte: https://developer.apple.com/documentation/swiftui/binding
        (
            topic: "Property Wrappers",
            block: .swiftUI,
            text: """
            Property wrappers em Swift são um mecanismo que permite anexar \
            comportamento extra a uma propriedade, sem repetir esse código \
            toda vez que a propriedade é declarada — o SwiftUI usa isso \
            intensamente para conectar o estado dos seus dados ao ciclo de \
            atualização da interface. @State é o mais básico: marca uma \
            propriedade como pertencente e gerenciada por uma View \
            específica, permitindo que o SwiftUI observe mudanças nesse \
            valor e refaça o corpo da view automaticamente quando ele muda. \
            Como as views em SwiftUI são structs (tipos de valor), @State \
            existe justamente para guardar um estado que sobrevive a \
            recriações da struct da view. @Binding, por sua vez, não é dono \
            do dado — ele cria uma referência de leitura e escrita para um \
            valor que pertence a outra view (geralmente a view pai, marcado \
            lá com @State). Isso permite que uma view filha modifique um \
            dado que não é dela, mantendo uma única fonte de verdade: \
            quando a view filha altera o valor através do binding, é a \
            propriedade original (na view pai) que muda, e o SwiftUI propaga \
            essa atualização para todas as views que dependem dela.
            """
        ),
        (
            topic: "Property Wrappers",
            block: .swiftUI,
            text: """
            Antes do framework Observation, o SwiftUI dependia do protocolo \
            ObservableObject, vindo do Combine. Uma classe conforme a esse \
            protocolo e marca suas propriedades observáveis com @Published; \
            toda vez que uma dessas propriedades muda, o objeto inteiro \
            emite uma notificação, e qualquer view que dependa dele é \
            atualizada — mesmo que a view só leia uma propriedade específica \
            que não mudou. Para consumir um ObservableObject, a view usa \
            @StateObject (quando é ela quem cria e é dona do objeto) ou \
            @ObservedObject (quando o objeto vem de fora, injetado por \
            outra view). A diferença entre os dois é sobre ciclo de vida: \
            @StateObject garante que o objeto seja criado uma única vez e \
            sobreviva a recriações da view, enquanto @ObservedObject não \
            tem essa garantia — se usado para criar o objeto (em vez de só \
            recebê-lo), o objeto pode ser recriado indevidamente toda vez \
            que a view for reconstruída. Esse modelo funciona bem, mas tem \
            um custo de performance: como a notificação de mudança é por \
            objeto inteiro, e não por propriedade individual, views que só \
            se importam com uma parte do objeto acabam sendo atualizadas \
            com mais frequência do que precisariam.
            """
        ),
        (
            topic: "Property Wrappers",
            block: .swiftUI,
            text: """
            O macro @Observable, parte do framework Observation, resolve \
            essa limitação de granularidade: em vez de notificar mudanças \
            por objeto inteiro, ele rastreia exatamente quais propriedades \
            cada view específica lê durante a renderização do seu corpo, e \
            só atualiza aquela view quando uma dessas propriedades \
            especificamente lidas muda — não quando qualquer propriedade do \
            objeto muda. Isso reduz recomputações desnecessárias de forma \
            considerável em objetos com muitas propriedades. Na prática, \
            uma classe marcada com @Observable não precisa mais conformar a \
            ObservableObject nem marcar campos com @Published — o macro \
            trata todas as propriedades armazenadas como observáveis \
            automaticamente (com @ObservationIgnored disponível para excluir \
            alguma explicitamente). O padrão de consumo na view também muda: \
            em vez de @StateObject, usa-se @State normal; em vez de \
            @ObservedObject, a propriedade é apenas declarada sem wrapper \
            algum. Para criar um binding a uma propriedade de um objeto \
            @Observable a partir de uma view filha, existe o wrapper \
            @Bindable, que permite escrever algo como $meuObjeto.propriedade \
            mesmo sem o objeto ser um @State local daquela view. Vale notar \
            que @Observable também passou a suportar rastrear mudanças \
            dentro de coleções e optionals, algo que ObservableObject não \
            fazia de forma nativa.
            """
        ),

        // MARK: - async/await (Bloco 2 — Intermediário)
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/
        (
            topic: "async/await",
            block: .intermediate,
            text: """
            async/await é o modelo de concorrência estruturada do Swift moderno \
            pra escrever código assíncrono com a mesma clareza sequencial de \
            código síncrono, sem a pirâmide de callbacks aninhados do modelo \
            antigo baseado em completion handlers. Uma função marcada async pode \
            conter pontos de suspensão marcados com await — nesses pontos, a \
            execução da função é pausada (sem bloquear a thread) até que a \
            operação assíncrona esperada termine, e então retoma exatamente de \
            onde parou, com o valor de retorno já disponível. Chamar uma função \
            async exige a palavra await no ponto da chamada, de forma parecida \
            com try em funções throws — torna visível, olhando só pro código, \
            exatamente onde uma pausa pode acontecer. O 'contexto' de execução \
            de código async é gerenciado pelo sistema de concorrência \
            estruturada: toda Task (a unidade básica de trabalho assíncrono) tem \
            um ciclo de vida bem definido, e tarefas filhas criadas dentro de \
            uma Task pai (por exemplo, com async let ou um TaskGroup) são \
            automaticamente aguardadas e, se a tarefa pai for cancelada, o \
            cancelamento se propaga pra baixo — diferente de disparar closures \
            assíncronas soltas, sem relação hierárquica nenhuma entre elas.
            """
        ),
        (
            topic: "async/await",
            block: .intermediate,
            text: """
            Um erro comum é tentar chamar uma função async de dentro de um \
            contexto síncrono comum — o compilador não permite isso diretamente, \
            porque não existe ponto de suspensão possível ali; a saída é criar \
            uma nova Task { await minhaFuncaoAsync() }, que inicia um novo \
            contexto assíncrono a partir daquele ponto síncrono. async let \
            permite iniciar múltiplas operações assíncronas em paralelo dentro \
            da mesma função, sem esperar uma terminar pra começar a próxima — o \
            await só é necessário no ponto em que o resultado de cada uma é \
            realmente usado, e o sistema aguarda as que ainda não terminaram \
            naquele ponto. Task.detached cria uma tarefa desligada do contexto \
            de concorrência estruturada ao redor (sem herdar prioridade, sem \
            herdar isolamento de actor, sem relação de cancelamento com a Task \
            que a criou) — é uma ferramenta poderosa, mas deveria ser exceção, \
            não regra: na maioria dos casos, uma Task comum (não detached) \
            dentro do escopo certo já basta, e usar detached sem necessidade \
            real joga fora justamente as garantias estruturais que async/await \
            foi desenhado pra oferecer.
            """
        ),
    ]

    // MARK: - Derivação da trilha (Plano V3 2.1)

    /// Tópicos únicos, agrupados por bloco e na ordem em que aparecem no
    /// dataset — é daqui que a StudyHomeView deriva os cards/chips da home.
    /// Nada hardcoded na view: adicionar chunk novo aqui é o suficiente pro
    /// tópico aparecer sozinho, no bloco certo.
    static func topicsByBlock() -> [TrackSection] {
        var topicsPerBlock: [TrackBlock: [String]] = [:]
        var seen = Set<String>()

        for chunk in rawChunks {
            guard !seen.contains(chunk.topic) else { continue }
            seen.insert(chunk.topic)
            topicsPerBlock[chunk.block, default: []].append(chunk.topic)
        }

        return TrackBlock.allCases.compactMap { block in
            guard let topics = topicsPerBlock[block], !topics.isEmpty else { return nil }
            return TrackSection(block: block, topics: topics)
        }
    }

    /// Todos os tópicos únicos do dataset, na ordem dos blocos — usado pra
    /// restringir `recommendedNextTopic` (Plano V3 2.5) e como fallback de
    /// verificação de existência.
    static func allTopics() -> [String] {
        topicsByBlock().flatMap { $0.topics }
    }
}

/// Uma seção da trilha (bloco + tópicos únicos dentro dele) — struct
/// própria em vez de tupla pra poder usar `Identifiable` direto em
/// `ForEach` na StudyHomeView, sem depender de key paths pra membros de
/// tupla (que o Swift não permite formar como `\.campo`).
struct TrackSection: Identifiable {
    let block: TrackBlock
    let topics: [String]
    var id: Int { block.rawValue }
}
