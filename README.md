# AudioTap

A macOS application for capturing system audio output to a file.

## Features

- Records system audio output to a WAV file
- Simple menu bar interface
- Uses Core Audio for high-quality audio capture
- Saves timestamped recordings to the Documents folder

## Requirements

- macOS 14.2+ (for optimal performance)
- Xcode 15+
- Swift 5.9+

## Setup

1. Create a new Swift project in Xcode
2. Add the AudioTap.swift and AudioManager.swift files to your project
3. Configure the Info.plist entries (already included in this repo)
4. Build and run the application

## Usage

1. Click the record icon in the menu bar
2. Select "Start Recording" to begin capturing system audio
3. Select "Stop Recording" when done
4. Find the recorded audio file in your Documents folder

## Technical Notes

This application uses AVAudioEngine for audio capture. While the ideal approach would be to use CATapDescription and AudioHardwareServiceCreateProcessTap for system audio capture, this prototype falls back to using AVAudioEngine's mixer node tap.

The current implementation installs a tap on the main mixer node of an AVAudioEngine instance. This captures any audio being played back by this application, not from other applications.

For capturing audio from other applications, a full implementation would need to use AudioHardwareServiceCreateProcessTap or an aggregate audio device approach, which would require additional code complexity.