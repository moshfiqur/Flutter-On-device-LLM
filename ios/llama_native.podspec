Pod::Spec.new do |s|
  s.name             = 'llama_native'
  s.version          = '0.0.1'
  s.summary          = 'Native Llama.cpp wrapper for Flutter'
  s.description      = 'Integrates llama.cpp with Flutter via FFI'
  s.homepage         = 'https://github.com/example/flutter-ai'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Your Name' => 'you@example.com' }
  s.source           = { :path => '.' }

  s.ios.deployment_target = '13.0'

  # Core wrapper files and llama.cpp sources
  # We use recursive globbing for ggml-cpu to catch all architecture-specific files
  s.source_files = [
    '../native/llama_cpp/llama_wrapper.{h,cpp}',
    '../native/llama_cpp/src/src/*.{h,cpp}',
    '../native/llama_cpp/src/src/models/*.{h,cpp}',
    '../native/llama_cpp/src/ggml/src/*.{h,c,cpp}',
    '../native/llama_cpp/src/ggml/src/ggml-cpu/**/*.{h,c,cpp}',
    '../native/llama_cpp/src/include/*.h',
    '../native/llama_cpp/src/ggml/include/*.h'
  ]

  # Make sure the wrapper header is available
  s.public_header_files = '../native/llama_cpp/llama_wrapper.h'
  
  s.pod_target_xcconfig = {
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'GCC_C_LANGUAGE_STANDARD' => 'c11',
    'HEADER_SEARCH_PATHS' => [
      '$(inherited)',
      '"${PODS_TARGET_SRCROOT}/../native/llama_cpp"',
      '"${PODS_TARGET_SRCROOT}/../native/llama_cpp/src/include"',
      '"${PODS_TARGET_SRCROOT}/../native/llama_cpp/src/ggml/include"',
      '"${PODS_TARGET_SRCROOT}/../native/llama_cpp/src/src"',
      '"${PODS_TARGET_SRCROOT}/../native/llama_cpp/src/ggml/src"',
      '"${PODS_TARGET_SRCROOT}/../native/llama_cpp/src/ggml/src/ggml-cpu"'
    ].join(' '),
    # Mandatory flags for llama.cpp to build and run on iOS/macOS
    'OTHER_CFLAGS' => [
      '$(inherited)',
      '-DGGML_USE_CPU',
      '-DGGML_USE_ACCELERATE',
      '-DGGML_CPU_ALL_VARIANTS', # Enable all CPU optimizations that Accelerate can provide
    ].join(' '),
    'OTHER_CPLUSPLUSFLAGS' => [
      '$(inherited)',
      '-DGGML_USE_CPU',
      '-DGGML_USE_ACCELERATE',
      '-DGGML_CPU_ALL_VARIANTS',
    ].join(' ')
  }

  s.frameworks = 'Accelerate', 'Foundation', 'CoreGraphics'
  s.library = 'c++'
end
