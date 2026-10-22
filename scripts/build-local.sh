#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Local ad-hoc builds have no development Team ID. Match Debug's runtime
# behavior so the embedded MediaRemoteAdapter can load without a team identity.
# This affects only this app build, not any macOS security settings.
xcodebuild -project AgentNotch.xcodeproj -scheme AgentNotch \
  -configuration Release -derivedDataPath build/DerivedData \
  -disableAutomaticPackageResolution build \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO
mkdir -p dist
ditto build/DerivedData/Build/Products/Release/AgentNotch.app dist/AgentNotch.app
codesign --verify --deep --strict dist/AgentNotch.app
ditto -c -k --sequesterRsrc --keepParent dist/AgentNotch.app dist/AgentNotch.zip
