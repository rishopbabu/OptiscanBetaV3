Pod::Spec.new do |spec|

  spec.name         = "OptiScanBarcodeReader"

  spec.version      = "0.1.0"

  spec.summary      = "A short description of OptiScanBarcodeReader."

  spec.homepage     = "https://github.com/rishopbabu/OptiscanBetaV3"

  spec.license      = "MIT"

  spec.author             = { "Rishop Babu" => "rishop.babu@optisolbusiness.com" }

  spec.platform     = :ios, "9.0"

  spec.swift_version = "5.0"

  spec.vendored_frameworks = 'OptiScanBarcodeReader.framework'

  spec.static_framework = true

  spec.source       = { :git => "https://github.com/rishopbabu/OptiscanBetaV3.git", :tag => "0.1.0" }

  # spec.source_files  = "OptiScanBarcodeReader/**/*.{h,m}"

  spec.requires_arc = true

  spec.pod_target_xcconfig = { "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => 'arm64' }
  
  spec.user_target_xcconfig = { "EXCLUDED_ARCHS[sdk=iphonesimulator*]" => 'arm64' }

end
