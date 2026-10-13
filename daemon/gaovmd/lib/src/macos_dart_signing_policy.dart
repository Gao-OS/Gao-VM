/// User-approved on 2026-10-10 for compiled Dart daemon/CLI code only.
/// Keep hardened runtime and library validation; do not apply this to the VZ
/// driver or inherit other entitlements from the SDK's signing policy.
const macOsDartRuntimeEntitlements = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
  <true/>
</dict>
</plist>
''';
