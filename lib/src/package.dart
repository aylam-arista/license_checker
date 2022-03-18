import 'dart:convert';
import 'dart:io';

import 'package:pana/pana.dart';
import 'package:pana/src/license_detection/license_detector.dart'
    as pana_license_detector;
import 'package:path/path.dart';

import 'package:license_checker/src/config.dart';

const String noFileLicense = 'no-file';
const String unknownLicense = 'unknown-license';
const String unknownCopyright = 'unknown-copyright';
const String unknownSource = 'unknown-source';
RegExp coprightRegex = RegExp(
  r'Copyright\s(\(c\)\s)*(?<date>[0-9]{4})(?<holders>.+)\n',
  caseSensitive: false,
  multiLine: false,
);

final _licenseFileNames = [
  ...textFileNameCandidates('LICENSE'),
  ...textFileNameCandidates('LICENCE'),
  ...textFileNameCandidates('COPYING'),
  ...textFileNameCandidates('UNLICENSE'),
  ...textFileNameCandidates('License'),
  ...textFileNameCandidates('Licence'),
  ...textFileNameCandidates('Copying'),
  ...textFileNameCandidates('Unlicense'),
  ...textFileNameCandidates('license'),
  ...textFileNameCandidates('licence'),
  ...textFileNameCandidates('copying'),
  ...textFileNameCandidates('unlicense'),
];

enum LicenseStatus {
  unknown,
  approved,
  permitted,
  rejected,
  needsApproval,
  noLicense,
}

/// Represents the config of the package we are checking dependencies for.
class PackageConfig {
  /// Add dependent packages
  final List<Package> packages;

  /// The pubspec config for the package
  final Pubspec pubspec;

  /// The liscense checker config. Includes permitted licenses and approved packages.
  final Config config;

  /// Constructor for package config
  PackageConfig({
    required this.pubspec,
    required this.packages,
    required this.config,
  });

  PackageConfig._({
    required this.pubspec,
    required this.packages,
    required this.config,
  });

  /// Constructs a package config from json
  factory PackageConfig.fromJson({
    required Pubspec pubspec,
    required Config config,
    required Object source,
  }) {
    List<Package> packages = [];
    if (source is! Map) {
      throw FormatException();
    }
    Object packagesSource = source['packages'] as Object? ?? [];
    if (packagesSource is! List) {
      throw FormatException();
    }
    for (Object p in packagesSource) {
      Package pkg = Package.fromJson(config: config, source: p);
      if (pkg.name == pubspec.name) {
        // Don't add or check self
        continue;
      }
      packages.add(pkg);
    }

    return PackageConfig._(
      pubspec: pubspec,
      packages: packages,
      config: config,
    );
  }

  /// Creates a package config from a file. Throws an error if the format is incorrect.
  factory PackageConfig.fromFile({
    required File pubspecFile,
    required File packageConfigFile,
    required Config config,
  }) {
    if (!pubspecFile.existsSync()) {
      return throw FileSystemException(
        'pubspec.yaml file not found in current directory.',
      );
    }

    if (!packageConfigFile.existsSync()) {
      return throw FileSystemException(
        '.dart_tool/package_config.json file not found in current directory. You may need to run "flutter pub get" or "dart pub get".',
      );
    }

    return PackageConfig.fromJson(
      pubspec: Pubspec.parseYaml(pubspecFile.readAsStringSync()),
      config: config,
      source: json.decode(packageConfigFile.readAsStringSync()),
    );
  }
}

/// Represents a single package that is a dependency of the package we are checking.
class Package {
  /// The name of the package
  final String name;

  /// The root uri of the package
  final String rootUri;

  final Config config;

  /// Constructor that creates a package.
  Package({required this.name, required this.rootUri, required this.config});

  Package._({
    required this.name,
    required this.rootUri,
    required this.config,
  });

  /// Constructs a package from json
  factory Package.fromJson({required Config config, required Object source}) {
    if (source is! Map) {
      throw FormatException();
    }

    String rootUri = source['rootUri'] ?? '<unknown root uri>';
    if (rootUri.startsWith('file://')) {
      if (Platform.isWindows) {
        rootUri = rootUri.substring(8);
      } else {
        rootUri = rootUri.substring(7);
      }
    }

    return Package._(
      name: source['name'] ?? '<unknown name>',
      rootUri: rootUri,
      config: config,
    );
  }

  /// Returns the license status of the package.
  Future<LicenseStatus> get packageLicenseStatus async {
    String lname = await licenseName;

    // No file found
    if (lname == noFileLicense) {
      // Check approved packages
      return _checkApprovedPackages(noFileLicense) ?? LicenseStatus.noLicense;
    }

    if (lname == unknownLicense) {
      return LicenseStatus.unknown;
    }

    // Check different cases defined in the config
    return Future.value(
      _checkLicense(
            lname,
            config.permittedLicenses,
            LicenseStatus.permitted,
          ) ??
          _checkLicense(
            lname,
            config.rejectedLicenses,
            LicenseStatus.rejected,
          ) ??
          _checkApprovedPackages(lname) ??
          LicenseStatus.needsApproval,
    );
  }

  File? get licenseFile {
    for (String fileName in _licenseFileNames) {
      File file = File(join(rootUri, fileName));
      if (file.existsSync()) {
        return file;
      }
    }

    return null;
  }

  /// The license name associated with the package
  Future<String> get licenseName async {
    if (licenseFile == null) {
      return noFileLicense;
    }

    String content = await licenseFile!.readAsString();
    pana_license_detector.Result res =
        await pana_license_detector.detectLicense(content, 0.9);
    // Just the first match (highest probability) as the license.
    return res.matches.isNotEmpty
        ? res.matches.first.identifier
        : unknownLicense;
  }

  Future<String> get copyright async {
    if (licenseFile == null) {
      return unknownCopyright;
    }

    String content = await licenseFile!.readAsString();
    RegExpMatch? match = coprightRegex.firstMatch(content);
    String? copyrightText = (match?.namedGroup('date') ?? '') +
        (match?.namedGroup('holders') ?? unknownCopyright);

    return copyrightText;
  }

  /// Returns the location where the source can be found
  String get sourceLocation {
    String sourceLocation = unknownSource;
    File file = File(join(rootUri, 'pubspec.yaml'));
    if (!file.existsSync()) {
      return throw FileSystemException(
        'pubspec.yaml file not found in package $name.',
      );
    }

    sourceLocation =
        Pubspec.parseYaml(file.readAsStringSync()).repositoryOrHomepage ??
            unknownSource;

    return sourceLocation;
  }

  LicenseStatus? _checkApprovedPackages(String lName) {
    List<String>? pkgs = config.approvedPackages[lName];
    if (pkgs != null && pkgs.contains(name)) {
      // Has been explicitly approved
      return LicenseStatus.approved;
    }
    return null;
  }

  LicenseStatus? _checkLicense(
    String lName,
    List<String> licenses,
    LicenseStatus status,
  ) {
    if (licenses.contains(lName)) {
      return status;
    }
    return null;
  }
}
