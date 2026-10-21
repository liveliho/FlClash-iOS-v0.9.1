import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (input.userDefines['build_assets'] == false) {
      stdout.writeln('Skipping the Rust build: user-define build_assets=false');
      return;
    }
    await FlutterRustBridgeNativeAssetsBuilder(
      cratePath: 'rust',
      extraCargoEnvironmentVariables: _bindgenEnvironment(input),
    ).run(input: input, output: output);
  });
}

// rquickjs runs bindgen on Android, which must load the NDK's libclang; Linux
// NDKs before r26 keep it under lib64, later ones and every macOS NDK under lib.
Map<String, String> _bindgenEnvironment(BuildInput input) {
  if (!input.config.buildCodeAssets) {
    return const {};
  }
  if (input.config.code.targetOS == OS.iOS) {
    return _iosBuildEnvironment(input.config.code);
  }
  if (input.config.code.targetOS != OS.android) {
    return const {};
  }
  final compiler = input.config.code.cCompiler?.compiler;
  if (compiler == null) {
    return const {};
  }
  final llvmRoot = File.fromUri(compiler).parent.parent;
  for (final name in const ['lib', 'lib64']) {
    final directory = Directory(
      '${llvmRoot.path}${Platform.pathSeparator}$name',
    );
    if (directory.existsSync() && directory.listSync().any(_isLibclang)) {
      return {'LIBCLANG_PATH': directory.path};
    }
  }
  throw StateError(
    'No libclang under ${llvmRoot.path} (lib or lib64); the NDK Flutter '
    'passed cannot run bindgen for rquickjs',
  );
}

bool _isLibclang(FileSystemEntity entity) {
  return entity.path.split(Platform.pathSeparator).last.startsWith('libclang.');
}

// On iOS bindgen runs on Xcode's own libclang, which finds no headers for a
// cross target unless it is handed the SDK. Without a deployment target cc
// builds QuickJS for the SDK's own version while rustc links for iOS 10,
// whose libSystem lacks the ___chkstk_darwin those objects call.
Map<String, String> _iosBuildEnvironment(CodeConfig code) {
  final sdk = code.iOS.targetSdk;
  final result = Process.runSync('xcrun', [
    '--sdk',
    sdk.type,
    '--show-sdk-path',
  ]);
  if (result.exitCode != 0) {
    throw StateError('xcrun found no ${sdk.type} SDK: ${result.stderr}');
  }
  final arch = code.targetArchitecture == Architecture.x64
      ? 'x86_64'
      : 'aarch64';
  final simulator = sdk == IOSSdk.iPhoneSimulator && arch == 'aarch64'
      ? '_sim'
      : '';
  return {
    'BINDGEN_EXTRA_CLANG_ARGS_${arch}_apple_ios$simulator':
        '-isysroot ${(result.stdout as String).trim()}',
    'IPHONEOS_DEPLOYMENT_TARGET': '${code.iOS.targetVersion}.0',
  };
}
