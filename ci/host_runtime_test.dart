import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/scale.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:reaprime/src/plugins/plugin_scale.dart';
import 'package:reaprime/src/plugins/plugin_ble_matcher.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';

import '../helpers/plugin_ble_fixture.dart';
import 'plugin_test_helpers.dart';

const _service = '0000ff08-0000-1000-8000-00805f9b34fb';
const _batteryService = '0000180f-0000-1000-8000-00805f9b34fb';
const _infoService = '0000180a-0000-1000-8000-00805f9b34fb';
const _weight = '0000ef81-0000-1000-8000-00805f9b34fb';
const _button = '0000ef82-0000-1000-8000-00805f9b34fb';
const _battery = '00002a19-0000-1000-8000-00805f9b34fb';
const _firmware = '00002a26-0000-1000-8000-00805f9b34fb';

class _SkaleTransport extends PluginBleFixtureTransport {
  _SkaleTransport(super.physicalId)
    : super(services: const [_service, _batteryService, _infoService]);

  bool failNextWrite = false;

  void emitButton(int value) => subscribers[_button]?.call(Uint8List.fromList([value]));

  void emitWeight() => subscribers[_weight]?.call(
    Uint8List.fromList(const [0, 10, 0, 0]),
  );

  @override
  Future<void> write(
    String service,
    String characteristic,
    Uint8List data, {
    bool withResponse = true,
    Duration? timeout,
  }) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('simulated Skale write failure');
    }
    await super.write(
      service,
      characteristic,
      data,
      withResponse: withResponse,
      timeout: timeout,
    );
  }

  @override
  Future<void> subscribe(
    String service,
    String characteristic,
    void Function(Uint8List) callback,
  ) async {
    subscribers[characteristic] = callback;
    operations.add('subscribe:$service:$characteristic');
  }
}

class _DelayedStore extends FakeKeyValueStoreService {
  final delays = <String, Duration>{};

  @override
  Future<void> set({
    String namespace = 'default',
    required String key,
    required Object value,
  }) async {
    final delay = delays[key];
    if (delay != null) await Future<void>.delayed(delay);
    await super.set(namespace: namespace, key: key, value: value);
  }
}

Future<Map<String, dynamic>> _request(
  PluginManager manager,
  String pluginId,
  String requestId,
  Map<String, dynamic> payload,
) async {
  final response = manager.registerPendingHttp(pluginId, requestId);
  manager.dispatchEvent(pluginId, 'httpRequest', {
    'requestId': requestId,
    ...payload,
  });
  return response;
}

