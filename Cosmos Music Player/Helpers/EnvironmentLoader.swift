//
//  EnvironmentLoader.swift
//  Cosmos Music Player
//
//  Environment variable loader for API keys and configuration
//

import Foundation

class EnvironmentLoader: @unchecked Sendable {
    static let shared = EnvironmentLoader()
    
    private var environmentVariables: [String: String] = [:]
    
    private init() {
        loadEnvironmentVariables()
    }
    
    private func loadEnvironmentVariables() {
        // First, try to load from .env file in the app bundle
        if let envPath = Bundle.main.path(forResource: ".env", ofType: nil) {
            loadFromFile(path: envPath)
        }
        
        // Also try loading from .env in the project root (for development)
        let projectRoot = Bundle.main.bundlePath
        let rootEnvPath = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent("../../../.env")
            .standardized
            .path
        
        if FileManager.default.fileExists(atPath: rootEnvPath) {
            loadFromFile(path: rootEnvPath)
        }
        
        // Finally, load from actual environment variables (overrides file values)
        loadFromSystemEnvironment()
    }
    
    private func loadFromFile(path: String) {
        guard let content = try? String(contentsOfFile: path) else {
            print("📄 EnvironmentLoader: Could not read .env file at \(path)")
            return
        }
        
        let lines = content.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip empty lines and comments
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            
            // Parse KEY=VALUE format
            let components = trimmed.components(separatedBy: "=")
            if components.count >= 2 {
                let key = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = components.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Remove quotes if present
                let cleanValue = value.hasPrefix("\"") && value.hasSuffix("\"") ? 
                    String(value.dropFirst().dropLast()) : value
                
                environmentVariables[key] = cleanValue
                print("🔑 EnvironmentLoader: Loaded \(key) from .env file")
            }
        }
    }
    
    private func loadFromSystemEnvironment() {
        // Load system environment variables (these override .env file values)
        for (key, value) in ProcessInfo.processInfo.environment {
            if key.hasPrefix("SPOTIFY_") || key.hasPrefix("DISCOGS_") {
                environmentVariables[key] = value
                print("🌍 EnvironmentLoader: Loaded \(key) from system environment")
            }
        }
    }
    
    /// Get an environment variable value
    func getValue(for key: String) -> String? {
        return environmentVariables[key]
    }
    
    /// Get an environment variable value with a fallback
    func getValue(for key: String, fallback: String) -> String {
        return environmentVariables[key] ?? fallback
    }
    
    /// Check if a key exists
    func hasKey(_ key: String) -> Bool {
        return environmentVariables[key] != nil
    }
    
    /// Get all loaded keys (for debugging)
    func getAllKeys() -> [String] {
        return Array(environmentVariables.keys).sorted()
    }
}

// MARK: - API Key Helpers

// The keys are optional: without them the online artist info is skipped. A
// missing key used to be a fatalError, which crashed every build made without
// a .env file as soon as post-index maintenance touched the Discogs service.
extension EnvironmentLoader {
    private func optionalKey(_ key: String) -> String? {
        guard let value = getValue(for: key), !value.isEmpty else { return nil }
        return value
    }

    // Spotify API Keys
    var spotifyClientId: String? { optionalKey("SPOTIFY_CLIENT_ID") }
    var spotifyClientSecret: String? { optionalKey("SPOTIFY_CLIENT_SECRET") }

    // Discogs API Keys
    var discogsConsumerKey: String? { optionalKey("DISCOGS_CONSUMER_KEY") }
    var discogsConsumerSecret: String? { optionalKey("DISCOGS_CONSUMER_SECRET") }
}
