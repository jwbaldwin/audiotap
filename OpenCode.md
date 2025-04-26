# OpenCode.md

## Build & Run Commands
- Build: `xcodebuild -project AudioTap.xcodeproj -scheme AudioTap build`
- Run: `open AudioTap.xcodeproj` then Command+R in Xcode
- Clean: `xcodebuild -project AudioTap.xcodeproj clean`
- Requirements: macOS 14.2+, Xcode 15+, Swift 5.9+

## Code Style Guidelines
- **Formatting**: 4-space indentation, ~100 character line limit
- **Imports**: Group frameworks (Foundation/SwiftUI first, then CoreAudio/AVFoundation/AudioToolbox)
- **Types**: Use `@Observable` for state objects, `@MainActor` for UI updates
- **Naming**: 
  - Types: UpperCamelCase (AudioManager, ProcessTap)
  - Variables/Functions: lowerCamelCase, descriptive
  - Boolean properties: Use "is" prefix (isRecording)
- **Error Handling**: Swift try/catch with clear errors, guard for early returns
- **Memory Management**: Clean up Core Audio resources in deinit/invalidate methods
- **Logging**: Use OSLog with appropriate privacy levels
- **Architecture**: Core Audio integration uses Swift wrappers around C APIs

## Technical Notes
- Audio processing uses CATapDescription and AudioHardwareCreateProcessTap APIs
- Always verify changes work with Core Audio before committing
- Handle resource cleanup properly to avoid memory leaks