import SwiftUI

/// Your tasks, in the Starlight window: the same list as the corner of the screen, with room to
/// breathe. A big friendly heading, a place to add, your tasks. Click a task's words to change
/// them. The switch at the top turns tasks on or off everywhere.
struct TasksPage: View {
    @ObservedObject var store: TaskStore
    @ObservedObject private var settings = AppSettings.shared
    @State private var confirmClear = false

    var body: some View {
        Page(title: "Tasks") {
            HStack(spacing: 14) {
                if settings.tasksEnabled, store.open.count > 1 {
                    GlassButton(title: "Clear all", destructive: true) { confirmClear = true }
                        .confirmationDialog("Clear all \(store.open.count) tasks?", isPresented: $confirmClear) {
                            Button("Clear all", role: .destructive) { store.clearAll() }
                        }
                        .transition(.opacity)
                }
                Switch(isOn: $settings.tasksEnabled)
                    .help(settings.tasksEnabled ? "Turn tasks off" : "Turn tasks on")
            }
        } content: {
            if settings.tasksEnabled { list.transition(.opacity) } else { off.transition(.opacity) }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: store.items)
        .animation(.easeOut(duration: 0.2), value: settings.tasksEnabled)
    }

    @ViewBuilder private var list: some View {
        HStack {
            Text(TaskStore.headline(store.open.filter { $0.kind == .task }.count)).font(.system(size: 26, weight: .semibold))
                .contentTransition(.numericText())
            Spacer()
            if store.undo != nil {
                UndoChip { store.undoLast() }.transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(.top, -6)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: store.undo)

        VStack(alignment: .leading, spacing: 2) {
            AddTaskField(store: store, fontSize: 15.5)
            ForEach(store.open) { item in
                TaskRow(item: item, store: store, fontSize: 15.5)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .leading))))
            }
        }
        .glassCard(padding: 8)

        Rows {
            Row(title: "Show in the corner of the screen", last: true) { Switch(isOn: $settings.showTasksCorner) }
        }
    }

    /// Off: nothing but what it means and how to turn it back on.
    private var off: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tasks are off.").font(.system(size: 26, weight: .semibold))
            Text("Nothing is written down from your meetings, the corner list is hidden, and Starlight won't add tasks when you ask. Your tasks are kept for when you turn them back on.")
                .font(.system(size: 14)).opacity(0.5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, -6)
    }
}
