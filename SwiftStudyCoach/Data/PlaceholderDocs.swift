//
//  PlaceholderDocs.swift
//  SwiftStudyCoach
//
//  Dataset de documentação parafraseada, baseado nos conceitos reais da
//  documentação oficial da Apple — Plano V3 2.2/2.3: trilha de 21 tópicos
//  em 3 blocos (Fundamentos, Intermediário, SwiftUI).
//
//  Plano V4 Fase 3: cada tópico tem comentários `// Fonte:` apontando pra
//  página oficial usada na auditoria (docs.swift.org / developer.apple.com).
//  Afirmações checadas contra a fonte foram corrigidas quando divergiam
//  (ex.: cláusula where em guard — removida do Swift 3+; mutação durante
//  iteração de coleções; recursão em didSet; any + associated types).
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

    static let rawChunks: [(topic: String, block: TrackBlock, text: String)] = [

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

        // MARK: - Guard (Bloco 1 — Fundamentos)
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/controlflow/#Early-Exit
        (
            topic: "Guard",
            block: .fundamentals,
            text: """
            A instrução guard existe para expressar pré-condições: "isso \
            precisa ser verdade para o código continuar daqui pra frente, \
            senão saia agora". Sintaticamente, ela é o inverso de um if let \
            — em vez de executar um bloco quando a condição é satisfeita, o \
            guard executa o bloco else quando a condição NÃO é satisfeita, e \
            esse bloco else é obrigado a sair do escopo atual (com return, \
            throw, break, continue, ou chamando uma função que nunca \
            retorna, como fatalError). O compilador garante essa saída \
            obrigatória — não é permitido escrever um guard cujo else \
            simplesmente continue a execução normalmente. Essa obrigação é \
            o que torna o guard especialmente útil para desembrulhar \
            optionals no início de uma função: guard let valor = \
            optional else { return } garante que, a partir daquele ponto, \
            valor está disponível e desembrulhado para todo o restante do \
            escopo da função — diferente de um if let, cujo valor \
            desembrulhado só existe dentro do bloco do if. Isso reduz \
            aninhamento de código: em vez de várias verificações \
            aninhadas em cascata de ifs, um guard após o outro mantém o \
            corpo da função no mesmo nível de indentação, tratando os casos \
            de erro/ausência logo no início e deixando o "caminho feliz" \
            limpo e linear depois.
            """
        ),
        (
            topic: "Guard",
            block: .fundamentals,
            text: """
            Um guard pode combinar múltiplas condições separadas por \
            vírgula, incluindo mais de um guard let na mesma instrução e \
            condições booleanas adicionais sobre um valor já desembrulhado \
            (desde o Swift 3, a vírgula substituiu a antiga cláusula where \
            nas listas de condição — where sobrevive só no pattern matching \
            de case). Por exemplo: guard let usuario = usuarioAtual, \
            let idade = usuario.idade, idade >= 18 else { return } \
            desembrulha dois optionals em sequência e ainda valida uma \
            condição booleana sobre o segundo valor, tudo em uma única \
            instrução. Se qualquer uma das condições falhar — o primeiro \
            optional ser nil, o segundo ser nil, ou a idade ser menor que \
            18 — o else inteiro é executado. Isso é diferente de escrever \
            vários guards separados, que também funcionaria, mas tornaria \
            o código mais longo sem necessariamente adicionar clareza \
            quando as condições estão logicamente relacionadas. Um detalhe \
            que costuma gerar dúvida: dentro da mesma instrução guard, cada \
            condição pode referenciar os valores desembrulhados pelas \
            condições anteriores na mesma linha, já que elas são avaliadas \
            em ordem, da esquerda para a direita — por isso "idade" já \
            está disponível na condição booleana seguinte daquele mesmo \
            guard, mesmo tendo sido desembrulhada poucos caracteres antes \
            na mesma instrução.
            """
        ),
        (
            topic: "Guard",
            block: .fundamentals,
            text: """
            Uma complexidade real do guard aparece em escopos aninhados: o \
            valor desembrulhado por um guard let pertence ao escopo em que \
            o guard foi escrito, então guards dentro de closures, loops ou \
            blocos condicionais só disponibilizam a variável dentro daquele \
            bloco específico, não na função inteira. Outro ponto sutil é a \
            ordem de avaliação em guards com múltiplas condições: como Swift \
            avalia da esquerda para a direita e para no primeiro item que \
            falhar (short-circuit), é possível — e às vezes necessário — \
            depender dessa ordem para evitar checar algo que só faz sentido \
            depois de outra condição já ter sido validada, como desembrulhar \
            um optional antes de acessar uma propriedade dele em uma \
            condição booleana subsequente. Guards também interagem de forma \
            específica com funções que retornam Never (como fatalError ou \
            preconditionFailure): o compilador aceita esses casos como saída \
            válida do bloco else porque sabe, em tempo de compilação, que a \
            execução não vai continuar depois deles. Por fim, vale lembrar \
            que abusar de guard no meio de uma função (não só no início) \
            para tratar casos de erro no meio da lógica é uma prática \
            válida, mas pode indicar que a função está fazendo coisa \
            demais e seria mais clara dividida em funções menores.
            """
        ),

        // MARK: - Optionals
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/thebasics/#Optionals
        (
            topic: "Optionals",
            block: .fundamentals,
            text: """
            Um Optional em Swift representa um valor que pode estar ausente: por \
            baixo dos panos, é um enum genérico com dois casos, .some(Wrapped) \
            quando há um valor, e .none quando não há. A sintaxe familiar com \
            interrogação — Int?, String? — é só açúcar sintático pra \
            Optional<Int>, Optional<String>. Essa modelagem explícita de \
            ausência é uma das decisões centrais do design de Swift: em vez de \
            qualquer tipo poder secretamente ser nil (como em Objective-C), só \
            um Optional pode. Isso empurra o tratamento de ausência pra dentro \
            do sistema de tipos, e o compilador obriga o desenvolvedor a lidar \
            com o caso .none antes de acessar o valor — não existe acesso direto \
            ao Wrapped sem antes desembrulhar. Existem várias formas de \
            desembrulhar: if let e guard let (a forma segura, condicional), o \
            operador de coalescência nula ?? (fornece um valor padrão quando é \
            nil), e o desembrulhamento forçado com ! (assume que o valor existe \
            e crasha com fatal error se estiver errado). Encadeamento opcional \
            (?.) permite acessar propriedades ou chamar métodos em uma cadeia de \
            optionals, propagando nil automaticamente se qualquer elo da cadeia \
            for nil, sem precisar de vários ifs aninhados. Essa combinação de \
            ferramentas é o que torna o tratamento de ausência em Swift \
            explícito, mas ainda assim ergonômico no dia a dia.
            """
        ),
        (
            topic: "Optionals",
            block: .fundamentals,
            text: """
            Desde o Swift 5.7, if let e guard let ganharam uma forma abreviada: \
            if let valor (sem = valor) desembrulha uma variável do mesmo nome em \
            um novo valor com escopo local, eliminando a repetição de if let \
            valor = valor que era comum antes. Optionals também participam do \
            pipeline funcional da linguagem: map transforma o valor \
            desembrulhado sem sair do Optional (retorna nil se a entrada for \
            nil), e flatMap faz o mesmo mas evita Optionals aninhados \
            (Optional<Optional<T>>) quando a transformação em si já retorna um \
            Optional. Um caso especial e mais arriscado é o Implicitly Unwrapped \
            Optional (declarado com !, como String!), que se comporta como um \
            Optional normal mas é desembrulhado automaticamente sempre que usado \
            como se não fosse opcional — útil em cenários bem específicos (como \
            @IBOutlet, ou uma propriedade que é nil só durante uma janela curta \
            de inicialização), mas arriscado porque um acesso a um valor nil \
            nesse caso crasha exatamente como um desembrulhamento forçado comum. \
            Erros comuns incluem: encadear vários ! sem necessidade, tornando o \
            crash uma questão de tempo; comparar um Optional diretamente com nil \
            em vez de desembrulhar quando o valor realmente é necessário \
            adiante; e esquecer que um Bool? não é a mesma coisa que um Bool — \
            usá-lo diretamente numa condição if é um erro de compilação, não um \
            valor 'falso' implícito.
            """
        ),

        // MARK: - Closures
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/closures/
        (
            topic: "Closures",
            block: .fundamentals,
            text: """
            Closures em Swift são blocos de código auto-contidos que podem ser \
            passados e usados como valores — como uma função anônima que também \
            consegue capturar e reter variáveis e constantes do escopo onde foi \
            criada, mesmo depois que esse escopo já terminou de executar. A \
            sintaxe completa é { (parâmetros) -> TipoDeRetorno in corpo }, mas o \
            compilador consegue inferir tipos de parâmetro e retorno na maioria \
            dos casos, permitindo formas bem mais enxutas: nomes abreviados de \
            argumento ($0, $1), inferência de tipo, e omissão da palavra in \
            quando não sobra ambiguidade. Quando uma closure é o último \
            argumento de uma função, o Swift permite a trailing closure syntax, \
            movendo-a pra fora dos parênteses — é esse padrão que faz chamadas \
            como array.sorted { $0 < $1 } parecerem quase uma extensão da \
            própria linguagem, em vez de uma chamada de função comum. \
            Funcionalmente, closures em Swift são tipos de referência por trás \
            de um valor: podem capturar variáveis por referência (o valor mais \
            atual é sempre visto, mesmo que mude depois da closure ser criada), \
            o que é diferente de simplesmente copiar o valor no momento da \
            criação. Funções nomeadas, aliás, são um caso especial de closure — \
            toda função em Swift é, tecnicamente, uma closure com nome.
            """
        ),
        (
            topic: "Closures",
            block: .fundamentals,
            text: """
            Por padrão, uma closure passada como parâmetro é non-escaping — o \
            compilador garante que ela só é usada durante a execução da própria \
            função, e pode até otimizar sua alocação de memória sabendo disso. \
            Quando a closure precisa sobreviver além do retorno da função (por \
            exemplo, guardada pra rodar depois, como um completion handler de \
            uma chamada assíncrona ou um callback salvo em uma propriedade), ela \
            precisa ser marcada explicitamente com @escaping. Essa marcação \
            importa porque muda como o Swift trata capturas: dentro de uma \
            closure @escaping que referencia self implicitamente, o compilador \
            te obriga a ser explícito (self.propriedade ou capturando self na \
            lista de captura), justamente pra deixar visível o risco de uma \
            referência retida por mais tempo do que se imagina. O erro mais \
            comum aqui é o retain cycle: uma classe guarda uma closure @escaping \
            numa propriedade, e essa closure captura self fortemente — self \
            mantém a closure viva, a closure mantém self vivo, e nenhum dos dois \
            é liberado. A correção padrão é uma lista de captura com [weak self] \
            ou [unowned self] no início da closure, e então desembrulhar self \
            como Optional dentro do corpo antes de usá-lo. Outro recurso \
            relacionado é o @autoclosure, que envolve automaticamente uma \
            expressão comum numa closure, atrasando sua avaliação até o ponto de \
            uso — é assim que operadores como ?? conseguem evitar avaliar o lado \
            direito quando não é necessário.
            """
        ),

        // MARK: - Structs vs Classes
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/
        (
            topic: "Structs vs Classes",
            block: .fundamentals,
            text: """
            Structs e classes são as duas formas principais de definir tipos \
            compostos em Swift, e a diferença mais fundamental entre elas é \
            semântica de valor versus semântica de referência. Uma struct é um \
            tipo de valor: toda vez que ela é atribuída a uma nova variável, \
            passada como argumento pra uma função, ou guardada numa coleção, uma \
            cópia independente é feita — mudar a cópia não afeta o original. Uma \
            classe é um tipo de referência: atribuir uma instância a uma nova \
            variável não copia nada, só cria uma segunda referência apontando \
            pro mesmo objeto na memória; mudar através de qualquer uma das \
            referências afeta o mesmo objeto que todas enxergam. Isso tem \
            consequências diretas em mutabilidade: métodos de uma struct que \
            alteram suas próprias propriedades precisam ser marcados como \
            mutating, porque tecnicamente estão substituindo o valor inteiro por \
            uma nova versão modificada — e uma struct guardada numa constante \
            (let) não pode ter esse método chamado, mesmo que o método só mude \
            uma propriedade interna. Classes não têm essa exigência: um método \
            normal já pode alterar propriedades da instância, mesmo que a \
            variável que a referencia seja let (a referência em si é constante, \
            não o objeto apontado). Outra diferença é herança: só classes \
            suportam herança de implementação; structs só podem adotar \
            protocolos, nunca herdar de outra struct.
            """
        ),
        (
            topic: "Structs vs Classes",
            block: .fundamentals,
            text: """
            Na prática, a recomendação geral em Swift — reforçada pelo próprio \
            SwiftUI, onde views são structs — é preferir structs por padrão, e \
            só usar classes quando identidade de referência é realmente \
            necessária: quando duas partes do código precisam compartilhar e \
            observar o mesmo objeto mutável, ou quando é preciso de herança de \
            implementação, ou pra interoperar com frameworks baseados em \
            Objective-C/Cocoa que esperam referências. Comparar instâncias \
            também muda de sentido entre os dois: para structs, == (quando o \
            tipo conforma a Equatable) compara valores — dois structs 'iguais' \
            têm os mesmos dados, mesmo sendo instâncias diferentes na memória. \
            Para classes, === compara identidade — se as duas variáveis apontam \
            exatamente pro mesmo objeto — enquanto == (se implementado) ainda \
            pode comparar valor, e confundir os dois operadores é um erro comum. \
            Outro detalhe sutil é performance: para arrays e outras coleções de \
            structs, o Swift usa copy-on-write (COW) — a cópia real de memória \
            só acontece no primeiro ponto em que uma das referências tenta \
            modificar os dados, não na atribuição em si. Isso significa que \
            passar structs grandes por aí é mais barato do que parece à primeira \
            vista, mas também que um comportamento de 'mutação compartilhada por \
            acidente' não existe pra structs — cada mutação sempre dispara a \
            cópia antes de alterar.
            """
        ),

        // MARK: - Enums e Pattern Matching
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/enumerations/
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/controlflow/#Switch
        (
            topic: "Enums e Pattern Matching",
            block: .fundamentals,
            text: """
            Um enum em Swift define um tipo com um conjunto fechado e finito de \
            valores possíveis, chamados casos. Diferente de enums em muitas \
            outras linguagens, os casos podem carregar dados associados próprios \
            — por exemplo, enum Resultado { case sucesso(Dado); case \
            falha(Error) } guarda um valor diferente (e de tipo diferente) \
            dependendo de qual caso está ativo, funcionando como uma união com \
            tag, garantida pelo compilador. Um enum também pode ter valores \
            brutos (raw values) — um tipo simples como String ou Int associado a \
            CADA caso de forma fixa e igual pra todas as instâncias daquele caso \
            (diferente de dados associados, que variam por instância). Enums com \
            raw values ganham automaticamente uma inicialização opcional a \
            partir do raw value (Enum(rawValue:)), útil pra desserializar \
            valores externos, tipo um código HTTP ou uma string de configuração. \
            Um dos maiores benefícios de enums em Swift é a checagem de \
            exaustividade: um switch sobre um enum precisa cobrir todos os casos \
            possíveis (ou ter um default), e o compilador emite erro se um caso \
            novo for adicionado ao enum e esquecido em algum switch existente — \
            isso torna enums uma ferramenta poderosa pra modelar estado finito \
            (como o carregamento de uma tela: idle, loading, loaded(Dado), \
            failed(Error)) de um jeito que o compilador ativamente ajuda a \
            manter consistente conforme o código evolui.
            """
        ),
        (
            topic: "Enums e Pattern Matching",
            block: .fundamentals,
            text: """
            Pattern matching é o mecanismo que o Swift usa pra desestruturar e \
            testar valores contra um formato esperado, e vai muito além de um \
            switch simples sobre casos de enum. Dentro de um case, é possível \
            extrair os dados associados diretamente pra constantes locais — case \
            .sucesso(let dado): já disponibiliza dado desembrulhado e tipado \
            dentro daquele bloco. Cláusulas where adicionam uma condição extra \
            sobre o valor já capturado, tipo case .falha(let erro) where erro is \
            TimeoutError:, permitindo diferenciar sub-casos sem precisar de um \
            enum mais granular. O mesmo mecanismo usado em switch também \
            funciona em if case e guard case, úteis quando só um caso específico \
            interessa e o resto do fluxo pode ignorar os demais sem precisar \
            escrever um switch inteiro. Tuplas e ranges também participam do \
            pattern matching: switch sobre uma tupla (x, y) pode casar contra \
            combinações específicas, intervalos (case 0..<10:), ou usar _ pra \
            ignorar uma posição. Um erro comum de quem vem de outras linguagens \
            é tentar usar switch/case em Swift como uma cadeia de if/else \
            disfarçada, sem aproveitar a desestruturação — perdendo a maior \
            vantagem do recurso. Outro cuidado: como não há fallthrough \
            implícito entre cases (diferente de C ou Objective-C), cada case \
            executa isoladamente por padrão, e um fallthrough explícito só é \
            necessário nos raros casos em que o comportamento de queda é \
            realmente desejado.
            """
        ),

        // MARK: - Protocolos
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/protocols/
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/opaquetypes/
        (
            topic: "Protocolos",
            block: .fundamentals,
            text: """
            Um protocolo define um contrato — um conjunto de métodos, \
            propriedades e outros requisitos — que qualquer tipo (struct, classe \
            ou enum) pode se comprometer a cumprir, sem ditar como esse tipo \
            deve ser implementado por dentro. Diferente de uma superclasse, um \
            protocolo não fornece implementação própria por padrão (embora \
            protocol extensions mudem isso parcialmente) e um mesmo tipo pode \
            conformar a vários protocolos ao mesmo tempo — algo que herança \
            simples, restrita a uma única superclasse, não permite. Protocolos \
            também podem ser usados como tipo em si: uma variável ou parâmetro \
            declarado como o tipo de um protocolo aceita qualquer instância \
            concreta que conforme a ele, permitindo escrever código genérico o \
            bastante pra funcionar com implementações futuras ainda \
            desconhecidas no momento em que a função foi escrita. Composição de \
            protocolos com & (tipo Codable & Equatable) exige que um valor \
            conforme a múltiplos protocolos simultaneamente, sem precisar criar \
            um protocolo novo só pra representar essa combinação. Protocolos \
            também podem declarar associated types — um placeholder de tipo que \
            cada tipo conformante preenche à sua maneira (é assim que Collection \
            consegue descrever tanto um Array<Int> quanto um Set<String> com o \
            mesmo protocolo, cada um preenchendo Element de um jeito diferente) \
            — o que torna protocolos com associated type parecidos com generics, \
            mas resolvidos no ponto de conformidade, não no ponto de uso.
            """
        ),
        (
            topic: "Protocolos",
            block: .fundamentals,
            text: """
            Protocol extensions são o que dá à programação orientada a \
            protocolos em Swift seu poder real: é possível fornecer uma \
            implementação padrão de um método ou propriedade computada \
            diretamente numa extension do protocolo, e todo tipo conformante \
            ganha esse comportamento de graça, podendo sobrescrevê-lo se \
            precisar de algo diferente. Isso permite compartilhar comportamento \
            entre tipos completamente não relacionados por herança — uma struct \
            e uma classe podem conformar ao mesmo protocolo e herdar a mesma \
            lógica default, algo que herança de classe simples nunca conseguiria \
            sem um ancestral comum artificial. Um ponto que costuma confundir é \
            a diferença entre existential types (any Protocolo) e generic \
            constraints (some Protocolo ou <T: Protocolo>): any Protocolo — \
            que a documentação chama de boxed protocol type (tipo \
            existencial) — guarda qualquer valor conformante por trás de uma \
            "caixa" (box) que apaga o tipo concreto original, uma indireção \
            com custo de performance em tempo de execução; entre as \
            limitações documentadas, um valor de tipo any Protocolo NÃO \
            conforma ao próprio protocolo (não pode ser passado onde se exige \
            um tipo conformante) e requisitos que envolvem Self, como o \
            operador ==, ficam indisponíveis através da caixa; já some Protocolo \
            (opaque type) ou um parâmetro genérico preservam o tipo concreto \
            internamente, resolvido em tempo de compilação, com despacho \
            estático mais rápido — a troca é entre flexibilidade em runtime \
            (any) e desempenho/garantias em compile-time (some/generics). \
            Confundir os dois, ou usar any por padrão sem necessidade, é um dos \
            erros de design mais comuns em código Swift que tenta ser 'genérico \
            demais' cedo demais.
            """
        ),

        // MARK: - Tratamento de Erros
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/
        (
            topic: "Tratamento de Erros",
            block: .fundamentals,
            text: """
            Swift trata erros recuperáveis através de um modelo baseado em tipos \
            que conformam ao protocolo Error (frequentemente um enum, já que \
            erros costumam ter um conjunto finito e conhecido de causas). Uma \
            função que pode falhar é marcada com throws na assinatura, e só pode \
            lançar um erro usando throw dentro do próprio corpo ou propagando \
            erros de outras chamadas throwing. Chamar uma função throws exige a \
            palavra-chave try antes da chamada — isso é proposital: try torna \
            visível, no ponto de leitura do código, exatamente onde uma falha \
            pode acontecer, sem precisar abrir a implementação da função pra \
            descobrir. Existem três variantes de try: try simples, que precisa \
            estar dentro de um bloco do-catch (ou de outra função throws, \
            propagando o erro pra cima); try?, que converte o resultado numa \
            Optional — nil se um erro foi lançado, o valor normal caso contrário \
            — descartando a informação específica do erro; e try!, que assume \
            que a chamada nunca vai falhar e crasha com fatal error se um erro \
            for lançado, análogo ao desembrulhamento forçado de Optionals. Um \
            bloco do-catch executa o código do do normalmente e só entra em um \
            catch se algum try dentro dele lançar — e, assim como switch sobre \
            enums, pattern matching nos catches permite capturar erros \
            específicos (catch MeuErro.timeout) antes de um catch genérico que \
            pega qualquer coisa.
            """
        ),
        (
            topic: "Tratamento de Erros",
            block: .fundamentals,
            text: """
            Definir um erro customizado normalmente significa criar um enum \
            conformando a Error, com um caso pra cada motivo distinto de falha — \
            dados associados em cada caso podem carregar contexto extra, como \
            qual arquivo faltou ou qual valor era inválido. Conformar também a \
            LocalizedError permite fornecer uma errorDescription legível pra \
            exibir diretamente na interface, em vez de depender da descrição \
            técnica padrão. Ao propagar erros por uma cadeia de chamadas, cada \
            função intermediária que chama uma throws com try (sem try? ou \
            do-catch) também precisa ser declarada throws — o efeito colateral \
            'pode falhar' se propaga pela assinatura de tipos, de forma parecida \
            com como async se propaga em código concorrente. Uma alternativa ao \
            par throws/try, mais explícita ainda, é o tipo Result<Success, \
            Failure>, que representa o resultado de uma operação como um valor \
            comum (enum com casos .success e .failure) em vez de um efeito \
            colateral de controle de fluxo — útil principalmente quando o \
            resultado precisa ser guardado, passado adiante ou combinado antes \
            de ser tratado, coisas que um throw não faz bem sozinho. Um erro \
            comum de iniciantes é usar try! em código de produção 'porque nunca \
            deveria falhar' — isso troca uma falha tratável por um crash \
            garantido caso a suposição esteja errada; outro é capturar um catch \
            genérico cedo demais, escondendo qual erro específico realmente \
            aconteceu.
            """
        ),

        // MARK: - Coleções (Array/Dictionary/Set)
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/collectiontypes/
        (
            topic: "Coleções (Array/Dictionary/Set)",
            block: .fundamentals,
            text: """
            Swift tem três coleções fundamentais na biblioteca padrão, cada uma \
            com uma garantia diferente. Array é uma coleção ordenada que permite \
            elementos duplicados e acesso por índice em tempo constante — é a \
            escolha padrão quando ordem importa ou quando é preciso acessar \
            elementos por posição. Dictionary guarda pares chave-valor, onde \
            cada chave precisa conformar a Hashable e é única dentro daquele \
            dicionário; a ordem de iteração não é garantida (nem estável entre \
            execuções), e a busca por chave é, em média, tempo constante — muito \
            mais rápida que buscar um valor num Array quando o que se tem de \
            partida é uma chave. Set guarda uma coleção de elementos únicos \
            (também exigindo Hashable), sem ordem definida, e é otimizado \
            justamente pra testar pertencimento (contains) e pra operações de \
            conjunto como união, interseção e diferença, todas em tempo próximo \
            de constante — usar um Array pra essas mesmas operações exigiria \
            varreduras lineares repetidas. Escolher a coleção certa pro problema \
            é menos sobre sintaxe e mais sobre qual operação vai ser mais \
            frequente: se é 'existe esse elemento?' ou 'quais elementos os dois \
            grupos têm em comum?', Set tende a vencer; se é 'me dê a chave X', \
            Dictionary; se é 'preciso da ordem e/ou de duplicatas', Array.
            """
        ),
        (
            topic: "Coleções (Array/Dictionary/Set)",
            block: .fundamentals,
            text: """
            As três coleções da biblioteca padrão são tipos de valor com \
            copy-on-write: atribuir um Array, Dictionary ou Set a uma nova \
            variável não copia os dados imediatamente, só cria uma segunda \
            referência interna compartilhada; a cópia de fato só acontece no \
            momento em que uma das duas partes tenta modificar os dados, e só \
            então elas realmente se tornam independentes. Isso é o que permite \
            passar coleções grandes como parâmetro sem pagar o custo de uma \
            cópia completa toda vez, mantendo ainda assim a garantia de \
            semântica de valor. Um erro clássico documentado é acessar ou \
            modificar um Array num índice fora dos limites — isso dispara um \
            erro em tempo de execução, e o maior índice válido é sempre \
            count - 1 (num array vazio não existe índice válido algum). Em \
            Dictionary, o subscript de leitura retorna um Optional por \
            natureza — nil quando a chave não existe —, atribuir nil a uma \
            chave REMOVE aquele par chave-valor do dicionário, e o método \
            updateValue(_:forKey:) faz o mesmo que o subscript de escrita \
            mas devolve o valor antigo (como Optional), útil pra saber se \
            houve substituição de fato. Outro cuidado comum é achar que \
            Dictionary preserva a ordem de inserção — ele não tem ordem \
            definida —; a forma documentada de iterar em ordem estável é \
            usar sorted() sobre keys ou values (o mesmo vale pra Set).
            """
        ),

        // MARK: - Property Observers e Computed Properties
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/properties/
        (
            topic: "Property Observers e Computed Properties",
            block: .fundamentals,
            text: """
            Propriedades em Swift podem ser armazenadas (stored) — ocupam espaço \
            real de memória na instância — ou computadas (computed) — não \
            guardam um valor diretamente, e sim calculam um a cada acesso \
            através de um bloco get, e opcionalmente aceitam escrita através de \
            um bloco set. Uma propriedade computada só de leitura pode omitir a \
            palavra get e o bloco de chaves externo, escrevendo só a lógica de \
            cálculo diretamente; já uma que também aceita escrita precisa dos \
            dois blocos explícitos, e dentro do set um valor implícito chamado \
            newValue (ou um nome customizado entre parênteses depois de set) \
            representa o que está sendo atribuído. Propriedades computadas são \
            úteis pra expor um valor derivado de outras propriedades armazenadas \
            sem duplicar estado — por exemplo, uma propriedade areaTotal \
            calculada a partir de largura e altura, sempre consistente porque \
            nunca é guardada separadamente, só recalculada. Diferente de \
            propriedades armazenadas, computadas não podem ter um valor inicial \
            nem participar de inicialização direta — elas dependem de outras \
            propriedades já estarem disponíveis pra calcular seu próprio valor. \
            Vale notar que propriedades computadas em uma struct que só tem get, \
            sem set, podem ser declaradas mesmo em uma instância let, já que não \
            guardam estado mutável de fato — o cálculo roda de novo a cada \
            leitura, não há nada pra 'travar'.
            """
        ),
        (
            topic: "Property Observers e Computed Properties",
            block: .fundamentals,
            text: """
            Property observers — willSet e didSet — permitem reagir a mudanças \
            no valor de uma propriedade armazenada, sem transformá-la numa \
            propriedade computada. willSet roda antes do novo valor ser \
            efetivamente atribuído (com acesso ao valor novo através de \
            newValue, e ainda ao valor antigo através da própria propriedade); \
            didSet roda depois da atribuição já ter acontecido (com acesso ao \
            valor antigo através de oldValue, e o valor atual já é o novo, \
            acessível pela própria propriedade). Um uso comum é disparar efeitos \
            colaterais quando um valor muda — validar um novo valor, notificar \
            outra parte do sistema, ou (no SwiftUI, através de @Observable) \
            propagar a mudança pra interface. Um detalhe importante e \
            frequentemente esquecido: property observers NÃO disparam durante a \
            inicialização da instância (quando o valor inicial é atribuído \
            dentro de um init, ou via valor padrão na declaração) — eles só \
            disparam em atribuições que acontecem depois que a instância já está \
            totalmente inicializada. Outro detalhe documentado: atribuir à \
            MESMA propriedade dentro do seu próprio didSet (por exemplo, pra \
            'corrigir' o valor recém-atribuído clampando-o num intervalo) \
            simplesmente substitui o valor que acabou de ser definido, SEM \
            disparar os observers de novo — não há recursão. E há uma exceção \
            à regra da inicialização: quando uma subclasse atribui a uma \
            propriedade herdada dentro do próprio init, depois de chamar o \
            inicializador da superclasse, os observers da superclasse são \
            chamados normalmente.
            """
        ),

        // MARK: - Generics
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/generics/
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/opaquetypes/
        (
            topic: "Generics",
            block: .intermediate,
            text: """
            Generics permitem escrever funções e tipos que funcionam com \
            qualquer tipo, respeitando restrições declaradas, sem duplicar \
            código pra cada tipo concreto e sem abrir mão da checagem de tipos \
            em tempo de compilação. Uma função genérica como func primeiro<T>(_ \
            itens: [T]) -> T? usa T como um placeholder de tipo — o compilador \
            substitui T pelo tipo real no momento em que a função é chamada, \
            gerando código especializado e com desempenho equivalente ao de \
            escrever uma versão separada pra cada tipo à mão. Restrições de tipo \
            (type constraints) limitam quais tipos podem preencher esse \
            placeholder: func maior<T: Comparable>(_ a: T, _ b: T) -> T só \
            aceita tipos que conformem a Comparable, porque o corpo da função \
            precisa usar o operador >, que só existe pra tipos que implementam \
            esse protocolo. Tipos genéricos funcionam do mesmo jeito — \
            Array<Element> e Optional<Wrapped> são, eles mesmos, tipos genéricos \
            da biblioteca padrão, com Element e Wrapped sendo os parâmetros de \
            tipo preenchidos no momento do uso. Cláusulas where mais elaboradas \
            permitem restrições adicionais além de conformidade simples a \
            protocolo, como exigir que dois parâmetros genéricos diferentes \
            tenham o mesmo Element, comum em extensions de coleções que combinam \
            duas sequências.
            """
        ),
        (
            topic: "Generics",
            block: .intermediate,
            text: """
            Uma fonte comum de confusão é a diferença entre generics e \
            protocolos com associated type usados como existential (any \
            Protocolo): ambos lidam com 'algum tipo desconhecido', mas generics \
            resolvem qual tipo concreto está em jogo em tempo de compilação (o \
            compilador gera, efetivamente, uma versão especializada da função \
            pra cada tipo usado, com despacho estático), enquanto any Protocolo \
            (boxed protocol type) apaga o tipo concreto e resolve tudo em \
            tempo de execução, com a indireção da "caixa" e sua penalidade de \
            performance — e, como a caixa esconde o tipo, informações que \
            dependem dele (como o associated type inferido a partir do tipo \
            concreto) deixam de estar disponíveis pra quem consome o valor. \
            Opaque types (some Protocolo) tentam um meio-termo: a função \
            devolve 'algum tipo específico que conforma a este protocolo', \
            escondendo o tipo concreto de quem chama, mas preservando-o \
            internamente pra fins de otimização e de conformidade a protocolos \
            com Self ou associated type — é o mecanismo por trás do retorno de \
            some View no SwiftUI. Uma limitação prática de generics que \
            surpreende iniciantes é que não dá pra guardar instâncias de tipos \
            genéricos diferentes na mesma coleção comum (um array de 'qualquer \
            Stack<T>', por exemplo, não compila diretamente) — pra isso, é \
            preciso recorrer a type erasure manual (um wrapper concreto que \
            esconde o T por trás de closures) ou a um protocolo comum sem \
            associated type.
            """
        ),

        // MARK: - Extensions
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/extensions/
        (
            topic: "Extensions",
            block: .intermediate,
            text: """
            Extensions em Swift adicionam funcionalidade nova a um tipo já \
            existente — seja um tipo próprio do projeto, um tipo da biblioteca \
            padrão (como String ou Array), ou um tipo vindo de um framework \
            externo — sem precisar de acesso ao código-fonte original e sem \
            herança. Dentro de uma extension é possível adicionar métodos de \
            instância e de tipo, propriedades computadas (nunca propriedades \
            armazenadas — extensions não podem adicionar estado novo a um tipo \
            já existente, só comportamento), inicializadores convenience (pra \
            classes) ou novos inicializadores (pra structs, desde que não \
            conflitem com os que a struct já sintetiza), e conformidade a \
            protocolos novos. Esse último uso — declarar que um tipo já \
            existente passa a conformar a um protocolo, numa extension separada \
            da declaração original do tipo — é um padrão extremamente comum em \
            Swift, usado tanto pra organizar o código quanto pra realmente \
            estender tipos de fora do projeto. Extensions também são o mecanismo \
            por trás de boa parte da programação orientada a protocolos: uma \
            extension de um PROTOCOLO (não de um tipo concreto) pode fornecer \
            implementação padrão pra métodos declarados nesse protocolo, e todo \
            tipo conformante herda esse comportamento automaticamente.
            """
        ),
        (
            topic: "Extensions",
            block: .intermediate,
            text: """
            Conformidade condicional é um recurso mais avançado de extensions: é \
            possível fazer um tipo genérico conformar a um protocolo só quando \
            seu parâmetro de tipo também conforma a algo — por exemplo, \
            extension Array: Equatable where Element: Equatable diz que um Array \
            só é comparável com == se os elementos dentro dele também forem. \
            Isso evita ter que escolher entre 'todo Array é Equatable' \
            (impossível de garantir em geral) ou 'nenhum Array é Equatable' \
            (perda de funcionalidade útil), condicionando a conformidade \
            exatamente ao caso em que ela faz sentido. Um cuidado importante ao \
            estender tipos que não são seus — bibliotecas de terceiros ou até \
            tipos do sistema — é o risco de 'conformidade retroativa' \
            conflitante: se duas bibliotecas diferentes (ou uma biblioteca e o \
            app) declaram a mesma conformidade de protocolo pro mesmo tipo \
            externo, o linker pode falhar ou o comportamento pode ficar ambíguo, \
            já que Swift não permite duas conformidades diferentes do mesmo tipo \
            ao mesmo protocolo dentro do mesmo processo. Por isso a prática \
            recomendada é evitar declarar conformidade de protocolo a tipos que \
            não são seus a menos que seja realmente o dono canônico dessa \
            conformidade — preferindo, quando possível, um wrapper ou uma função \
            livre em vez de estender o tipo alheio diretamente.
            """
        ),

        // MARK: - ARC e Gerenciamento de Memória
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/automaticreferencecounting/
        (
            topic: "ARC e Gerenciamento de Memória",
            block: .intermediate,
            text: """
            Swift gerencia memória de instâncias de classes através de Automatic \
            Reference Counting (ARC): cada instância mantém um contador de \
            quantas referências fortes (strong) apontam pra ela, esse contador \
            sobe toda vez que uma nova referência forte é criada e desce toda \
            vez que uma referência forte sai de escopo ou é reatribuída, e a \
            instância é desalocada automaticamente assim que o contador chega a \
            zero — sem um garbage collector rodando em background, e com o \
            timing de desalocação previsível. Isso só se aplica a classes: \
            structs e enums são tipos de valor e não participam de contagem de \
            referência. Um deinit opcional pode ser declarado numa classe pra \
            rodar código de limpeza exatamente no momento da desalocação — \
            soltar um recurso externo, cancelar uma observação, etc. — algo que \
            não existe (nem faz sentido da mesma forma) pra structs. Referências \
            fracas (weak) e não possuídas (unowned) existem justamente pra \
            quebrar esse contador quando duas instâncias precisam se referenciar \
            mutuamente sem impedir que uma libere a outra.
            """
        ),
        (
            topic: "ARC e Gerenciamento de Memória",
            block: .intermediate,
            text: """
            O problema clássico que ARC sozinho não resolve é o retain cycle \
            (ciclo de referência forte): duas instâncias se referenciando \
            mutuamente por referência forte fazem com que o contador de nenhuma \
            das duas chegue a zero, mesmo que nada mais no programa as \
            referencie — nem uma nem outra são desalocadas, e o deinit de \
            nenhuma das duas roda, um vazamento de memória silencioso. O caso \
            mais comum na prática envolve closures: uma classe guarda uma \
            closure @escaping que captura self fortemente por padrão, e essa \
            mesma closure é guardada como propriedade daquela instância — self \
            mantém a closure viva, a closure mantém self vivo. A correção é \
            declarar self como weak ou unowned na lista de captura da closure \
            ([weak self] in ou [unowned self] in). weak torna a referência um \
            Optional que vira nil automaticamente se a instância for desalocada \
            por outro caminho — mais seguro, mas exige desembrulhar self dentro \
            do corpo; unowned assume que a instância vai continuar viva enquanto \
            a closure existir, sem o Optional, mas crasha se essa suposição \
            estiver errada. Regra prática: weak quando a instância pode \
            legitimamente deixar de existir antes da closure rodar; unowned só \
            quando há garantia forte do contrário.
            """
        ),

        // MARK: - async/await
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

        // MARK: - Actors
        // Fonte: https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Actors
        // Fonte: https://developer.apple.com/documentation/swift/mainactor
        (
            topic: "Actors",
            block: .intermediate,
            text: """
            Actors são um tipo de referência, parecido com uma classe, mas com \
            uma garantia extra embutida pelo compilador: todo o estado mutável \
            de um actor só pode ser acessado de forma serializada, um acesso de \
            cada vez, mesmo que várias partes do código tentem acessar esse \
            estado 'ao mesmo tempo' vindas de threads diferentes. Isso elimina \
            data races por construção — duas tasks concorrentes nunca conseguem \
            ler e escrever a mesma propriedade de um actor simultaneamente, \
            porque o próprio actor enfileira essas operações internamente. Do \
            ponto de vista de quem usa um actor de fora, esse isolamento aparece \
            na forma de await obrigatório: acessar uma propriedade ou chamar um \
            método de um actor a partir de fora dele exige await, mesmo que o \
            método em si não seja assíncrono — o await ali não está esperando \
            uma operação demorada, está esperando a vez de acessar aquele estado \
            isolado, que pode já estar ocupado processando outra chamada. Dentro \
            do próprio actor, entre seus métodos, o acesso ao próprio estado é \
            direto, sem precisar de await, porque já está executando dentro da \
            região serializada.
            """
        ),
        (
            topic: "Actors",
            block: .intermediate,
            text: """
            Nem todo membro de um actor precisa ficar isolado: uma propriedade \
            ou método marcado nonisolated explicitamente abre mão da proteção do \
            actor pra esse membro específico — só faz sentido pra coisas que não \
            dependem de estado mutável, e permite acessar esse membro específico \
            de fora sem precisar de await. @MainActor é um caso especial e \
            extremamente comum de actor global: qualquer tipo, propriedade ou \
            função marcada @MainActor tem seu acesso automaticamente serializado \
            através da thread principal — é o mecanismo moderno recomendado pra \
            garantir que código relacionado a UI realmente rode lá, com erro de \
            compilação (não só um crash em runtime) se algo tentar acessar um \
            valor @MainActor de um contexto que não é a main thread sem await. \
            Um detalhe sutil que costuma surpreender é a reentrância de actors: \
            como cada await dentro de um método de actor é um ponto de suspensão \
            real, outra chamada pra esse mesmo actor pode 'furar a fila' e rodar \
            entre um await e o próximo dentro do MESMO método — isso significa \
            que o estado do actor pode ter mudado entre dois pontos do mesmo \
            método, algo que não aconteceria num código estritamente sequencial, \
            e que precisa ser levado em conta ao escrever lógica que depende de \
            invariantes se manterem estáveis ao longo de múltiplos awaits.
            """
        ),

        // MARK: - Ciclo de vida e identidade de Views
        // Fonte: https://developer.apple.com/documentation/swiftui/view/id(_:)
        // Fonte: https://developer.apple.com/documentation/swiftui/view/onappear(perform:)
        // Fonte: https://developer.apple.com/documentation/swiftui/view/task(priority:_:)
        (
            topic: "Ciclo de vida e identidade de Views",
            block: .swiftUI,
            text: """
            Views em SwiftUI são structs — valores leves, baratos de criar e \
            destruir — e o corpo (body) de uma view é recalculado com \
            frequência, potencialmente a cada mudança de estado relevante, sem \
            que isso signifique necessariamente 'recriar a UI na tela'. O que de \
            fato existe persistentemente na tela é gerenciado pelo framework por \
            trás dos panos através de identidade: SwiftUI decide se uma view \
            antes e depois de uma atualização é 'a mesma view, só com dados \
            diferentes' (nesse caso, ela é atualizada in-place, preservando \
            @State e completando uma transição suave) ou se é 'uma view \
            completamente nova substituindo a antiga' (nesse caso, o estado \
            antigo é descartado e um novo é criado do zero). Identidade \
            estrutural (implícita) é inferida pela posição de uma view na \
            hierarquia e pelo seu tipo — trocar o tipo de view retornado \
            condicionalmente por um if/else no body, por exemplo, faz SwiftUI \
            tratar os dois ramos como identidades diferentes. Identidade \
            explícita, via o modificador .id(valor), permite forçar esse \
            comportamento manualmente: mudar o valor passado pra .id() entre \
            duas atualizações sinaliza pro SwiftUI que aquela view deve ser \
            tratada como uma instância nova, mesmo que o tipo seja o mesmo — \
            descartando e recriando seu estado interno propositalmente, útil por \
            exemplo pra resetar todo o @State de uma view quando o dado que ela \
            representa muda completamente.
            """
        ),
        (
            topic: "Ciclo de vida e identidade de Views",
            block: .swiftUI,
            text: """
            O ciclo de vida de uma view em SwiftUI é bem diferente do ciclo de \
            vida de uma UIViewController: não existem callbacks parecidos com \
            viewDidLoad ou viewWillAppear como parte do contrato principal da \
            view — em vez disso, o modificador .onAppear roda uma closure quando \
            aquela instância de view (por identidade) entra na hierarquia \
            visível, e .onDisappear quando ela sai; ambos podem disparar mais de \
            uma vez ao longo da vida do app, sempre que a view entra e sai de \
            novo. Pra trabalho assíncrono atrelado à visibilidade da view — \
            carregar dados assim que ela aparece, e cancelar automaticamente se \
            ela desaparecer antes de terminar — o modificador .task é geralmente \
            preferível a disparar uma Task manualmente dentro de .onAppear: \
            .task cria e gerencia sua própria Task vinculada ao ciclo de vida da \
            view, cancelando-a automaticamente quando a view desaparece, sem \
            precisar guardar uma referência à Task manualmente pra cancelar \
            depois. Um erro comum é assumir que .onAppear roda só uma vez 'como \
            viewDidLoad' — planejar lógica de inicialização que só deveria rodar \
            uma única vez dentro de .onAppear sem proteção extra pode acabar \
            rodando repetidamente e de forma inesperada.
            """
        ),

        // MARK: - Listas e ForEach
        // Fonte: https://developer.apple.com/documentation/swiftui/list
        // Fonte: https://developer.apple.com/documentation/swiftui/foreach
        (
            topic: "Listas e ForEach",
            block: .swiftUI,
            text: """
            List é a view do SwiftUI pra exibir coleções de dados em formato de \
            lista rolável, com estilo e comportamento de plataforma \
            (separadores, seleção, swipe actions) prontos por padrão. Dentro de \
            uma List (ou de qualquer container que precise repetir uma view pra \
            cada elemento de uma coleção, como um VStack também), ForEach é o \
            mecanismo que faz esse loop declarativo — diferente de um for comum \
            do Swift, ForEach precisa saber como identificar unicamente cada \
            elemento entre atualizações, e é exatamente essa identidade (não o \
            índice, nem a posição visual) que o SwiftUI usa pra decidir quais \
            linhas animam como inseridas, removidas, ou apenas atualizadas \
            quando os dados mudam. A forma mais robusta é usar dados que \
            conformam a Identifiable (com uma propriedade id estável e única) — \
            ForEach(meusDados) já infere o id automaticamente nesse caso. Quando \
            o tipo do dado não conforma a Identifiable, é possível passar \
            explicitamente qual propriedade usar como id, através do parâmetro \
            id: do inicializador. Combinar List com ForEach dentro de uma \
            Section permite agrupar visualmente subconjuntos da coleção, cada \
            Section com seu próprio cabeçalho e rodapé opcionais, sem precisar \
            reestruturar os dados que alimentam a lista.
            """
        ),
        (
            topic: "Listas e ForEach",
            block: .swiftUI,
            text: """
            Um erro comum e sutil é usar o índice do array como identificador \
            (passando o próprio índice, ou o offset de um enumerated(), como id) \
            quando a coleção pode ser reordenada, ter itens inseridos no meio, \
            ou ter itens removidos: como o índice de um item muda quando a lista \
            muda de tamanho ou ordem, o SwiftUI pode associar erroneamente o \
            estado (e as animações) da linha errada ao índice errado — uma linha \
            que 'deveria' desaparecer, por exemplo, pode acabar mostrando o \
            conteúdo de outra, ou uma animação de remoção acontece na posição \
            errada. A correção quase sempre é usar um identificador estável de \
            verdade — um UUID gerado uma única vez na criação do dado, ou uma \
            chave de negócio única — em vez do índice. List também expõe \
            modificadores prontos pra edição comum: .onDelete(perform:) habilita \
            o gesto de arrastar-pra-excluir (junto de um EditButton ou modo de \
            edição), e .onMove(perform:) habilita reordenação por arrastar — \
            ambos recebem os índices afetados, e é responsabilidade do código \
            que os implementa realmente remover/mover os itens na fonte de dados \
            subjacente, já que a List em si não é dona dos dados, só os exibe.
            """
        ),

        // MARK: - Modificadores e Layout
        // Fonte: https://developer.apple.com/documentation/swiftui/configuring-views
        // Fonte: https://developer.apple.com/documentation/swiftui/layout-fundamentals
        (
            topic: "Modificadores e Layout",
            block: .swiftUI,
            text: """
            Um modificador de view em SwiftUI (.padding(), .background(), \
            .frame(), etc.) não muda a view original — ele envolve a view \
            existente numa nova view que adiciona aquele comportamento, e \
            devolve essa nova view encadeável com o próximo modificador. É por \
            isso que a ORDEM dos modificadores importa e pode mudar \
            completamente o resultado visual: aplicar padding antes de um \
            background desenha o fundo por cima do espaço do padding também, \
            enquanto aplicar o background antes do padding deixa o fundo \
            restrito só ao conteúdo original, com o padding aparecendo por fora, \
            sem cor de fundo nesse espaço extra. Pensar em cada modificador como \
            uma nova camada envolvendo a anterior — uma view dentro de outra \
            view, literalmente — é o modelo mental mais confiável pra prever o \
            resultado. O sistema de layout do SwiftUI, por trás dos \
            modificadores, funciona por negociação de tamanho: o container pai \
            PROPÕE um tamanho disponível pro filho, o filho decide (com base \
            nesse tamanho proposto e no seu próprio conteúdo) qual tamanho \
            realmente quer ocupar, e o pai então posiciona o filho dentro do \
            espaço negociado — diferente de um modelo onde o pai simplesmente \
            força um tamanho fixo no filho.
            """
        ),
        (
            topic: "Modificadores e Layout",
            block: .swiftUI,
            text: """
            HStack, VStack e ZStack são os containers básicos de layout: \
            organizam suas views filhas horizontalmente, verticalmente, ou \
            sobrepostas (nessa ordem), distribuindo o espaço proposto entre as \
            filhas de acordo com o quanto cada uma 'pede' de tamanho intrínseco. \
            Spacer(), usado dentro de um HStack ou VStack, é uma view invisível \
            que tenta ocupar todo o espaço restante disponível, empurrando as \
            views ao redor dela pras extremidades — é o mecanismo mais comum pra \
            criar espaçamento flexível entre elementos, ao contrário de um \
            padding fixo. O modificador .frame(width:height:) tenta forçar a \
            view a ocupar um tamanho específico, mas ele não é uma garantia \
            absoluta em todos os casos — texto que não cabe no espaço proposto, \
            por exemplo, ainda pode ser truncado ou quebrar linha dependendo de \
            outros modificadores como .lineLimit() e .fixedSize(). Um erro comum \
            é aplicar .frame(maxWidth: .infinity) esperando que a view 'preencha \
            o espaço disponível' e se surpreender quando isso não acontece — \
            geralmente porque a view está dentro de um container que já está \
            propondo um tamanho menor do que .infinity permitiria, e o .infinity \
            ali só define o teto máximo aceitável, não força a expansão sozinho \
            sem que o pai realmente ofereça esse espaço.
            """
        ),

        // MARK: - Sheets e Navegação Modal
        // Fonte: https://developer.apple.com/documentation/swiftui/view/sheet(item:ondismiss:content:)
        // Fonte: https://developer.apple.com/documentation/swiftui/view/fullscreencover(ispresented:ondismiss:content:)
        // Fonte: https://developer.apple.com/documentation/swiftui/environmentvalues/dismiss
        (
            topic: "Sheets e Navegação Modal",
            block: .swiftUI,
            text: """
            O modificador .sheet apresenta uma view modal que desliza de baixo \
            pra cima, cobrindo parte ou toda a tela — o padrão mais comum do \
            SwiftUI pra fluxos secundários que não fazem parte da navegação \
            principal (formulários, configurações, detalhes que interrompem o \
            fluxo por um momento). Existem duas formas principais de controlar \
            quando ele aparece: vinculado a um Bool simples através do parâmetro \
            isPresented, útil quando o conteúdo apresentado não depende de qual \
            dado específico disparou a apresentação; e vinculado a um Optional \
            de um tipo Identifiable através do parâmetro item — a sheet aparece \
            automaticamente quando esse valor deixa de ser nil, e o closure já \
            recebe o item desembrulhado e não-opcional, pronto pra passar pra \
            view de destino, o que evita ter que guardar duas variáveis de \
            estado separadas sincronizadas manualmente. Dentro da sheet \
            apresentada, o dismiss é geralmente feito lendo a action do \
            Environment (a chave dismiss), chamada a partir de um botão de \
            fechar ou ao final de um fluxo — mais idiomático do que a view \
            apresentada tentar manipular diretamente a variável de estado que a \
            apresentou, que muitas vezes nem está acessível dali.
            """
        ),
        (
            topic: "Sheets e Navegação Modal",
            block: .swiftUI,
            text: """
            fullScreenCover se comporta de forma parecida com .sheet — mesma API \
            com isPresented ou item —, mas cobre a tela inteira sem deixar \
            visível uma borda do conteúdo por trás, e no iOS não pode ser \
            dispensado com um gesto de arrastar pra baixo por padrão, sendo mais \
            apropriado pra fluxos que realmente exigem uma ação explícita do \
            usuário pra sair (como uma tela de onboarding ou de login \
            obrigatório) em vez de fluxos que podem ser abandonados a qualquer \
            momento. Um erro comum ao usar a variante baseada em item é esquecer \
            que o CONTEÚDO da sheet é recriado (não só atualizado) toda vez que \
            o item muda de identidade — se dois itens diferentes forem \
            apresentados em sequência rápida, o SwiftUI trata como duas \
            apresentações de sheet distintas, o que pode gerar uma transição \
            visual estranha se não for essa a intenção. Outro cuidado é \
            gerenciar estado local da view apresentada: como a view dentro da \
            sheet é recriada a cada apresentação (a menos que sua identidade \
            indique o contrário), qualquer @State dentro dela reseta pro valor \
            inicial toda vez que a sheet é reaberta — o que geralmente é o \
            comportamento desejado, mas pode surpreender se alguém esperava que \
            a sheet 'lembrasse' o estado anterior automaticamente.
            """
        ),

        // MARK: - Animações
        // Fonte: https://developer.apple.com/documentation/swiftui/withanimation(_:_:)
        // Fonte: https://developer.apple.com/documentation/swiftui/view/animation(_:value:)
        // Fonte: https://developer.apple.com/documentation/swiftui/view/transition(_:)
        // Fonte: https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:)
        (
            topic: "Animações",
            block: .swiftUI,
            text: """
            SwiftUI tem dois modelos principais de animação: implícita e \
            explícita. Uma animação implícita é criada com o modificador \
            .animation(_:value:), anexado a uma view e vinculado a um valor \
            específico — toda vez que esse valor muda, qualquer propriedade \
            animável afetada por esse valor dentro daquela view (posição, \
            opacidade, cor, tamanho, etc.) anima automaticamente pra transição \
            entre o estado antigo e o novo, usando a curva de animação \
            especificada (.easeInOut, .spring(), .linear, entre outras). Uma \
            animação explícita, por outro lado, é disparada envolvendo a mudança \
            de estado em si dentro de um bloco withAnimation — qualquer view \
            cujo corpo dependa dessa variável, em qualquer lugar da hierarquia, \
            anima a transição resultante, sem precisar de um .animation() \
            anexado individualmente em cada view afetada. A escolha entre os \
            dois geralmente depende do escopo: .animation(value:) é mais local e \
            declarativo, enquanto withAnimation é mais amplo e imperativo — esta \
            mudança de estado, onde quer que ela afete a UI, deve ser animada — \
            e é comum usar os dois modelos dentro do mesmo app, em contextos \
            diferentes.
            """
        ),
        (
            topic: "Animações",
            block: .swiftUI,
            text: """
            Transitions controlam como uma view anima especificamente ao ENTRAR \
            ou SAIR da hierarquia — aplicadas com o modificador \
            .transition(.opacity), .transition(.slide), .transition(.scale), \
            entre outras, ou combinações customizadas com .combined(with:) e \
            .asymmetric(insertion:removal:). Uma transition só tem efeito \
            visível quando combinada com uma mudança de estado dentro de um \
            withAnimation (ou dentro de um contexto já animado) — sem isso, a \
            view simplesmente aparece ou desaparece instantaneamente, ignorando \
            a transition declarada. matchedGeometryEffect é um recurso mais \
            avançado que permite animar a transformação geométrica (posição e \
            tamanho) entre duas views diferentes que compartilham o mesmo \
            identificador de namespace — é o mecanismo por trás de efeitos tipo \
            'hero animation', onde um elemento em uma tela parece morphar \
            suavemente pro seu equivalente em outra tela ou estado, em vez de \
            simplesmente sumir de um lugar e aparecer no outro. Um erro comum é \
            tentar animar uma mudança de estado que acontece fora de um \
            withAnimation e de um .animation(value:) — nesses casos a UI \
            simplesmente 'pula' pro novo estado sem transição nenhuma — e outro \
            é animar propriedades que mudam a identidade estrutural da view \
            esperando uma transição suave, quando na prática o SwiftUI trata \
            como troca de view, exigindo uma transition explícita pra suavizar \
            essa troca em vez de uma animação implícita comum.
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
