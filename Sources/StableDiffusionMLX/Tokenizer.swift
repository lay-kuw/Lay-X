// Copyright © 2024 Apple Inc.

import Foundation

struct Bigram: Hashable {
    let a: String
    let b: String

    init(_ s: String) {
        let pieces = s.split(separator: " ")
        precondition(pieces.count == 2, "BPEPair expected two pieces for '\(s)'")
        self.a = String(pieces[0])
        self.b = String(pieces[1])
    }

    init(_ a: String, _ b: String) {
        self.a = a
        self.b = b
    }

    init(_ v: (String, String)) {
        self.a = v.0
        self.b = v.1
    }
}

/// A CLIP tokenizer.
///
/// Ported from:
///
/// - https://github.com/ml-explore/mlx-examples/blob/main/stable_diffusion/stable_diffusion/tokenizer.py
/// - https://github.com/huggingface/transformers/blob/main/src/transformers/models/clip/tokenization_clip.py
///
/// Ideally this would be a tokenizer from `swift-transformers` but this is too special purpose to be representable in
/// what exists there (at time of writing).
class CLIPTokenizer {

    let pattern =
        #/<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+/#
    let bpeRanks: [Bigram: Int]
    let vocabulary: [String: Int]

    let bos = "<|startoftext|>"
    let eos = "<|endoftext|>"

    let bosToken: Int
    let eosToken: Int

    var cache = [String: [String]]()

    init(merges: [String], vocabulary: [String: Int]) {
        self.bpeRanks = Dictionary(
            uniqueKeysWithValues:
                merges
                .map { Bigram($0) }
                .enumerated()
                .map { ($0.element, $0.offset) })

        self.vocabulary = vocabulary
        self.cache[bos] = [bos]
        self.cache[eos] = [eos]
        self.bosToken = vocabulary[bos]!
        self.eosToken = vocabulary[eos]!
    }

    func bpe(text: String) -> [String] {
        if let result = cache[text] {
            return result
        }

        precondition(!text.isEmpty)

        var unigrams = text.dropLast().map { String($0) } + ["\(text.last!)</w>"]
        var uniqueBigrams = Set(zip(unigrams, unigrams.dropFirst()).map { Bigram($0) })

        // In every iteration try to merge the two most likely bigrams. If none
        // was merged we are done

        while !uniqueBigrams.isEmpty {
            let (bigram, _) =
                uniqueBigrams
                .map { ($0, bpeRanks[$0] ?? Int.max) }
                .min { $0.1 < $1.1 }!

            if bpeRanks[bigram] == nil {
                break
            }

            var newUnigrams = [String]()
            var skip = false

            for (a, b) in zip(unigrams, unigrams.dropFirst()) {
                if skip {
                    skip = false
                    continue
                }

                if Bigram(a, b) == bigram {
                    newUnigrams.append(a + b)
                    skip = true
                } else {
                    newUnigrams.append(a)
                }
            }

            if !skip, let last = unigrams.last {
                newUnigrams.append(last)
            }

            unigrams = newUnigrams
            uniqueBigrams = Set(zip(unigrams, unigrams.dropFirst()).map { Bigram($0) })
        }

        cache[text] = unigrams

        return unigrams
    }

    /// Token ids of `text` without BOS / EOS.
    func contentTokens(_ text: String) -> [Int] {
        // Lower case cleanup and split according to self.pat. Hugging Face does
        // a much more thorough job here but this should suffice for 95% of
        // cases.

        let clean = text.lowercased().replacing(#/\s+/#, with: " ")
        let tokens = clean.matches(of: pattern).map { $0.description }

        // Split the tokens according to the byte-pair merge file
        let bpeTokens = tokens.flatMap { bpe(text: String($0)) }
        return bpeTokens.compactMap { vocabulary[$0] }
    }

    // The text encoder has a fixed 77-position embedding (a longer sequence aborts with `[broadcast_shapes]`):
    // BOS + up to 75 content tokens + EOS = 77 per chunk.
    static let maxContentTokens = 77 - 2
    /// Lay X: longer prompts are split into chunks of 75 tokens, each encoded on its own and joined (as in A1111).
    static let maxChunks = 8
    /// A full chunk ends after its last comma when that comma is at most this many tokens from the end, so a
    /// phrase isn't cut in half.
    static let commaBacktrack = 20

    /// One chunk: BOS + content + EOS, with the emphasis of each token (BOS / EOS at 1).
    public struct Chunk: Sendable {
        public var tokens: [Int32]
        public var weights: [Float]
    }

    /// Lay X: the prompt in chunks of up to 75 tokens. `BREAK` (upper case, a word of its own) starts a new chunk.
    public func tokenizeChunks(segments: [WeightedText]) -> [Chunk] {
        let comma = vocabulary[",</w>"]
        var chunks: [([Int], [Float])] = []
        var ids: [Int] = []
        var weights: [Float] = []
        var lastComma = -1
        func close() {
            chunks.append((ids, weights))
            ids = []
            weights = []
            lastComma = -1
        }
        for segment in segments {
            for (n, part) in segment.text.split(separator: #/\bBREAK\b/#,
                                                 omittingEmptySubsequences: false).enumerated() {
                if n > 0 { close() }
                for id in contentTokens(String(part)) {
                    if ids.count == Self.maxContentTokens {
                        if lastComma >= 0, ids.count - (lastComma + 1) <= Self.commaBacktrack {
                            // Carry the words after the comma over to the next chunk.
                            let restIDs = Array(ids[(lastComma + 1)...]), restWeights = Array(weights[(lastComma + 1)...])
                            ids.removeSubrange((lastComma + 1)...)
                            weights.removeSubrange((lastComma + 1)...)
                            close()
                            ids = restIDs
                            weights = restWeights
                        } else {
                            close()
                        }
                    }
                    if id == comma { lastComma = ids.count }
                    ids.append(id)
                    weights.append(segment.weight)
                }
            }
        }
        if !ids.isEmpty || chunks.isEmpty { close() }
        return chunks.prefix(Self.maxChunks).map { ids, weights in
            Chunk(tokens: ([bosToken] + ids + [eosToken]).map { Int32($0) }, weights: [1] + weights + [1])
        }
    }

    public func tokenize(text: String) -> [Int32] {
        tokenizeChunks(segments: [WeightedText(text)])[0].tokens
    }
}
