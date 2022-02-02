#!/usr/bin/env dart
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

const appName = 'ServerBox';

Future<int> getGitCommitCount() async {
  final result = await Process.run('git', ['log', '--oneline']);
  return (result.stdout as String)
      .split('\n')
      .where((line) => line.isNotEmpty)
      .length;
}

Future<void> writeStaicConfigFile(
    Map<String, dynamic> data, String className, String path) async {
  final buffer = StringBuffer();
  buffer.writeln('// This file is generated by ./make.dart');
  buffer.writeln('');
  buffer.writeln('class $className {');
  for (var entry in data.entries) {
    final type = entry.value.runtimeType;
    final value = json.encode(entry.value);
    buffer.writeln('  static const $type ${entry.key} = $value;');
  }
  buffer.writeln('}');
  await File(path).writeAsString(buffer.toString());
}

Future<int> getGitModificationCount() async {
  final result =
      await Process.run('git', ['ls-files', '-mo', '--exclude-standard']);
  return (result.stdout as String)
      .split('\n')
      .where((line) => line.isNotEmpty)
      .length;
}

Future<String> getFlutterVersion() async {
  final result = await Process.run('flutter', ['--version'], runInShell: true);
  return (result.stdout as String);
}

Future<Map<String, dynamic>> getBuildData() async {
  final data = {
    'name': appName,
    'build': await getGitCommitCount(),
    'engine': await getFlutterVersion(),
    'buildAt': DateTime.now().toString(),
    'modifications': await getGitModificationCount(),
  };
  return data;
}

String jsonEncodeWithIndent(Map<String, dynamic> json) {
  const encoder = JsonEncoder.withIndent('  ');
  return encoder.convert(json);
}

Future<void> updateBuildData() async {
  print('Updating BuildData...');
  final data = await getBuildData();
  print(jsonEncodeWithIndent(data));
  const path = 'lib/data/res/build_data.dart';
  await writeStaicConfigFile(data, 'BuildData', path);
}

void dartFormat() {
  final result = Process.runSync('dart', ['format', './*.dart']);
  print(result.stdout);
  if (result.exitCode != 0) {
    print(result.stderr);
    exit(1);
  }
}

void flutterRun(String? mode) {
  Process.start('flutter', ['run', mode == null ? '' : '--$mode'],
      mode: ProcessStartMode.inheritStdio, runInShell: true);
}

Future<void> flutterBuild(String source, String target, bool isAndroid) async {
  final startTime = DateTime.now();
  final build = await getGitCommitCount();

  final args = [
    'build',
    isAndroid ? 'apk' : 'ipa',
    '--target-platform=android-arm64',
    '--build-number=$build',
    '--build-name=1.0.$build'
  ];
  if (!isAndroid) args.removeAt(2);
  print('Building with args: ${args.join(' ')}');
  final buildResult = await Process.run('flutter', args, runInShell: true);
  final exitCode = buildResult.exitCode;

  if (exitCode == 0) {
    target = target.replaceFirst('build', build.toString());
    print('Copying from $source to $target');
    await File(source).copy(target);
    print('Done.');
  } else {
    print(buildResult.stderr.toString());
    print('\nBuild failed with exit code $exitCode');
    exit(exitCode);
  }
  final endTime = DateTime.now();
  print('Spent time: ${endTime.difference(startTime).toString()}');
}

Future<void> flutterBuildIOS() async {
  await flutterBuild('./build/ios/iphoneos/ToastTiku.app',
      './release/${appName}_build.app', false);
}

Future<void> flutterBuildAndroid() async {
  await flutterBuild('./build/app/outputs/flutter-apk/app-release.apk',
      './release/${appName}_build_Arm64.apk', true);
}

void main(List<String> args) async {
  if (args.isEmpty) {
    print('No action. Exit.');
    return;
  }

  final command = args[0];

  switch (command) {
    case 'run':
      return flutterRun(args.length == 2 ? args[1] : null);
    case 'build':
      if (args.length > 1) {
        await updateBuildData();
        dartFormat();
        if (args[1] == 'android' || args[1] == 'harmony') {
          return flutterBuildAndroid();
        } else if (args[1] == 'ios') {
          return flutterBuildIOS();
        }
        print('unkonwn build arg: ${args[1]}');
      }
      return;
    default:
      print('Unsupported command: $command');
      return;
  }
}
