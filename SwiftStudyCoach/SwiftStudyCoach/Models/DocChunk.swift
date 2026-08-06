//
//  DocChunk.swift
//  SwiftStudyCoach
//
//  Representa um trecho (chunk) de documentação indexado para o RAG.
//  O array `embedding` é gerado uma vez, no indexing, e reutilizado
//  em toda busca — não recalculamos embedding do chunk a cada query,
//  só o embedding da query do usuário.
//

import Foundation

struct DocChunk: Identifiable, Codable {
    let id: UUID
    let topic: String       // ex: "Optionals", "Concorrência", "Generics"
    let text: String        // o trecho de texto em si (parafraseado da doc oficial)
    var embedding: [Double] // preenchido pelo DocumentIndex ao carregar

    init(id: UUID = UUID(), topic: String, text: String, embedding: [Double] = []) {
        self.id = id
        self.topic = topic
        self.text = text
        self.embedding = embedding
    }
}
