import Foundation
import SwiftUI

enum ChatRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

struct ChatMessage: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let role: ChatRole
    var content: String
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: ChatRole,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

struct AgentSession: Identifiable, Codable, Sendable, Equatable {
    static let untitledTitle = "Yangi sessiya"

    let id: UUID
    var openCodeSessionID: String?
    var title: String
    var projectPath: String?
    var modelName: String
    var messages: [ChatMessage]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        openCodeSessionID: String? = nil,
        title: String = AgentSession.untitledTitle,
        projectPath: String? = nil,
        modelName: String,
        messages: [ChatMessage] = [AgentSession.welcomeMessage()],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.openCodeSessionID = openCodeSessionID
        self.title = title
        self.projectPath = projectPath
        self.modelName = modelName
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static func welcomeMessage() -> ChatMessage {
        ChatMessage(
            role: .system,
            content: "Yangi lokal sessiya tayyor. Loyiha tanlang va vazifani yozing."
        )
    }
}

struct AgentActivity: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case preparing
        case tool(name: String, failed: Bool)
    }

    let kind: Kind

    var title: String {
        switch kind {
        case .preparing:
            "Javob tayyorlanmoqda"
        case .tool(let name, false):
            "\(name) bajarildi"
        case .tool(let name, true):
            "\(name) xato bilan tugadi"
        }
    }

    var symbol: String {
        switch kind {
        case .preparing:
            "sparkles"
        case .tool(_, false):
            "wrench.and.screwdriver.fill"
        case .tool(_, true):
            "exclamationmark.triangle.fill"
        }
    }
}

enum ComponentState: Equatable, Sendable {
    case unknown
    case checking
    case ready(String)
    case missing(String)
    case failed(String)

    var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    var title: String {
        switch self {
        case .unknown:
            "Tekshirilmagan"
        case .checking:
            "Tekshirilmoqda"
        case .ready(let detail):
            detail
        case .missing(let detail), .failed(let detail):
            detail
        }
    }

    var symbol: String {
        switch self {
        case .unknown:
            "circle.dashed"
        case .checking:
            "arrow.trianglehead.2.clockwise.rotate.90"
        case .ready:
            "checkmark.circle.fill"
        case .missing:
            "minus.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .unknown:
            .secondary
        case .checking:
            .blue
        case .ready:
            .green
        case .missing:
            .orange
        case .failed:
            .red
        }
    }
}

enum QuickAction: String, CaseIterable, Identifiable, Sendable {
    case analyze
    case build
    case test
    case run

    var id: String { rawValue }

    var title: String {
        switch self {
        case .analyze:
            "Loyihani tahlil qilish"
        case .build:
            "Build"
        case .test:
            "Test"
        case .run:
            "Simulator’da ochish"
        }
    }

    var symbol: String {
        switch self {
        case .analyze:
            "waveform.path.ecg.rectangle"
        case .build:
            "hammer.fill"
        case .test:
            "checkmark.seal.fill"
        case .run:
            "play.rectangle.fill"
        }
    }

    var prompt: String {
        switch self {
        case .analyze:
            """
            Loyihani o‘zgartirmasdan tahlil qil. AGENTS.md ko‘rsatmalariga amal qil. \
            Arxitektura, targetlar, scheme, deployment target, testlar va asosiy xavflarni aniqlagin. \
            XcodeBuildMCP CLI mavjudligini tekshir va natijani o‘zbek tilida qisqa yoz.
            """
        case .build:
            """
            Manba kodini o‘zgartirma. AGENTS.md ko‘rsatmalariga amal qil. \
            XcodeBuildMCP CLI orqali haqiqiy workspace/project va scheme’ni aniqlab, \
            bitta mos iPhone Simulator uchun loyihani build qil. Xatolar bo‘lsa sababini aniq yoz.
            """
        case .test:
            """
            Manba kodini o‘zgartirma. AGENTS.md ko‘rsatmalariga amal qil. \
            XcodeBuildMCP CLI orqali mavjud unit/integration testlarni ishga tushir. \
            O‘tgan, yiqilgan va mavjud bo‘lmagan testlarni aniq hisobot qil.
            """
        case .run:
            """
            Manba kodini o‘zgartirma. AGENTS.md ko‘rsatmalariga amal qil. \
            XcodeBuildMCP CLI orqali loyihani build qilib bitta mos iPhone Simulator’da ishga tushir. \
            Dastlabki runtime loglarni tekshir va crash yoki jiddiy xatolarni hisobot qil.
            """
        }
    }
}

enum AgentError: LocalizedError, Sendable {
    case processAlreadyRunning
    case executableLaunchFailed(String)
    case noProjectSelected
    case emptyTask
    case componentUnavailable(String)
    case processTerminationFailed
    case emptyAgentResponse
    case gitFileUnavailable

    var errorDescription: String? {
        switch self {
        case .processAlreadyRunning:
            "Boshqa vazifa hali bajarilmoqda. Avval uni to‘xtating."
        case .executableLaunchFailed(let detail):
            "Jarayonni ishga tushirib bo‘lmadi: \(detail)"
        case .noProjectSelected:
            "Avval iOS loyiha papkasini tanlang."
        case .emptyTask:
            "Vazifa matnini kiriting."
        case .componentUnavailable(let name):
            "\(name) topilmadi yoki ishlamayapti. O‘rnatish qo‘llanmasini bajaring."
        case .processTerminationFailed:
            "Jarayonni belgilangan vaqt ichida to‘xtatib bo‘lmadi."
        case .emptyAgentResponse:
            "OpenCode vazifani yakunladi, ammo JSON oqimida matnli javob bermadi. Sessiya OpenCode’da saqlangan bo‘lishi mumkin."
        case .gitFileUnavailable:
            "Tanlangan Git fayli endi mavjud emas yoki loyiha tashqarisida."
        }
    }
}
