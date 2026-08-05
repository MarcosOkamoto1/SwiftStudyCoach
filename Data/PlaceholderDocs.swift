//
//  PlaceholderDocs.swift
//  SwiftStudyCoach
//
//  Dataset PLACEHOLDER para testar o pipeline de RAG hoje.
//  Troque pelo conteúdo real (parafraseado da documentação oficial da
//  Apple) depois que a busca estiver funcionando corretamente.
//
//  Cada string é um "chunk" — a recomendação do pacote de embeddings
//  é 200-300 palavras por chunk; os placeholders abaixo são menores
//  só pra teste rápido, ajuste o tamanho quando trocar pelo conteúdo real.
//

import Foundation

enum PlaceholderDocs {

    static let rawChunks: [(topic: String, text: String)] = [
        // MARK: - Optionals
        (
            topic: "Optionals",
            text: """
            Optionals em Swift representam a possibilidade de ausência de um valor. \
            Um tipo Optional pode conter um valor ou pode ser nil. Você declara um \
            optional adicionando um ponto de interrogação depois do tipo, como String?. \
            Para acessar o valor com segurança, use optional binding com if let ou \
            guard let, que desembrulha o optional apenas se ele contiver um valor.
            """
        ),
        (
            topic: "Optionals",
            text: """
            Force unwrapping, feito com o operador !, extrai o valor de um optional \
            sem checagem — se o optional for nil, o app trava em tempo de execução. \
            Por isso force unwrapping deve ser evitado em código de produção, exceto \
            quando você tem certeza absoluta de que o valor existe. Optional chaining, \
            usando ?., permite acessar propriedades e métodos de um optional de forma \
            segura, retornando nil automaticamente se qualquer elo da cadeia for nil.
            """
        ),
        (
            topic: "Optionals",
            text: """
            O operador nil-coalescing (??) fornece um valor padrão quando um optional \
            é nil, como em let nome = usuario.nome ?? "Anônimo". Isso é mais conciso \
            do que escrever um if/else manual para tratar o caso nil.
            """
        ),

        // MARK: - Concorrência
        (
            topic: "Concorrência",
            text: """
            Swift Concurrency introduz async/await para escrever código assíncrono de \
            forma sequencial e legível, evitando o encadeamento de closures conhecido \
            como "callback hell". Uma função marcada como async pode suspender sua \
            execução em pontos de espera (await) sem bloquear a thread.
            """
        ),
        (
            topic: "Concorrência",
            text: """
            Actors são um tipo de referência que protege seu estado mutável contra \
            acesso concorrente não sincronizado, prevenindo data races em tempo de \
            compilação. Todo acesso às propriedades de um actor a partir de fora dele \
            precisa ser feito com await, já que o acesso é serializado automaticamente.
            """
        ),
        (
            topic: "Concorrência",
            text: """
            Task cria uma nova unidade de trabalho assíncrono e concorrente. \
            TaskGroup permite disparar múltiplas tarefas filhas em paralelo e \
            aguardar todos os resultados. O atributo @MainActor garante que um \
            código específico sempre rode na thread principal, essencial para \
            atualizações de interface.
            """
        ),

        // MARK: - Generics
        (
            topic: "Generics",
            text: """
            Generics permitem escrever funções e tipos flexíveis que funcionam com \
            qualquer tipo, respeitando os requisitos que você define, em vez de \
            duplicar código para cada tipo específico. Um parâmetro de tipo genérico, \
            como <T>, é um placeholder substituído pelo tipo real no momento do uso.
            """
        ),
        (
            topic: "Generics",
            text: """
            Constraints (restrições) limitam quais tipos podem ser usados com um \
            generic, exigindo conformidade com um protocolo específico, como em \
            func maiorValor<T: Comparable>(_ itens: [T]) -> T?. Isso permite usar \
            operadores como < dentro da função genérica, já que o compilador sabe \
            que T é Comparable.
            """
        ),
        (
            topic: "Generics",
            text: """
            Associated types permitem que um protocolo declare um placeholder de \
            tipo a ser especificado por quem adota o protocolo, comum em protocolos \
            como Collection ou Sequence. Isso é diferente de generics em funções: \
            o associated type é resolvido pela struct/class que implementa o protocolo.
            """
        ),
    ]
}
