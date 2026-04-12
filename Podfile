platform :ios, '18.6'

target 'SenseHat_dashboard' do
  use_frameworks!

  pod 'MobileVLCKit'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '18.6'
    end
  end
end
