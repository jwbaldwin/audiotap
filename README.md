# AudioTap

A macOS application for capturing system audio output to a file.

## Features

- Records system audio output to a WAV file using modern Core Audio APIs
- Captures audio from all applications on your system
- Simple menu bar interface
- Saves timestamped recordings to the Documents folder

## Requirements

- macOS 14.2+ (required for CATapDescription and AudioHardwareCreateProcessTap)
- Xcode 15+
- Swift 5.9+

## Setup

1. Create a new Swift project in Xcode
2. Add the AudioTap.swift and AudioManager.swift files to your project
3. Configure the Info.plist entries (already included in this repo)
4. Set the deployment target to macOS 14.2 or later
5. Configure the necessary entitlements:
   - com.apple.security.device.audio-input
   - com.apple.security.device.microphone
   - com.apple.security.audio-capture
6. Build and run the application

## Usage

1. Click the record icon in the menu bar
2. Select "Start Recording" to begin capturing system audio
3. Select "Stop Recording" when done
4. Find the recorded audio file in your Documents folder

## Technical Notes

This application uses the new CATapDescription and AudioHardwareCreateProcessTap APIs introduced in macOS 14.2 to capture system audio from all applications. These are public APIs specifically designed for this purpose.

The implementation:
1. Obtains the system's default output device
2. Creates a CATapDescription targeting that device
3. Uses AudioHardwareCreateProcessTap to establish a tap on the audio stream
4. Collects audio buffers and writes them to a WAV file
5. Properly cleans up the tap when recording stops

This method allows capturing audio from any application on the system without needing to create aggregate audio devices or use third-party solutions.