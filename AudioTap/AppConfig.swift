import Foundation

struct AppConfig {
    static let uploadEndpoint: URL = {
        #if DEBUG
        return URL(string: "http://localhost:4000/api/audio")!
        #else
        return URL(string: "https://pair.jwbaldwin.com/api/audio")!
        #endif
    }()
}
