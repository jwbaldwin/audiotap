# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run
- Build: Open in Xcode and use Command+B
- Run: Use Command+R in Xcode
- Requirements: macOS 14.2+, Xcode 15+, Swift 5.9+

## Code Style Guidelines
- **Formatting**: 4-space indentation, ~100 character line limit
- **Imports**: Group related frameworks (Foundation/SwiftUI first, then CoreAudio/AVFoundation/AudioToolbox)
- **Comments**: Use MARK directives for sections, triple-slash (///) for documentation
- **Naming**: 
  - Classes/Structs: UpperCamelCase (AudioManager, TapStorage)
  - Variables/Functions: lowerCamelCase, descriptive names
  - Boolean properties: Use "is" prefix (isRecording, isSetup)
- **Error Handling**: Use Swift try/catch with clear NSError creation, guard statements for early returns
- **Memory Management**: Careful management of C API resources, proper cleanup in deinit/teardown methods
- **Swift Patterns**: Follow SwiftUI standards for property wrappers (@Published, @StateObject)

## Architecture
- Core Audio integration uses Swift wrappers around C APIs
- Audio processing and recording happens through AVAudioEngine
- UI follows standard SwiftUI patterns

Remember to verify changes work with Core Audio APIs before committing.