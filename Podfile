platform :osx, '12.0'

target 'AIMacro' do
  use_frameworks!

  pod 'RxSwift', '6.2.0'
  pod 'RxCocoa', '6.2.0'
  pod 'Socket.IO-Client-Swift', '~> 16.1.0'
  # Type-safe Swift wrapper around SQLite. Used by ActionStore for per-action
  # state (replaces UserDefaults for AutoAction.save/restore).
  pod 'SQLite.swift', '~> 0.15'
end

# Force every pod target to match the host's macOS 12 deployment target.
# Without this, CocoaPods leaves some pods (RxSwift) at the legacy 10.9
# default, which fails to compile against APIs like `Date`/`Data`.
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '12.0'
    end
  end
end
