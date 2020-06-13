#  nes-emu-ios

An NES emulator written in Swift for iOS, ported from fogelman's NES emulator in Go: https://github.com/fogleman/nes

This emulator loads up the UIDocumentBrowserViewController for easy NES ROM (.nes) file browsing, and renders each PPU output frame to a UIView as a CGImage.  AVAudioEngine is used for sound, with buffers scheduled periodically from the APU output.  Everything is done using native iOS frameworks, with no third-party libraries.

## Current Features
- CPU
- PPU
- APU
- Con
- Touchscreen controls
- Builds successfully for Mac Catalyst (macOS 10.15 Catalina), but still needs some Mac-specific tweaks

## Compatibility 
At this time, only NROM games are supported, meaning mostly black box games from the early NES library, but more mappers will be added soon.

## Performance
For best performance, build for release mode.  Or, if you want better performance for debug builds, change these debug build settings under Swift Compiler - Code Generation:
- Disable Safety Checks = YES
- Exclusive Access to Memory = Compile Time Enforcement Only
- Optimization level = Optimize for Speed [-O]

Supported games should be able to run at full speed on recent iOS devices (such as iPhone 11 Pro) with these settings, or in Release mode, but I haven't done any testing yet on older devices.

## Near Future Plans
- Add support for more mappers, particularly the ones already supported in fogleman's NES emulator.
- Add setting to adjust audio sample rate, which may help reduce CPU usage.
- Performance improvements (look for low hanging fruit in areas of the app that are taking the longest)
- On-screen control improvements
- Support for built-in iOS game controller framework
- Save states
