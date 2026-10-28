import Foundation

/// Which Starlight this is. The open-source build (scripts/make-opensource.sh) has no accounts,
/// so no Clerk: it's dictation and Live mode with your own key or Ollama, and nothing else.
/// Meetings, tasks and memory are Starlight's, along with Pro.
enum Edition {
    #if canImport(ClerkKit)
    static let isOpenSource = false
    #else
    static let isOpenSource = true
    #endif

    /// Where "Upgrade to Pro" goes in the open-source build: Starlight, with Pro, on the website.
    static let proURL = URL(string: "https://starlightnotch.com/pricing")!

    /// Agent extensions and tools the open-source build leaves out (meetings, tasks, memory).
    static let hiddenExtensions: Set<String> = isOpenSource ? ["memory"] : []
    static let hiddenTools: Set<String> = isOpenSource ? ["search_meetings", "search_memory", "remember", "list_tasks", "open_transcript"] : []
}
