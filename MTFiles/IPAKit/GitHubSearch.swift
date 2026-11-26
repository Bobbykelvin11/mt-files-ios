import Foundation

struct GitHubIPAResult: Identifiable, Hashable {
    var id: String { downloadURL.absoluteString }
    let repoFullName: String
    let repoDescription: String
    let stars: Int
    let releaseTag: String
    let assetName: String
    let assetSize: Int64
    let downloadURL: URL
    let repoURL: URL
}

/// Searches public GitHub repos and their releases for .ipa assets.
enum GitHubSearch {
    private static let stopWords: Set<String> = [
        "find", "search", "look", "for", "get", "download", "me", "an", "a", "the", "app", "apps",
        "ipa", "ipas", "open", "source", "opensource", "open-source", "free", "alternative", "alternatives",
        "to", "of", "ios", "iphone", "please", "some", "like", "similar", "best", "good", "github", "release", "releases"
    ]

    static func keywords(from query: String) -> String {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-+.")).inverted)
            .filter { !$0.isEmpty && !stopWords.contains($0) }
        return words.joined(separator: " ")
    }

    private struct RepoSearch: Decodable { let items: [Repo] }
    private struct Repo: Decodable {
        let full_name: String
        let description: String?
        let stargazers_count: Int
        let html_url: String
    }
    fileprivate struct Release: Decodable {
        let tag_name: String
        let draft: Bool?
        let assets: [Asset]
    }
    fileprivate struct Asset: Decodable {
        let name: String
        let size: Int64
        let browser_download_url: String
    }

    private static func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MTFiles/1.0", forHTTPHeaderField: "User-Agent")
        let token = Keychain.get("github_token")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 20
        return req
    }

    fileprivate static func fetch<T: Decodable>(_ url: URL, as type: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: request(url))
        if let http = resp as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 429 {
            throw StudioError.message("GitHub rate limit reached. Wait a minute, or add a free GitHub token in Settings.")
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StudioError.message("GitHub returned HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func searchRepos(_ q: String) async throws -> [Repo] {
        var comps = URLComponents(string: "https://api.github.com/search/repositories")!
        comps.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "per_page", value: "15")
        ]
        return try await fetch(comps.url!, as: RepoSearch.self).items
    }

    static func search(_ query: String) async throws -> [GitHubIPAResult] {
        var terms = keywords(from: query)
        if terms.isEmpty { terms = query }
        // Two passes: repos that mention ipa, and iOS repos in general.
        var repos: [Repo] = []
        var seen = Set<String>()
        for q in ["\(terms) ipa", "\(terms) ios", terms] {
            if repos.count >= 12 { break }
            let found = (try? await searchRepos(q)) ?? []
            for r in found where !seen.contains(r.full_name) {
                seen.insert(r.full_name)
                repos.append(r)
            }
        }
        if repos.isEmpty {
            // surface a real error (e.g. rate limit) if the plain search fails
            _ = try await searchRepos(terms)
            return []
        }
        repos = Array(repos.sorted { $0.stargazers_count > $1.stargazers_count }.prefix(14))

        return await withTaskGroup(of: [GitHubIPAResult].self) { group in
            for repo in repos {
                group.addTask {
                    guard let url = URL(string: "https://api.github.com/repos/\(repo.full_name)/releases?per_page=5"),
                          let releases = try? await GitHubSearch.fetch(url, as: [Release].self) else { return [] }
                    for rel in releases where rel.draft != true {
                        let ipas = rel.assets.filter { $0.name.lowercased().hasSuffix(".ipa") }
                        if !ipas.isEmpty {
                            return ipas.prefix(3).compactMap { (a: Asset) -> GitHubIPAResult? in
                                guard let dl = URL(string: a.browser_download_url), let page = URL(string: repo.html_url) else { return nil }
                                return GitHubIPAResult(
                                    repoFullName: repo.full_name, repoDescription: repo.description ?? "",
                                    stars: repo.stargazers_count, releaseTag: rel.tag_name, assetName: a.name,
                                    assetSize: a.size, downloadURL: dl, repoURL: page
                                )
                            }
                        }
                    }
                    return []
                }
            }
            var all: [GitHubIPAResult] = []
            for await chunk in group { all += chunk }
            return all.sorted { $0.stars > $1.stars }
        }
    }
}
