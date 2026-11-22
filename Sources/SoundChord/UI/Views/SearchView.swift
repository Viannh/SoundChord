import SwiftUI

public struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    private enum SearchFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case songs = "Songs"
        case addons = "Addons"
        case albums = "Albums"
        case artists = "Artists"
        case playlists = "Playlists"

        var id: String { rawValue }
    }

    @State private var selectedFilter: SearchFilter = .all
    @State private var showSuggestions = false
    @FocusState private var isSearchFocused: Bool

    private static let browseCategories: [(title: String, query: String, color: Color, icon: String)] = [
        ("Pop", "Top Pop hits", Color(red: 0.96, green: 0.25, blue: 0.44), "sparkles"),
        ("Hip-Hop", "Hip-Hop hits", Color(red: 0.95, green: 0.52, blue: 0.14), "flame.fill"),
        ("Rock", "Rock classics & new", Color(red: 0.78, green: 0.16, blue: 0.24), "guitars.fill"),
        ("Electronic", "Electronic dance", Color(red: 0.45, green: 0.26, blue: 0.95), "waveform.path.ecg"),
        ("Chill", "Chill lofi beats", Color(red: 0.16, green: 0.62, blue: 0.88), "moon.stars.fill"),
        ("R&B & Soul", "R&B Soul", Color(red: 0.68, green: 0.24, blue: 0.68), "heart.fill"),
        ("Indie & Alt", "Indie alternative", Color(red: 0.16, green: 0.72, blue: 0.56), "leaf.fill"),
        ("Jazz", "Jazz essentials", Color(red: 0.82, green: 0.62, blue: 0.16), "music.quarternote.3")
    ]

    public var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header + Centered Pill Search Field
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Search")
                            .font(.system(size: 34, weight: .bold))

                        searchFieldBar
                    }
                    .padding(.horizontal, 36)
                    .padding(.top, 28)

                    // Category Filter Pills when results exist
                    if appState.searchResults != nil || !appState.addonSearchResults.isEmpty || appState.isSearchingAddons {
                        filterPillsBar
                            .padding(.horizontal, 36)
                    }

                    // Body Content
                    if selectedFilter == .addons {
                        addonSearchResultsSection
                    } else if appState.isSearching {
                        searchLoadingSkeleton
                    } else if let results = appState.searchResults {
                        if results.isEmpty && appState.addonSearchResults.isEmpty {
                            BCEmptyStateView(
                                icon: "magnifyingglass",
                                title: "No Results for \"\(results.query)\"",
                                message: "Try checking your spelling or searching for a different song, artist, album, or playlist."
                            )
                            .padding(.horizontal, 36)
                        } else {
                            searchResultsContent(results)
                        }
                    } else {
                        idleLandingContent
                    }
                }
                .padding(.bottom, 110)
            }

            // Live Debounced Suggestions Dropdown Overlay
            if showSuggestions && !appState.searchSuggestions.isEmpty && isSearchFocused {
                VStack {
                    suggestionsDropdown
                        .frame(maxWidth: 560)
                        .padding(.top, 128)
                        .padding(.horizontal, 36)
                    Spacer()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
                .zIndex(50)
            }
        }
        .onAppear {
            if appState.searchQuery.isEmpty && appState.searchResults == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFocused = true
                }
            }
        }
    }

    // MARK: - Search Field

    private var searchFieldBar: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme)
        let border = isSearchFocused ? accent : SoundChordTheme.hairline(for: colorScheme)

        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))

            TextField(
                "Artists, songs, albums, and playlists",
                text: Binding(
                    get: { appState.searchQuery },
                    set: { newValue in
                        appState.updateSearchSuggestions(for: newValue)
                        showSuggestions = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                )
            )
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .focused($isSearchFocused)
            .onSubmit {
                submitSearch(appState.searchQuery)
            }

            if !appState.searchQuery.isEmpty {
                Button {
                    appState.searchQuery = ""
                    appState.searchSuggestions = []
                    appState.searchResults = nil
                    appState.addonSearchResults = []
                    showSuggestions = false
                    selectedFilter = .all
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                }
                .buttonStyle(.plain)
            }

            Button {
                submitSearch(appState.searchQuery)
            } label: {
                Text("Search")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accentFg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
            .disabled(appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .frame(maxWidth: 560)
        .background(Capsule().fill(cardBg))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(border, lineWidth: isSearchFocused ? 1.5 : 1)
        )
    }

    // MARK: - Suggestions Dropdown

    private var suggestionsDropdown: some View {
        let bg = SoundChordTheme.elevatedBackground(for: colorScheme)
        let border = SoundChordTheme.hairline(for: colorScheme)

        return VStack(alignment: .leading, spacing: 2) {
            ForEach(appState.searchSuggestions.prefix(8)) { suggestion in
                SearchSuggestionRow(suggestion: suggestion) {
                    if let item = suggestion.item {
                        showSuggestions = false
                        isSearchFocused = false
                        openShelfItem(item)
                    } else {
                        submitSearch(suggestion.text)
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                .fill(bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                .strokeBorder(border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.5 : 0.16), radius: 18, y: 8)
    }

    // MARK: - Filter Pills

    private var filterPillsBar: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let cardBg = SoundChordTheme.cardBackground(for: colorScheme)

        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchFilter.allCases) { filter in
                    let isSelected = selectedFilter == filter
                    let labelText: String = {
                        if filter == .addons && !appState.addonSearchResults.isEmpty {
                            return "Addons (\(appState.addonSearchResults.count))"
                        }
                        return filter.rawValue
                    }()
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedFilter = filter
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if filter == .addons {
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            Text(labelText)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(isSelected ? accentFg : primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isSelected ? accent : cardBg)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Idle Landing (Recent Searches + Browse Categories)

    private var idleLandingContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            // Recent Searches
            if !appState.libraryStore.searchHistory.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Recent Searches")
                            .font(.system(size: 18, weight: .bold))
                        Spacer()
                        Button {
                            appState.libraryStore.clearSearchHistory()
                        } label: {
                            Text("Clear")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                        }
                        .buttonStyle(.plain)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(appState.libraryStore.searchHistory, id: \.self) { query in
                                Button {
                                    submitSearch(query)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.system(size: 11))
                                            .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                                        Text(query)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(SoundChordTheme.primaryText(for: colorScheme))
                                    }
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 7)
                                    .background(Capsule().fill(SoundChordTheme.cardBackground(for: colorScheme)))
                                    .overlay(Capsule().strokeBorder(SoundChordTheme.hairline(for: colorScheme), lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.horizontal, 36)
            }

            // Browse Categories Bricks (Apple Music Search Landing Style)
            VStack(alignment: .leading, spacing: 14) {
                Text("Browse Categories")
                    .font(.system(size: 18, weight: .bold))

                let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)]
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Self.browseCategories, id: \.title) { cat in
                        SearchCategoryTile(title: cat.title, color: cat.color, icon: cat.icon) {
                            submitSearch(cat.query)
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
        }
    }

    // MARK: - Search Results Content

    @ViewBuilder
    private func searchResultsContent(_ results: SearchResults) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            // Top Result Hero Card (shown in All tab)
            if selectedFilter == .all, let top = results.topResult {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Top Result")
                        .font(.system(size: 18, weight: .bold))
                    TopResultHeroCard(item: top)
                }
                .padding(.horizontal, 36)
            }

            // Songs Section
            if (selectedFilter == .all || selectedFilter == .songs) && !results.songs.isEmpty {
                let songsToShow = selectedFilter == .all ? Array(results.songs.prefix(6)) : results.songs
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Songs")
                            .font(.system(size: 18, weight: .bold))
                        Spacer()
                        if selectedFilter == .all && results.songs.count > 6 {
                            Button("See All") {
                                selectedFilter = .songs
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                        }
                    }
                    .padding(.horizontal, 36)

                    LazyVStack(spacing: 2) {
                        ForEach(songsToShow) { song in
                            BCStandardTrackRow(
                                track: song,
                                showArtwork: true,
                                showAlbumColumn: true,
                                queueContext: results.songs
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }

            // Addon Results Preview (shown in All tab when addons returned lossless hits)
            if selectedFilter == .all && !appState.addonSearchResults.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        HStack(spacing: 7) {
                            Image(systemName: "puzzlepiece.extension.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                            Text("From Your Addons")
                                .font(.system(size: 18, weight: .bold))
                        }
                        Spacer()
                        if appState.addonSearchResults.count > 4 {
                            Button("See All (\(appState.addonSearchResults.count))") {
                                selectedFilter = .addons
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                        }
                    }
                    .padding(.horizontal, 36)

                    LazyVStack(spacing: 2) {
                        ForEach(Array(appState.addonSearchResults.prefix(4))) { track in
                            AddonSearchTrackRow(
                                track: track,
                                queueContext: appState.addonSearchResults
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }

            // Albums Section
            if (selectedFilter == .all || selectedFilter == .albums) && !results.albums.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Albums")
                            .font(.system(size: 18, weight: .bold))
                        Spacer()
                        if selectedFilter == .all && results.albums.count > 6 {
                            Button("See All") { selectedFilter = .albums }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                        }
                    }
                    .padding(.horizontal, 36)

                    if selectedFilter == .albums {
                        let cols = [GridItem(.adaptive(minimum: 184, maximum: 210), spacing: 20)]
                        LazyVGrid(columns: cols, spacing: 24) {
                            ForEach(results.albums) { album in
                                BCSquareCard(item: .album(album), size: 184)
                            }
                        }
                        .padding(.horizontal, 36)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 18) {
                                ForEach(results.albums) { album in
                                    BCSquareCard(item: .album(album), size: 184)
                                }
                            }
                            .padding(.horizontal, 36)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            // Artists Section
            if (selectedFilter == .all || selectedFilter == .artists) && !results.artists.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Artists")
                            .font(.system(size: 18, weight: .bold))
                        Spacer()
                        if selectedFilter == .all && results.artists.count > 6 {
                            Button("See All") { selectedFilter = .artists }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                        }
                    }
                    .padding(.horizontal, 36)

                    if selectedFilter == .artists {
                        let cols = [GridItem(.adaptive(minimum: 140, maximum: 164), spacing: 20)]
                        LazyVGrid(columns: cols, spacing: 24) {
                            ForEach(results.artists) { artist in
                                BCArtistCircleCard(artist: artist, size: 124)
                            }
                        }
                        .padding(.horizontal, 36)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 20) {
                                ForEach(results.artists) { artist in
                                    BCArtistCircleCard(artist: artist, size: 124)
                                }
                            }
                            .padding(.horizontal, 36)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            // Playlists Section
            if (selectedFilter == .all || selectedFilter == .playlists) && !results.playlists.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Playlists")
                            .font(.system(size: 18, weight: .bold))
                        Spacer()
                        if selectedFilter == .all && results.playlists.count > 6 {
                            Button("See All") { selectedFilter = .playlists }
                                .buttonStyle(.plain)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                        }
                    }
                    .padding(.horizontal, 36)

                    if selectedFilter == .playlists {
                        let cols = [GridItem(.adaptive(minimum: 184, maximum: 210), spacing: 20)]
                        LazyVGrid(columns: cols, spacing: 24) {
                            ForEach(results.playlists) { playlist in
                                BCSquareCard(item: .playlist(playlist), size: 184)
                            }
                        }
                        .padding(.horizontal, 36)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 18) {
                                ForEach(results.playlists) { playlist in
                                    BCSquareCard(item: .playlist(playlist), size: 184)
                                }
                            }
                            .padding(.horizontal, 36)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private var addonSearchResultsSection: some View {
        let enabledAddons = appState.addonManager.addons.filter(\.isEnabled)
        return VStack(alignment: .leading, spacing: 14) {
            if enabledAddons.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("No Addons Enabled")
                        .font(.system(size: 18, weight: .bold))
                    Text("Install and enable a BitChord addon like Resonance (Qobuz Hi-Res + TIDAL) or ReZenOnance to search Lossless FLAC catalogues directly.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button {
                        appState.selectSidebar(.addons)
                    } label: {
                        Label("Open Addons & Sources", systemImage: "puzzlepiece.extension.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SoundChordTheme.accentForeground(for: colorScheme))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(SoundChordTheme.accentColor(for: colorScheme)))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
                .padding(.horizontal, 36)
            } else if appState.isSearchingAddons {
                searchLoadingSkeleton
            } else if appState.addonSearchResults.isEmpty {
                BCEmptyStateView(
                    icon: "puzzlepiece.extension",
                    title: "No Addon Matches",
                    message: "None of your \(enabledAddons.count) enabled addon\(enabledAddons.count == 1 ? "" : "s") returned tracks for \"\(appState.searchQuery)\"."
                )
                .padding(.horizontal, 36)
            } else {
                HStack {
                    Text("Addon Tracks (\(appState.addonSearchResults.count))")
                        .font(.system(size: 18, weight: .bold))
                    Spacer()
                    Button {
                        appState.selectSidebar(.addons)
                    } label: {
                        Text("Manage Addons")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SoundChordTheme.accentColor(for: colorScheme))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 36)

                LazyVStack(spacing: 2) {
                    ForEach(appState.addonSearchResults) { track in
                        AddonSearchTrackRow(
                            track: track,
                            queueContext: appState.addonSearchResults
                        )
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private var searchLoadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 24) {
            BCShimmerBox(cornerRadius: 16)
                .frame(maxWidth: 460, minHeight: 132, maxHeight: 132)
                .padding(.horizontal, 36)

            VStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: 12) {
                        BCShimmerBox(cornerRadius: 6).frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 6) {
                            BCShimmerBox(cornerRadius: 4).frame(width: 220, height: 12)
                            BCShimmerBox(cornerRadius: 4).frame(width: 140, height: 10)
                        }
                        Spacer()
                        BCShimmerBox(cornerRadius: 4).frame(width: 40, height: 10)
                    }
                    .padding(.horizontal, 36)
                    .frame(height: 50)
                }
            }
        }
    }

    // MARK: - Helpers

    private func submitSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        showSuggestions = false
        isSearchFocused = false
        if selectedFilter != .addons {
            selectedFilter = .all
        }
        Task {
            await appState.performSearch(trimmed)
        }
    }

    private func openShelfItem(_ item: ShelfItem) {
        switch item {
        case .track(let t): appState.play(track: t)
        case .album(let a): appState.openDestination(.album(a))
        case .artist(let a): appState.openDestination(.artist(a))
        case .playlist(let p): appState.openDestination(.playlist(p))
        }
    }
}

// MARK: - Search Subcomponents

private struct SearchSuggestionRow: View {
    @Environment(\.colorScheme) private var colorScheme
    let suggestion: SearchSuggestion
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)

        return Button(action: onTap) {
            HStack(spacing: 10) {
                if let item = suggestion.item {
                    let isArtist: Bool = {
                        if case .artist = item { return true }
                        return false
                    }()
                    ArtworkImage(
                        url: item.artworkURL,
                        size: 36,
                        cornerRadius: isArtist ? 18 : SoundChordTheme.cornerRadiusArtworkSmall,
                        isCircle: isArtist
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isHovered ? accentFg : primary)
                            .lineLimit(1)
                        Text("\(item.kindLabel) · \(item.subtitle)")
                            .font(.system(size: 11))
                            .foregroundStyle(isHovered ? accentFg.opacity(0.85) : secondary)
                            .lineLimit(1)
                    }
                } else {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(isHovered ? accentFg : secondary)
                        .frame(width: 20)
                    Text(suggestion.text)
                        .font(.system(size: 13))
                        .foregroundStyle(isHovered ? accentFg : primary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                    .fill(isHovered ? accent : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct TopResultHeroCard: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let item: ShelfItem
    @State private var isHovered = false

    private var isArtist: Bool {
        if case .artist = item { return true }
        return false
    }

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let accentFg = SoundChordTheme.accentForeground(for: colorScheme)

        return HStack(spacing: 18) {
            ArtworkImage(
                url: item.artworkURL,
                size: 96,
                cornerRadius: isArtist ? 48 : SoundChordTheme.cornerRadiusCard,
                isCircle: isArtist
            )
            .shadow(color: .black.opacity(0.24), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.kindLabel.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(accent.opacity(0.16)))

                Text(item.title)
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)

                Text(item.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(SoundChordTheme.secondaryText(for: colorScheme))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                handlePrimaryAction()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isArtist ? "arrow.right.circle.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(isArtist ? "View Artist" : "Play")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(accentFg)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Capsule().fill(accent))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: 580)
        .soundCardSurface(cornerRadius: SoundChordTheme.cornerRadiusCard, isHovered: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous))
        .onTapGesture {
            openItem()
        }
        .onHover { isHovered = $0 }
    }

    private func openItem() {
        switch item {
        case .track(let t): appState.play(track: t)
        case .album(let a): appState.openDestination(.album(a))
        case .artist(let a): appState.openDestination(.artist(a))
        case .playlist(let p): appState.openDestination(.playlist(p))
        }
    }

    private func handlePrimaryAction() {
        switch item {
        case .track(let t):
            appState.play(track: t)
        case .album(let a):
            if !a.tracks.isEmpty {
                appState.playAlbum(a)
            } else {
                Task {
                    if let full = try? await appState.innerTube.fetchAlbum(browseId: a.id), !full.tracks.isEmpty {
                        appState.playAlbum(full)
                    } else {
                        appState.openDestination(.album(a))
                    }
                }
            }
        case .playlist(let p):
            if !p.tracks.isEmpty {
                appState.playPlaylist(p)
            } else {
                Task {
                    if let full = try? await appState.innerTube.fetchPlaylist(browseId: p.id), !full.tracks.isEmpty {
                        appState.playPlaylist(full)
                    } else {
                        appState.openDestination(.playlist(p))
                    }
                }
            }
        case .artist(let a):
            appState.openDestination(.artist(a))
        }
    }
}

private struct SearchCategoryTile: View {
    let title: String
    let color: Color
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [color.opacity(0.92), color.opacity(0.52)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: icon)
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(.white.opacity(0.20))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(14)

                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(14)
            }
            .frame(height: 112)
            .clipShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                    .strokeBorder(Color.white.opacity(isHovered ? 0.28 : 0.12), lineWidth: 1)
            )
            .shadow(color: color.opacity(isHovered ? 0.28 : 0.12), radius: isHovered ? 10 : 4, y: 3)
            .scaleEffect(isHovered ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

private struct AddonSearchTrackRow: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    let track: Track
    let queueContext: [Track]
    @State private var isHovered = false

    private var isCurrent: Bool {
        appState.audioEngine.currentTrack?.id == track.id
    }

    var body: some View {
        let accent = SoundChordTheme.accentColor(for: colorScheme)
        let primary = SoundChordTheme.primaryText(for: colorScheme)
        let secondary = SoundChordTheme.secondaryText(for: colorScheme)
        let hoverBg = SoundChordTheme.cardBackground(for: colorScheme, hovered: true)

        return Button {
            appState.play(track: track, queue: queueContext)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    ArtworkImage(url: track.artworkURL, size: 42, cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall)
                    if isCurrent || isHovered {
                        RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusArtworkSmall, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                            .frame(width: 42, height: 42)
                        if isCurrent {
                            MiniEqualizerBars(isPlaying: appState.audioEngine.isPlaying, tint: .white)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.system(size: 13.5, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? accent : primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(track.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(secondary)
                            .lineLimit(1)

                        if let album = track.album, !album.isEmpty {
                            Text("·")
                                .foregroundStyle(secondary.opacity(0.6))
                            Text(album)
                                .font(.system(size: 12))
                                .foregroundStyle(secondary.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                }

                Spacer(minLength: 10)

                HStack(spacing: 6) {
                    if let quality = track.qualityLabel, !quality.isEmpty {
                        Text(quality)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(quality.lowercased().contains("hi-res") || quality.lowercased().contains("flac") || quality.lowercased().contains("lossless") ? .green : secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(quality.lowercased().contains("hi-res") || quality.lowercased().contains("flac") || quality.lowercased().contains("lossless") ? Color.green.opacity(0.14) : Color.primary.opacity(0.07))
                            )
                    }

                    if let source = track.sourceName, !source.isEmpty {
                        Text(source)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(accent.opacity(0.14))
                            )
                    }
                }

                if track.duration > 0 {
                    Text(track.formattedDuration)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(secondary)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous)
                    .fill(isHovered || isCurrent ? hoverBg : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: SoundChordTheme.cornerRadiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Play") {
                appState.play(track: track, queue: queueContext)
            }
            Button("Play Next") {
                appState.audioEngine.addToQueue(track, playNext: true)
                appState.showToast("Playing \"\(track.title)\" next")
            }
            Button("Add to Queue") {
                appState.audioEngine.addToQueue(track, playNext: false)
                appState.showToast("Added \"\(track.title)\" to Up Next")
            }
            Divider()
            let liked = appState.libraryStore.isLiked(track.id)
            Button(liked ? "Remove from Liked Songs" : "Add to Liked Songs") {
                appState.libraryStore.toggleLike(track)
            }
            if !appState.libraryStore.playlists.isEmpty {
                Menu("Add to Playlist") {
                    ForEach(appState.libraryStore.playlists) { playlist in
                        Button(playlist.title) {
                            appState.libraryStore.addToPlaylist(playlistId: playlist.id, track: track)
                            appState.showToast("Added to \"\(playlist.title)\"")
                        }
                    }
                }
            }
        }
    }
}
