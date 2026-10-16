import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'cold_state_lease.dart';
import 'image_filesystem.dart';
import 'macos_driver_inventory.dart';
import 'macos_open_references.dart';
import 'macos_release_inspection.dart';
import 'maintenance_command.dart';
import 'maintenance_tree.dart';
import 'maintenance_state_fence.dart';

part 'macos_app_retirement.dart';
part 'macos_candidate_publication.dart';

/// Native read-only cold observations bound to one freshly inspected app.
/// No registration, stop, signal, replacement or catalog opening is performed.
final class MacOsColdStateHost implements ColdStateHost {
  MacOsColdStateHost._(
    this._app,
    this._release,
    ReleaseInspectionHost host,
    this._observer,
    this._inventory, [
    this._retirement,
  ]) : _host = _PublicationExecution(host);
  final MaintenanceTree _app;
  final Map<String, Object?> _release;
  final ReleaseInspectionHost _host;
  final MacOsOpenReferences _observer;
  final Future<DriverInventorySnapshot> Function(String) _inventory;
  final _AppRetirement? _retirement;
  String? _validationExecutable;
  DriverProcessIdentity? _validationProcess;
  @override
  String get appPath => _app.path;
  String get installationPath => _retirement?.sourceAppPath ?? appPath;
  bool get isRetired => _retirement != null;
  bool get isValidatingCandidate => _validationExecutable != null;
  Map<String, Object?> get retirementEvidence {
    final retirement = _retirement;
    if (retirement == null) throw StateError('app has not been retired');
    return {
      'phase': 'old_app_retired',
      'source_app': installationPath,
      'retired_app': appPath,
      'journal_path': retirement._root.path,
      'intent_digest': 'sha256:${sha256.convert(retirement._bytes)}',
      'installed_candidate_published':
          retirement._publication?.evidence['installed_candidate_published'] ??
          false,
      'activation_authorized': false,
      'rollback_authorized': false,
    };
  }

  /// Last verified placement only, never startup/commit/restore authority.
  Map<String, Object?> get publicationEvidence =>
      _retirement?._publication?.evidence ??
      (throw StateError('candidate publication has not been opened'));

  /// Stable publication bindings, not a cold permit or a validating self PID.
  /// A recovery coordinator must reacquire the actual state/fence ownership.
  Map<String, Object?> get publicationBindingEvidence {
    final publication = _retirement?._publication;
    if (publication == null) throw StateError('verified publication required');
    return {
      ...publication.evidence,
      'publication_intent_digest':
          'sha256:${sha256.convert(_AppRetirement._encode(publication._intent))}',
      'publication_record_digest':
          'sha256:${sha256.convert(_AppRetirement._encode(publication._record))}',
      'candidate_manifest_digest':
          'sha256:${sha256.convert(_AppRetirement._encode(publication._intent['candidate_manifest'] as Map<String, Object?>))}',
      'candidate_identity': Map<String, Object?>.from(
        publication._record['candidate_identity'] as Map,
      ),
    };
  }

  Map<String, Object?> get validationAdmissionEvidence {
    final process = _validationProcess;
    if (!isValidatingCandidate || process == null) {
      throw StateError('verified executing candidate required');
    }
    return {
      ...publicationBindingEvidence,
      'executing_process': {
        'pid': process.pid,
        'uid': process.uid,
        'executable_path': process.executablePath,
        'started_at_microseconds': process.startedAtMicroseconds,
        'pid_version': process.pidVersion,
      },
    };
  }

  static Future<MacOsColdStateHost> open(
    Directory app, {
    required String bundleIdentifier,
    required String version,
    required String teamIdentifier,
    required int catalogSchema,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
  }) async {
    final inspected = await inspectMacOsRelease(
      app,
      bundleIdentifier: bundleIdentifier,
      version: version,
      teamIdentifier: teamIdentifier,
      catalogSchema: catalogSchema,
      host: _PublicationExecution(host),
    );
    final manifest = inspected['tree'] as Map<String, Object?>;
    final tree = await MaintenanceTree.open(app);
    try {
      await tree.verify(manifest);
      return MacOsColdStateHost._(
        tree,
        inspected,
        host,
        observer ?? MacOsOpenReferences(),
        inventory ??
            (path) => MacOsDriverInventory(executablePath: path).snapshot(),
      );
    } catch (_) {
      tree.close();
      rethrow;
    }
  }