void main() {
  test('Skale discovery works without advertised service UUIDs and excludes DE1', () {
    final root = Platform.environment['SKALE_PLUGIN_ROOT'] ?? '.';
    final manifest = PluginManifest.fromJson(
      jsonDecode(File('$root/manifest.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    final matcher = manifest.drivers.single.ble!;
    for (final name in ['Skale2', 'skale', 'SKALE-2']) {
      expect(
        matcher.evaluate(
          name: name,
          nameComplete: true,
          serviceUuids: null,
          servicesComplete: false,
        ),
        PluginBleMatch.match,
        reason: 'A named Skale must not wait for an advertised UUID',
      );
    }
    expect(
      matcher.evaluate(
        name: 'DE1',
        nameComplete: true,
        serviceUuids: null,
        servicesComplete: false,
      ),
      PluginBleMatch.noMatch,
      reason: 'Skale discovery must not leave the DE1 pending',
    );
  });

  test('published Skale package connects through the real host BLE bridge', () async {
    final root = Platform.environment['SKALE_PLUGIN_ROOT'] ?? '.';
    final manifest = PluginManifest.fromJson(
      jsonDecode(File('$root/manifest.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      bleRegistry: PluginBleRegistry(activeBindingLimit: 4),
    );
    addTearDown(manager.dispose);
    await manager.loadPlugin(
      id: manifest.id,
      manifest: manifest,
      settings: const {},
      jsCode: File('$root/plugin.js').readAsStringSync(),
    );

    final transports = <_SkaleTransport>[];
    final evidence = BleAdvertisementEvidence(name: 'Skale2', nameComplete: true, serviceUuids: null, servicesComplete: false);
    expect(manager.bleService.registry.decide(evidence).kind, PluginBleOwnership.plugin);
    Future<Scale> candidate(String id) async => await manager.bleService
          .createCandidate(
            driver: manager.bleService.registry.decide(evidence).drivers.single,
            physicalId: id,
            evidence: evidence,
            admit: () => true,
            createTransport: () {
              final transport = _SkaleTransport(id);
              transport.queueRead(_battery, Uint8List.fromList(const [87]));
              transport.queueRead(_firmware, Uint8List.fromList(utf8.encode('R-$id')));
              transports.add(transport);
              return transport;
            },
          ) as Scale;

    final first = await candidate('AA:01');
    final second = await candidate('BB:02');
    final firstConnect = first.onConnect();
    final secondConnect = second.onConnect();
    (first as ScaleSnapshotHandoff).activateSnapshots();
    (second as ScaleSnapshotHandoff).activateSnapshots();
    final firstTransport = transports[0];
    final secondTransport = transports[1];
    final firstSnapshot = first.currentSnapshot.first;
    final secondSnapshot = second.currentSnapshot.first;
    final weightPump = Timer.periodic(const Duration(milliseconds: 100), (_) {
      firstTransport.emitWeight();
      secondTransport.emitWeight();
    });
    try {
      await Future.wait([firstConnect, secondConnect]);
    } finally {
      weightPump.cancel();
    }
    expect((await firstSnapshot).weight, 1);
    expect((await secondSnapshot).weight, 1);
    expect((first as PluginScale).currentDeviceInformation?.firmwareVersion, 'R-AA:01');
    expect((second as PluginScale).currentDeviceInformation?.firmwareVersion, 'R-BB:02');
    await first.tare();
    expect(firstTransport.writes.last.data, Uint8List.fromList(const [0x10]));
    expect(secondTransport.writes.where((write) => write.data.length == 1 && write.data.first == 0x10), isEmpty);
    expect(firstTransport.operations, contains('subscribe:$_service:$_button'));
    expect(secondTransport.operations, contains('subscribe:$_service:$_button'));
    final beforeButtons = firstTransport.writes.length;
    firstTransport.emitButton(2);
    firstTransport.emitButton(0xff);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(firstTransport.writes.length, beforeButtons);
    firstTransport.emitButton(1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(firstTransport.writes.length, beforeButtons + 1);
    expect(firstTransport.writes.last.data, Uint8List.fromList(const [0x10]));
    final secondBeforeButton = secondTransport.writes.length;
    secondTransport.emitButton(1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(secondTransport.writes.length, secondBeforeButton + 1);
    expect(secondTransport.writes.last.data, Uint8List.fromList(const [0x10]));
    await first.startTimer();
    await first.stopTimer();
    await first.resetTimer();
    await first.sleepDisplay();
    await first.wakeDisplay();
    expect(firstTransport.writes.map((write) => write.data.last), containsAllInOrder([0xdd, 0xd1, 0xd0, 0xee, 0xed, 0xec]));
    firstTransport.failNextWrite = true;
    await expectLater(first.tare(), throwsA(anything));
    await first.disconnect();
    final firstAfterDisconnect = firstTransport.writes.length;
    firstTransport.emitWeight();
    firstTransport.emitButton(1);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(firstTransport.writes.length, firstAfterDisconnect);
    expect(manager.bleService.registry.activeBindingCount, 1);
    await second.disconnect();
  });

  test('settings surface uses host storage and survives plugin reload', () async {
    final store = FakeKeyValueStoreService();
    final root = Platform.environment['SKALE_PLUGIN_ROOT'] ?? '.';
    final manifest = PluginManifest.fromJson(
      jsonDecode(File('$root/manifest.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    final manager = PluginManager(kvStore: store);
    await manager.loadPlugin(
      id: manifest.id,
      manifest: manifest,
      settings: const {},
      jsCode: File('$root/plugin.js').readAsStringSync(),
    );
    final initial = await _request(manager, manifest.id, 'settings-get-1', {
      'method': 'GET',
      'query': {'deviceId': 'AA:01'},
    });
    expect(initial['status'], 200);
    expect(jsonDecode(initial['body'] as String), {'deviceId': 'AA:01', 'usbPower': false});
    final invalid = await _request(manager, manifest.id, 'settings-post-invalid', {
      'method': 'POST',
      'query': {'deviceId': 'AA:01'},
      'body': {'usbPower': 'yes'},
    });
    expect(invalid['status'], 400);
    final saved = await _request(manager, manifest.id, 'settings-post-1', {
      'method': 'POST',
      'query': {'deviceId': 'AA:01'},
      'body': {'usbPower': true},
    });
    expect(saved['status'], 200);
    expect(jsonDecode(saved['body'] as String), {'deviceId': 'AA:01', 'usbPower': true});
    final ui = await _request(manager, manifest.id, 'settings-ui', {
      'method': 'GET',
      'query': {'ui': '1'},
    });
    expect(ui['status'], 200);
    expect(ui['body'], contains('Skale settings'));
    await manager.dispose();

    final reloaded = PluginManager(kvStore: store);
    addTearDown(reloaded.dispose);
    await reloaded.loadPlugin(
      id: manifest.id,
      manifest: manifest,
      settings: const {},
      jsCode: File('$root/plugin.js').readAsStringSync(),
    );
    final persisted = await _request(reloaded, manifest.id, 'settings-get-2', {
      'method': 'GET',
      'query': {'deviceId': 'AA:01'},
    });
    expect(persisted['status'], 200);
    expect(jsonDecode(persisted['body'] as String), {'deviceId': 'AA:01', 'usbPower': true});
  });

  test('serializes storage writes across devices before acknowledging each request', () async {
    final store = _DelayedStore()
      ..delays['skale.reaplugin.device.AA:01'] = const Duration(milliseconds: 80)
      ..delays['skale.reaplugin.device.BB:02'] = Duration.zero;
    final root = Platform.environment['SKALE_PLUGIN_ROOT'] ?? '.';
    final manifest = PluginManifest.fromJson(
      jsonDecode(File('$root/manifest.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    final manager = PluginManager(kvStore: store);
    addTearDown(manager.dispose);
    await manager.loadPlugin(
      id: manifest.id,
      manifest: manifest,
      settings: const {},
      jsCode: File('$root/plugin.js').readAsStringSync(),
    );
    final first = _request(manager, manifest.id, 'settings-post-a', {
      'method': 'POST',
      'query': {'deviceId': 'AA:01'},
      'body': {'usbPower': true},
    });
    final second = _request(manager, manifest.id, 'settings-post-b', {
      'method': 'POST',
      'query': {'deviceId': 'BB:02'},
      'body': {'usbPower': true},
    });
    var firstDone = false;
    var secondDone = false;
    first.then((_) => firstDone = true);
    second.then((_) => secondDone = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(firstDone, isFalse);
    expect(secondDone, isFalse);
    expect((await first)['status'], 200);
    expect((await second)['status'], 200);
  });

  test('invalid battery and firmware reads publish nullable metadata', () async {
    final root = Platform.environment['SKALE_PLUGIN_ROOT'] ?? '.';
    final manifest = PluginManifest.fromJson(
      jsonDecode(File('$root/manifest.json').readAsStringSync())
          as Map<String, dynamic>,
    );
    final manager = PluginManager(
      kvStore: FakeKeyValueStoreService(),
      bleRegistry: PluginBleRegistry(activeBindingLimit: 4),
    );
    addTearDown(manager.dispose);
    await manager.loadPlugin(
      id: manifest.id,
      manifest: manifest,
      settings: const {},
      jsCode: File('$root/plugin.js').readAsStringSync(),
    );
    final evidence = BleAdvertisementEvidence(name: 'Skale2', nameComplete: true, serviceUuids: null, servicesComplete: false);
    late _SkaleTransport transport;
    final scale = await manager.bleService.createCandidate(
      driver: manager.bleService.registry.decide(evidence).drivers.single,
      physicalId: 'CC:03',
      evidence: evidence,
      admit: () => true,
      createTransport: () {
        transport = _SkaleTransport('CC:03');
        transport.queueRead(_battery, Uint8List.fromList(const [101]));
        transport.queueRead(_firmware, Uint8List.fromList(const [0xff]));
        return transport;
      },
    ) as Scale;
    final connect = scale.onConnect();
    (scale as ScaleSnapshotHandoff).activateSnapshots();
    final snapshot = scale.currentSnapshot.first;
    final weightPump = Timer.periodic(const Duration(milliseconds: 100), (_) {
      transport.emitWeight();
    });
    try {
      await connect;
    } finally {
      weightPump.cancel();
    }
    expect((await snapshot).weight, 1);
    expect((scale as PluginScale).currentDeviceInformation?.firmwareVersion, isNull);
    expect((scale as PluginScale).currentDeviceInformation?.batteryLevel, isNull);
    await scale.disconnect();
  });

}
