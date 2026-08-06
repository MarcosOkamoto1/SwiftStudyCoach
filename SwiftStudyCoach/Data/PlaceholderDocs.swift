//
//  PlaceholderDocs.swift
//  SwiftStudyCoach
//
//  Dataset de documentação parafraseada, baseado nos conceitos reais da
//  documentação oficial da Apple, para os 3 tópicos escolhidos:
//  NavigationStack, Property Wrappers (State/Binding/Observable) e Guard.
//
//  Chunks de ~200-250 palavras, seguindo a recomendação do pacote de
//  embeddings para melhor qualidade de busca semântica.
//
//  IMPORTANTE: ao trocar este dataset, incrementar DatasetVersion.current
//  (ver Persistence.swift) para invalidar o cache de tópicos já gerados.
//

import Foundation

enum PlaceholderDocs {

    static let rawChunks: [(topic: String, text: String)] = [

        // MARK: - NavigationStack
        (
            topic: "NavigationStack",
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

        // MARK: - Property Wrappers
        (
            topic: "Property Wrappers",
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

        // MARK: - Guard
        (
            topic: "Guard",
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
            text: """
            Um guard pode combinar múltiplas condições separadas por \
            vírgula, incluindo mais de um guard let na mesma instrução, e \
            também cláusulas where para checagens adicionais sobre um valor \
            já desembrulhado. Por exemplo: guard let usuario = usuarioAtual, \
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
            está disponível na cláusula where daquele mesmo guard, mesmo \
            tendo sido desembrulhada poucos caracteres antes na mesma \
            instrução.
            """
        ),
        (
            topic: "Guard",
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
            cláusula where subsequente. Guards também interagem de forma \
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
    ]
}
