# Rack Control

A native iOS app for monitoring and using a home server rack. It shows node status and activity, browses and previews files, and includes notes, spending and goal tracking, all behind a biometric lock.

Built with SwiftUI, WebKit, QuickLook and Swift Charts. The project has no automated tests.

**This is a portfolio project.** The app connects to a personal server that isn't in this repo, so it won't show live data without one.

## Build

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open RackControl.xcodeproj
```

Set your own Apple team under Signing & Capabilities to run it on a device.

## License

[MIT](LICENSE)
