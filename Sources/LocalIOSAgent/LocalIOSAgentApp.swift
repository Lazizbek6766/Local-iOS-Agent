import SwiftUI

@main
struct LocalIOSAgentApp: App {
    @State private var controller = AgentController()

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller)
                .frame(minWidth: 1_020, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Yangi sessiya") {
                    controller.createNewSession()
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(controller.isRunning)

                Button("Loyiha tanlash…") {
                    controller.chooseProject()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            CommandMenu("Agent") {
                Button("Holatni tekshirish") {
                    Task { await controller.refreshHealth() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Vazifani to‘xtatish") {
                    controller.stopCurrentTask()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!controller.isRunning || controller.isStopping)
            }
        }
    }
}
