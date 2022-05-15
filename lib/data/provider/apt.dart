import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:logging/logging.dart';
import 'package:toolbox/core/extension/stringx.dart';
import 'package:toolbox/core/extension/uint8list.dart';
import 'package:toolbox/core/provider_base.dart';
import 'package:toolbox/data/model/apt/upgrade_pkg_info.dart';
import 'package:toolbox/data/model/distribution.dart';

typedef PwdRequestFunc = Future<String> Function(
    bool lastTimes, String? userName);
final pwdRequestWithUserReg = RegExp(r'\[sudo\] password for (.+):');

class AptProvider extends BusyProvider {
  final logger = Logger('AptProvider');

  SSHClient? client;
  Distribution? dist;
  Function()? onUpgrade;
  Function()? onUpdate;
  PwdRequestFunc? onPasswordRequest;

  String? whoami;
  List<UpgradePkgInfo>? upgradeable;
  String? error;
  String? upgradeLog;
  String? updateLog;
  String lastLog = '';
  int triedTimes = 0;

  AptProvider();

  Future<void> init(SSHClient client, Distribution dist, Function() onUpgrade,
      Function() onUpdate, PwdRequestFunc onPasswordRequest) async {
    this.client = client;
    this.dist = dist;
    this.onUpgrade = onUpgrade;
    this.onPasswordRequest = onPasswordRequest;
    whoami = (await client.run('whoami').string).trim();
  }

  bool get isSU => whoami == 'root';

  void clear() {
    client = null;
    dist = null;
    upgradeable = null;
    error = null;
    upgradeLog = null;
    updateLog = whoami = null;
    onUpgrade = null;
    onUpdate = null;
    onPasswordRequest = null;
    triedTimes = 0;
  }

  Future<void> refreshInstalled() async {
    if (client == null) {
      error = 'No client';
      return;
    }

    final result = await _update();
    try {
      getUpgradeableList(result);
    } catch (e) {
      error = '[Server Raw]:\n$result\n[App Error]:\n$e';
    } finally {
      notifyListeners();
    }
  }

  void getUpgradeableList(String? raw) {
    if (raw == null) return;
    var list = raw.split('\n');
    switch (dist) {
      case Distribution.rehl:
        list = list.sublist(2);
        list.removeWhere((element) => element.isEmpty);
        final endLine = list.lastIndexWhere(
            (element) => element.contains('Obsoleting Packages'));
        list = list.sublist(0, endLine);
        break;
      default:
        list = list.sublist(4);
        list.removeWhere((element) => element.isEmpty);
    }
    upgradeable = list.map((e) => UpgradePkgInfo(e, dist!)).toList();
  }

  Future<String> _update() async {
    switch (dist) {
      case Distribution.rehl:
        return await client?.run(_wrap('yum check-update')).string ?? '';
      default:
        final session = await client!.execute(_wrap('apt update'));
        session.stderr.listen((event) => _onPwd(event, session.stdin));
        session.stdout.listen((event) {
          updateLog = (updateLog ?? '') + event.string;
          notifyListeners();
          onUpdate ?? () {}();
        });
        await session.done;
        return await client
                ?.run('apt list --upgradeable'.withLangExport)
                .string ??
            '';
    }
  }

  Future<void> upgrade() async {
    if (client == null) {
      error = 'No client';
      return;
    }

    final upgradeCmd = () {
      switch (dist) {
        case Distribution.rehl:
          return 'yum upgrade -y';
        default:
          return 'apt upgrade -y';
      }
    }();

    final session = await client!.execute(_wrap(upgradeCmd));
    session.stderr.listen((e) => _onPwd(e, session.stdin));

    session.stdout.listen((data) async {
      final log = data.string;
      if (lastLog == log.trim()) return;
      upgradeLog = (upgradeLog ?? '') + log;
      lastLog = log.trim();
      notifyListeners();
      onUpgrade!();
    });

    upgradeLog = null;
    await session.done;
    refreshInstalled();
  }

  Future<void> _onPwd(Uint8List e, StreamSink<Uint8List> stdin) async {
    final event = e.string;
    if (event.contains('[sudo] password for ')) {
      final user = pwdRequestWithUserReg.firstMatch(event)?.group(1);
      logger.info('sudo password request for $user');
      triedTimes++;
      final pwd =
          await (onPasswordRequest ?? (_) async => '')(triedTimes == 3, user);
      if (pwd.isEmpty) {
        logger.info('sudo password request cancelled');
        return;
      }
      stdin.add(Uint8List.fromList(utf8.encode('$pwd\n')));
    }
  }

  String _wrap(String cmd) =>
      'export LANG=en_US.utf-8 && ${isSU ? "" : "sudo -S "}$cmd';
}
