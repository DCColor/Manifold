//
//  PrivateURLSession.swift
//  Manifold — the one URLSession the app's own requests go through, and the launch-time removal of
//  the disk cache the shared session used to write. Privacy stage P1 (docs/PRIVACY_AUDIT.md).
//
//  ── WHY NOT `URLSession.shared` ─────────────────────────────────────────────────────────────────
//
//  `URLSession.shared` keeps a DISK cache (`~/Library/Caches/com.graviton.manifold/Cache.db`) and a
//  persistent cookie/HSTS store (`~/Library/HTTPStorages/com.graviton.manifold`). The audit found the
//  cache holding the licence server's /activate and /validate replies — which carry the licensee's
//  email — and the request URLs of WHEP sessions, whose paths carry stream keys. POSTs are not
//  supposed to be cached; these were, so "it should not cache that" was not a guarantee worth having.
//
//  So: an EPHEMERAL session, with no URL cache at all. Ephemeral also means cookies and credentials
//  live in memory for the life of the process and are never written; a WHEP server that sets a
//  cookie between its POST and its DELETE still gets it back, because both go through this session.
//
//  AVPlayer does not use this session: HLS playback goes through AVFoundation's own loader. That
//  loader does open the process's DEFAULT URL cache, which created an empty `Cache.db` during HLS
//  (measured, P1), so `makeDefaultCacheMemoryOnly` gives the process a memory-only default cache.
//  Only the HLS client's own playlist GET comes through this session.
//

import Foundation

enum PrivateURLSession {

    /// For the licence server, the update check, WHEP signalling and the HLS playlist read.
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCredentialStorage = nil
        return URLSession(configuration: config)
    }()

    /// Replaces the process's default URL cache with a memory-only one (decided 2026-10-19, P1).
    ///
    /// ⚠️ THIS IS FOR AVFoundation, NOT FOR US. Our own requests already bypass any cache. But HLS
    /// playback's loader runs in-process and opens the DEFAULT cache: measured, 40 s of HLS created
    /// an empty `Cache.db` in `~/Library/Caches/com.graviton.manifold`. With no disk capacity the
    /// file is never created. Playback is unaffected — AVPlayer stored nothing in it anyway.
    /// Called at launch, after `removeLegacyDiskCache` and before anything can make a request.
    static func makeDefaultCacheMemoryOnly() {
        URLCache.shared = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0, directory: nil)
    }

    /// Removes the disk cache `URLSession.shared` left behind in earlier versions. Called once per
    /// launch, before any request. Idempotent: on a clean install there is nothing to remove and
    /// nothing is logged.
    ///
    /// ⚠️ ONLY OUR OWN CACHE FOLDER, AND ONLY THE URL-CACHE FILES IN IT: `Cache.db` with its SQLite
    /// companions and the `fsCachedData` folder of large bodies. Anything else in the folder is
    /// left alone. `~/Library/HTTPStorages/com.graviton.manifold` is not touched (P1 does not
    /// include it); the ephemeral session simply stops adding to it.
    static func removeLegacyDiskCache() {
        let fm = FileManager.default
        guard let bundleID = Bundle.main.bundleIdentifier,
              let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let folder = caches.appendingPathComponent(bundleID, isDirectory: true)
        var removed: [String] = []
        for name in ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData"] {
            let url = folder.appendingPathComponent(name)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                try fm.removeItem(at: url)
                removed.append(name)
            } catch {
                NSLog("[PRIVACY] ⚠️ could not remove the old network cache file %@: %@",
                      name, error.localizedDescription)
            }
        }
        if !removed.isEmpty {
            NSLog("[PRIVACY] removed the old network disk cache (%@)", removed.joined(separator: ", "))
        }
    }
}