  /// Explicit read-only recovery of the old-app retirement gap. No paths from
  /// the journal select targets; the caller supplies the original slot, state,
  /// fence, storage/name and expected release. Still needs the real state lock.
  /// A relocated original additionally requires both active inode-bound fences.
  static Future<MacOsColdStateHost> openRetired(
    Directory originalApp,
    Directory state,
    MaintenanceStateFence fence,
    OwnedImageDirectory storage,
    String name, {
    required String bundleIdentifier,
    required String version,
    required String teamIdentifier,
    required int catalogSchema,
    MaintenanceStateFence? preservedOriginal,
    ColdStateRestoration? stateRestoration,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
  }) => _AppRetirement.open(
    originalApp,
    state,
    fence,
    storage,
    name,
    bundleIdentifier: bundleIdentifier,
    version: version,
    teamIdentifier: teamIdentifier,
    catalogSchema: catalogSchema,
    preservedOriginal: preservedOriginal,
    stateRestoration: stateRestoration,
    host: _PublicationExecution(host),
    observer: observer ?? MacOsOpenReferences(),
    inventory:
        inventory ??
        (path) => MacOsDriverInventory(executablePath: path).snapshot(),
  );

  /// Read-only interrupted-publication recovery. All target/release selectors
  /// come from the operator; journal paths never select an app or state target.
  /// A fresh actual state lock and complete cold check are still required.
  static Future<MacOsColdStateHost> openPublished(
    Directory originalApp,
    Directory state,
    MaintenanceStateFence fence,
    OwnedImageDirectory retirementStorage,
    String retirementName,
    OwnedImageDirectory publicationStorage,
    String publicationName, {
    required String bundleIdentifier,
    required String oldVersion,
    required String newVersion,
    required String teamIdentifier,
    required int retiredCatalogSchema,
    required int catalogSchema,
    MaintenanceStateFence? preservedOriginal,
    ColdStateRestoration? stateRestoration,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
  }) => _AppRetirement.open(
    originalApp,
    state,
    fence,
    retirementStorage,
    retirementName,
    bundleIdentifier: bundleIdentifier,
    version: oldVersion,
    teamIdentifier: teamIdentifier,
    catalogSchema: retiredCatalogSchema,
    preservedOriginal: preservedOriginal,
    stateRestoration: stateRestoration,
    host: _PublicationExecution(host),
    observer: observer ?? MacOsOpenReferences(),
    inventory:
        inventory ??
        (path) => MacOsDriverInventory(executablePath: path).snapshot(),
    publication: (
      storage: publicationStorage,
      name: publicationName,
      version: newVersion,
      catalogSchema: catalogSchema,
    ),
  );

  /// Only the executing installed candidate may enter this observation scope.
  /// Its own exact, versioned daemon identity is expected; no other process or
  /// unresolved PID is waived. Ordinary cold acquisition is unchanged.
  static Future<MacOsColdStateHost> openPublishedForValidation(
    Directory originalApp,
    Directory state,
    MaintenanceStateFence fence,
    OwnedImageDirectory storage, {
    required String bundleIdentifier,
    required String oldVersion,
    required String newVersion,
    required String teamIdentifier,
    required int catalogSchema,
    ReleaseInspectionHost host = const MacOsReleaseInspectionHost(),
    MacOsOpenReferences? observer,
    Future<DriverInventorySnapshot> Function(String)? inventory,
    Future<String> Function()? currentExecutable,
  }) async {
    final executing =
        await (currentExecutable?.call() ??
            File(Platform.resolvedExecutable).resolveSymbolicLinks());
    if (executing != '${originalApp.path}/Contents/MacOS/gaovmd') {
      throw const FormatException(
        'validation must execute the installed candidate daemon',
      );
    }
    final result = await openPublished(
      originalApp,
      state,
      fence,
      storage,
      'retirement',
      storage,
      'publication',
      bundleIdentifier: bundleIdentifier,
      oldVersion: oldVersion,
      newVersion: newVersion,
      teamIdentifier: teamIdentifier,
      retiredCatalogSchema: 0,
      catalogSchema: catalogSchema,
      host: host,
      observer: observer,
      inventory: inventory,
    );
    try {
      if (result.publicationEvidence['phase'] != 'candidate_published') {
        throw const FormatException('installed candidate publication required');
      }
      result._validationExecutable = executing;
      return result;
    } catch (_) {
      result.close();
      rethrow;
    }
  }

  @override
  Future<ProcessResult> serviceStatus() async {
    await _verifyApp();
    final result = await _host.run(
      '${_app.path}/Contents/MacOS/gaovm-service',
      ['status'],
    );
    await _verifyApp();
    return result;
  }

