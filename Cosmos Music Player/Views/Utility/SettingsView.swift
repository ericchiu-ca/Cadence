import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var deleteSettings = DeleteSettings.load()
    @State private var showDeleteFolderPlaylistsPrompt = false

    private func deleteExistingFolderPlaylists() {
        do {
            let folderPlaylists = try DatabaseManager.shared.getAllFolderPlaylists()
            for playlist in folderPlaylists {
                if let id = playlist.id {
                    // Through the coordinator so the iCloud/local JSON copy is
                    // deleted too; otherwise the next scan's restore recreated
                    // each one as an ordinary playlist.
                    try AppCoordinator.shared.deletePlaylist(playlistId: id)
                }
            }
            print("🗑️ Deleted \(folderPlaylists.count) folder playlist(s) after disabling auto-creation")
        } catch {
            print("❌ Failed to delete folder playlists: \(error)")
        }
    }

    private func aboutLinkRow(_ title: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "arrow.up.right.square")
                .foregroundStyle(.secondary)
                .font(.system(size: 16))
        }
        .contentShape(Rectangle())
    }

    var body: some View {
        NavigationView {
            Form {
                Section(Localized.appearance) {
                    Toggle(Localized.minimalistLibraryIcons, isOn: $deleteSettings.minimalistIcons)
                        .onChange(of: deleteSettings.minimalistIcons) { _, _ in
                            deleteSettings.save()
                        }
                    
                    Text(Localized.useSimpleIcons)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Picker(Localized.appAppearance, selection: $deleteSettings.appearance) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: deleteSettings.appearance) { _, _ in
                        deleteSettings.save()
                    }

                    Text(Localized.appAppearanceDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text(Localized.backgroundColor)
                            .font(.headline)
                        
                        LazyVGrid(columns: [
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible()),
                            GridItem(.flexible())
                        ], spacing: 16) {
                            ForEach(BackgroundColor.allCases, id: \.self) { color in
                                Button(action: {
                                    deleteSettings.backgroundColorChoice = color
                                    deleteSettings.save()
                                    NotificationCenter.default.post(name: NSNotification.Name("BackgroundColorChanged"), object: nil)
                                }) {
                                    ZStack {
                                        Circle()
                                            .fill(color.color)
                                            .frame(width: 44, height: 44)
                                            .overlay(
                                                Circle()
                                                    .stroke(deleteSettings.backgroundColorChoice == color ? Color.primary : Color.clear, lineWidth: 3)
                                            )
                                        
                                        if deleteSettings.backgroundColorChoice == color {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 16, weight: .bold))
                                                .foregroundColor(.white)
                                        }
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                    
                    Text(Localized.chooseColorTheme)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                
                Section(Localized.audioSettings) {
                    NavigationLink(destination: EQSettingsView()) {
                        HStack {
                            Image(systemName: "slider.horizontal.3")
                                .foregroundColor(.blue)
                                .font(.system(size: 20))
                            Text(Localized.graphicEqualizer)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localized.dsdPlaybackMode)
                            .font(.headline)

                        Text(Localized.dsdPlaybackModeDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $deleteSettings.dsdPlaybackMode) {
                            ForEach(DSDPlaybackMode.allCases, id: \.self) { mode in
                                VStack(alignment: .leading) {
                                    Text(mode.displayName)
                                        .font(.body)
                                }
                                .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: deleteSettings.dsdPlaybackMode) { _, _ in
                            deleteSettings.save()
                        }

                        Text(deleteSettings.dsdPlaybackMode.description)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                    .padding(.vertical, 4)
                }

                Section(Localized.librarySection) {
                    Toggle(Localized.splitArtistsOnComma, isOn: $deleteSettings.splitArtistsOnComma)
                        .onChange(of: deleteSettings.splitArtistsOnComma) { _, _ in
                            deleteSettings.save()
                        }

                    Text(Localized.splitArtistsOnCommaDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Picker(Localized.libraryScanFrequency, selection: $deleteSettings.libraryScanInterval) {
                            ForEach(LibraryScanInterval.allCases, id: \.self) { interval in
                                Text(interval.displayName).tag(interval)
                            }
                        }
                        .onChange(of: deleteSettings.libraryScanInterval) { _, _ in
                            deleteSettings.save()
                        }

                        Text(Localized.libraryScanFrequencyDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)

                    Toggle(Localized.removeFromLibraryOnly, isOn: $deleteSettings.deleteFromLibraryOnly)
                        .onChange(of: deleteSettings.deleteFromLibraryOnly) { _, _ in
                            deleteSettings.save()
                        }

                    Text(Localized.removeFromLibraryOnlyDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle(Localized.autoFolderPlaylists, isOn: $deleteSettings.autoCreateFolderPlaylists)
                        .onChange(of: deleteSettings.autoCreateFolderPlaylists) { _, newValue in
                            deleteSettings.save()
                            if newValue {
                                // Re-enabled: clear tombstones so folder playlists
                                // can be recreated on the next scan
                                try? DatabaseManager.shared.clearDeletedFolderPlaylistTombstones()
                            } else {
                                showDeleteFolderPlaylistsPrompt = true
                            }
                        }

                    Text(Localized.autoFolderPlaylistsDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .alert(Localized.deleteFolderPlaylistsTitle, isPresented: $showDeleteFolderPlaylistsPrompt) {
                    Button(Localized.deleteFolderPlaylistsConfirm, role: .destructive) {
                        deleteExistingFolderPlaylists()
                    }
                    Button(Localized.keepFolderPlaylists, role: .cancel) {}
                } message: {
                    Text(Localized.deleteFolderPlaylistsMessage)
                }

                Section(Localized.playerControls) {
                    Toggle(Localized.showLyricsButton, isOn: $deleteSettings.showLyricsButton)
                        .onChange(of: deleteSettings.showLyricsButton) { _, _ in
                            deleteSettings.save()
                        }

                    Toggle(Localized.showSleepTimerButton, isOn: $deleteSettings.showSleepTimerButton)
                        .onChange(of: deleteSettings.showSleepTimerButton) { _, _ in
                            deleteSettings.save()
                        }

                    Toggle(Localized.queueFullListFromSearch, isOn: $deleteSettings.queueFullListFromSearch)
                        .onChange(of: deleteSettings.queueFullListFromSearch) { _, _ in
                            deleteSettings.save()
                        }

                    Text(Localized.queueFullListFromSearchDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    ForEach($deleteSettings.homeSections) { $section in
                        HStack {
                            Image(systemName: section.id.icon)
                                .foregroundColor(.secondary)
                                .frame(width: 24)

                            Toggle(section.id.displayName, isOn: $section.isVisible)
                                .onChange(of: section.isVisible) { _, _ in
                                    deleteSettings.save()
                                }
                        }
                    }
                    .onMove { source, destination in
                        deleteSettings.homeSections.move(fromOffsets: source, toOffset: destination)
                        deleteSettings.save()
                    }

                    Text(Localized.chooseVisibleSections)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    HStack {
                        Text(Localized.homeSections)
                        Spacer()
                        EditButton()
                            .font(.caption)
                    }
                }

                Section(Localized.information) {
                    HStack {
                        Text(Localized.version)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? Localized.unknown)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text(Localized.appName)
                        Spacer()
                        Text(Localized.cosmosMusicPlayer)
                            .foregroundColor(.secondary)
                    }
                    
                    // This app's source (GPLv3 requires it to be available)
                    // and the project it is based on.
                    Link(destination: URL(string: "https://github.com/ericchiu-ca/Cadence")!) {
                        aboutLinkRow(Localized.githubRepository)
                    }
                    Link(destination: URL(string: "https://github.com/clquwu/Cosmos-Music-Player")!) {
                        aboutLinkRow(Localized.basedOnCosmos)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 100)
            }
            .navigationTitle(Localized.settings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.done) {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
