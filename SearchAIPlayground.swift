import SwiftUI
import Foundation
import PlaygroundSupport

// MARK: - Models

struct SearchResult: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let url: URL
    let snippet: String
}

struct SearchResponse {
    let query: String
    let results: [SearchResult]
}

// MARK: - Search Service

@MainActor
final class SearchService: ObservableObject {
    @Published var isLoading = false
    @Published var errorMessage: String?

    func search(query: String) async -> SearchResponse {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchResponse(query: query, results: [])
        }

        do {
            // Uses DuckDuckGo's Instant Answer API.
            // Endpoint docs: https://duckduckgo.com/api
            var components = URLComponents(string: "https://api.duckduckgo.com/")!
            components.queryItems = [
                URLQueryItem(name: "q", value: trimmed),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "no_redirect", value: "1"),
                URLQueryItem(name: "no_html", value: "1"),
                URLQueryItem(name: "skip_disambig", value: "1")
            ]

            let (data, _) = try await URLSession.shared.data(from: components.url!)
            let decoded = try JSONDecoder().decode(DDGEnvelope.self, from: data)

            let direct = decoded.directResult.map {
                SearchResult(title: $0.title, url: $0.url, snippet: $0.snippet)
            }

            let related = decoded.relatedTopicsFlat.compactMap { topic -> SearchResult? in
                guard let text = topic.text, let firstURL = topic.firstURL, let url = URL(string: firstURL) else {
                    return nil
                }

                return SearchResult(title: text.components(separatedBy: " - ").first ?? text,
                                    url: url,
                                    snippet: text)
            }

            // De-duplicate by URL and cap results
            let merged = (direct + related)
            var seen = Set<String>()
            let deduped = merged.filter { result in
                let key = result.url.absoluteString
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }

            return SearchResponse(query: trimmed, results: Array(deduped.prefix(12)))
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
            return SearchResponse(query: trimmed, results: [])
        }
    }
}

// MARK: - AI Overview (local, extractive)

struct AIOverviewBuilder {
    static func overview(for response: SearchResponse) -> String {
        guard !response.results.isEmpty else {
            return "No results found. Try a broader query or fewer keywords."
        }

        let snippets = response.results.map(\.snippet).filter { !$0.isEmpty }
        let summary = summarize(snippets: snippets)
        let themes = inferThemes(from: snippets)

        var blocks: [String] = []
        blocks.append("**AI Overview for \"\(response.query)\"**")
        blocks.append(summary)

        if !themes.isEmpty {
            blocks.append("Top themes: \(themes.joined(separator: ", ")).")
        }

        blocks.append("Sources sampled: \(min(response.results.count, 6)) of \(response.results.count) results.")
        return blocks.joined(separator: "\n\n")
    }

    private static func summarize(snippets: [String]) -> String {
        let joined = snippets.joined(separator: ". ")
        let sentences = joined
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 25 }

        guard !sentences.isEmpty else {
            return "I found relevant links, but there was not enough snippet text to build a useful summary."
        }

        let ranked = rankSentences(sentences)
        return ranked.prefix(3).joined(separator: ". ") + "."
    }

    private static func rankSentences(_ sentences: [String]) -> [String] {
        let stopWords: Set<String> = ["the","a","an","and","or","to","of","in","on","for","with","is","are","as","by","that","this","from","at","it"]

        var freq: [String: Int] = [:]
        let tokenized = sentences.map { sentence in
            sentence.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { $0.count > 2 && !stopWords.contains($0) }
        }

        for tokens in tokenized {
            for token in tokens { freq[token, default: 0] += 1 }
        }

        return zip(sentences, tokenized)
            .map { sentence, tokens -> (String, Int) in
                let score = tokens.reduce(0) { $0 + freq[$1, default: 0] }
                return (sentence, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private static func inferThemes(from snippets: [String]) -> [String] {
        let dictionary: [String: [String]] = [
            "News": ["news", "breaking", "latest", "update"],
            "Research": ["study", "paper", "analysis", "journal", "evidence"],
            "Product": ["buy", "price", "review", "features", "model"],
            "How-to": ["guide", "tutorial", "steps", "how to"],
            "Reference": ["definition", "overview", "encyclopedia", "wiki"]
        ]

        let text = snippets.joined(separator: " ").lowercased()
        let scored = dictionary.map { theme, keywords in
            let hits = keywords.reduce(0) { count, keyword in
                count + text.components(separatedBy: keyword).count - 1
            }
            return (theme, hits)
        }

        return scored
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
            .prefix(3)
            .map { $0 }
    }
}

// MARK: - DuckDuckGo API Decoding

private struct DDGEnvelope: Decodable {
    let heading: String?
    let abstractText: String?
    let abstractURL: String?
    let relatedTopics: [DDGTopic]

    enum CodingKeys: String, CodingKey {
        case heading = "Heading"
        case abstractText = "AbstractText"
        case abstractURL = "AbstractURL"
        case relatedTopics = "RelatedTopics"
    }

    var directResult: SearchResult? {
        guard let heading,
              let abstractText,
              !heading.isEmpty,
              !abstractText.isEmpty,
              let abstractURL,
              let url = URL(string: abstractURL) else {
            return nil
        }

        return SearchResult(title: heading, url: url, snippet: abstractText)
    }
}

private struct DDGTopic: Decodable {
    let text: String?
    let firstURL: String?
    let topics: [DDGTopic]?

    enum CodingKeys: String, CodingKey {
        case text = "Text"
        case firstURL = "FirstURL"
        case topics = "Topics"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        firstURL = try c.decodeIfPresent(String.self, forKey: .firstURL)
        topics = try c.decodeIfPresent([DDGTopic].self, forKey: .topics)
    }
}

extension Array where Element == DDGTopic {
    var flattened: [DDGTopic] {
        flatMap { topic in
            if let nested = topic.topics {
                return nested.flattened
            }
            return [topic]
        }
    }
}

private extension DDGEnvelope {
    var relatedTopicsFlat: [DDGTopic] {
        relatedTopics.flattened
    }
}

// MARK: - UI

struct ContentView: View {
    @StateObject private var service = SearchService()
    @State private var query = "Swift concurrency tutorial"
    @State private var response = SearchResponse(query: "", results: [])

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                HStack {
                    TextField("Search", text: $query)
                        .textFieldStyle(.roundedBorder)
                    Button("Go") {
                        Task {
                            response = await service.search(query: query)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                if service.isLoading {
                    ProgressView("Searching…")
                        .padding(.top, 8)
                }

                if let error = service.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                }

                ScrollView {
                    if !response.query.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(AIOverviewBuilder.overview(for: response))
                                .padding()
                                .background(Color.blue.opacity(0.08))
                                .cornerRadius(12)

                            Text("Results")
                                .font(.headline)

                            ForEach(response.results) { result in
                                VStack(alignment: .leading, spacing: 6) {
                                    Link(result.title, destination: result.url)
                                        .font(.headline)
                                    Text(result.url.absoluteString)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(result.snippet)
                                        .font(.subheadline)
                                }
                                .padding()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.gray.opacity(0.08))
                                .cornerRadius(10)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("Enter a query and tap Go.")
                            .foregroundColor(.secondary)
                            .padding(.top, 24)
                    }
                }
            }
            .padding()
            .navigationTitle("Search + AI Overview")
        }
    }
}

PlaygroundPage.current.setLiveView(ContentView())