  @override
  Future<DriverInventorySnapshot> inventory({required bool driver}) async {
    final processes = <DriverProcessIdentity>{};
    final unresolved = <int>{};
    for (final root in {
      installationPath,
      appPath,
      ...?_retirement?._publication?.candidatePaths,
    }) {
      final result = await _inventory(
        driver
            ? '$root/Contents/Helpers/gaovm-driver-vz'
            : '$root/Contents/MacOS/gaovmd',
      );
      processes.addAll(result.processes);
      unresolved.addAll(result.unresolvedProcessIds);
    }
    if (!driver && _validationExecutable != null) {
      final self = processes.where((process) => process.pid == pid).toList();
      if (self.length != 1 ||
          self.single.executablePath != _validationExecutable ||
          self.single.pidVersion == null ||
          (_validationProcess != null && self.single != _validationProcess)) {
        throw const ColdStateFailure(
          'validation_process',
          'executing candidate identity is missing or changed',
        );
      }
      _validationProcess ??= self.single;
      processes.remove(self.single);
    }
    return DriverInventorySnapshot(
      processes: processes,
      unresolvedProcessIds: unresolved,
    );
  }

  @override
  Future<Set<int>> stateReferences(Directory state) async {
    final references = await _observer.directory(state);
    if (isRetired) await _AppRetirement._noReferences(_observer, appPath);
    final publication = _retirement?._publication;
    if (publication != null) {
      await publication.verify();
      await _AppRetirement._noReferences(_observer, publication.candidatePath);
      await _AppRetirement._noReferences(
        _observer,
        '${publication._root.path}/probe',
      );
    }
    return references;
  }

  Future<void> _verifyApp() async {
    await _retirement?.verify(_app);
    await _app.verify(_release['tree'] as Map<String, Object?>);
  }

  /// Used only by a held cold lease. Returns a new owner of the retired app and
  /// journal readers; the old host is deliberately not silently rebased.
  Future<MacOsColdStateHost> retireForMaintenance(
    ColdStateLease state,
    MaintenanceStateFence fence,
    OwnedImageDirectory storage,
    String name, {
    required Future<void> Function() verifyPreparedInputs,
  }) => _AppRetirement.create(
    this,
    state,
    fence,
    storage,
    name,
    verifyPreparedInputs: verifyPreparedInputs,
  );

  Future<void> verifyRetirementFor(
    OwnedImageDirectory state,
    MaintenanceStateFence fence, {
    required String bundleIdentifier,
    required String installationPath,
    MaintenanceStateFence? preservedOriginal,
  }) async {
    final retirement = _retirement;
    if (retirement == null) throw StateError('retirement proof required');
    await fence.verifyFor(
      state,
      bundleIdentifier: bundleIdentifier,
      appPath: installationPath,
    );
    if (preservedOriginal != null) {
      await preservedOriginal.verifyRelocatedOriginal(
        state,
        fence,
        bundleIdentifier: bundleIdentifier,
        appPath: installationPath,
      );
    }
    final origin = preservedOriginal ?? fence;
    if (retirement._intent['source_state'] != origin.sourceStatePath ||
        retirement._intent['fence_path'] != origin.path ||
        retirement.sourceAppPath != installationPath ||
        retirement._intent['bundle_identifier'] != bundleIdentifier ||
        jsonEncode(retirement._intent['state_identity']) !=
            jsonEncode(await state.maintenanceIdentity())) {
      throw const FormatException('retirement does not belong to held state');
    }
    await _verifyApp();
  }

  Future<Map<String, Object?>> publishForMaintenance(
    ColdStateLease state,
    MaintenanceStateFence fence,
    OwnedImageDirectory storage,
    String name,
    Directory candidate, {
    required String version,
    required int catalogSchema,
    required Map<String, Object?> candidateManifest,
    required Future<void> Function() verifyPreparedInputs,
  }) async {
    final retirement = _retirement;
    if (retirement == null) throw StateError('retired native app required');
    if (state.appPath != appPath ||
        state.installationPath != installationPath ||
        state.path != retirement._intent['source_state'] ||
        state.bundleIdentifier != retirement._intent['bundle_identifier'] ||
        fence.path != retirement._intent['fence_path']) {
      throw const FormatException(
        'publication requires the matching original cold lease',
      );
    }
    var publication = retirement._publication;
    if (publication == null) {
      publication = await _CandidatePublication.create(
        this,
        state,
        fence,
        storage,
        name,
        candidate,
        version: version,
        catalogSchema: catalogSchema,
        manifest: candidateManifest,
      );
      // Keep the typed journal/namespace owner even if rename or its later
      // inspection fails. Closing it here would lose in-process recovery.
      retirement._publication = publication;
    } else if (publication._root.path != '${storage.path}/$name' ||
        publication._intent['candidate_source'] != candidate.path ||
        publication._intent['new_version'] != version ||
        publication._intent['catalog_schema'] != catalogSchema ||
        !_AppRetirement._equal(
          publication._intent['candidate_manifest'],
          candidateManifest,
        )) {
      throw const FormatException('publication disagrees with explicit inputs');
    }
    await publication.publish(this, state, verifyPreparedInputs);
    return publication.evidence;
  }

  void close() {
    _app.close();
    _retirement?.close();
  }
}
