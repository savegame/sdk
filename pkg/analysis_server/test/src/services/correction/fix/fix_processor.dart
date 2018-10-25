// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/plugin/edit/fix/fix_core.dart';
import 'package:analysis_server/plugin/edit/fix/fix_dart.dart';
import 'package:analysis_server/src/services/correction/fix_internal.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/file_system/file_system.dart';
import 'package:analyzer/src/dart/analysis/ast_provider_driver.dart';
import 'package:analyzer/src/dart/analysis/driver.dart';
import 'package:analyzer/src/dart/element/ast_provider.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart'
    hide AnalysisError;
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';
import 'package:test/test.dart';

import '../../../../abstract_single_unit.dart';

/// A base class defining support for writing fix processor tests.
abstract class FixProcessorTest extends AbstractSingleUnitTest {
  /// The errors in the file for which fixes are being computed.
  List<AnalysisError> _errors;

  /// The source change associated with the fix that was found, or `null` if
  /// neither [assertHasFix] nor [assertHasFixAllFix] has been invoked.
  SourceChange change;

  /// The result of applying the [change] to the file content, or `null` if
  //  /// neither [assertHasFix] nor [assertHasFixAllFix] has been invoked.
  String resultCode;

  /// Return the kind of fixes being tested by this test class.
  FixKind get kind;

  Future<void> assertHasFix(String expected,
      {bool Function(AnalysisError) errorFilter, String target}) async {
    AnalysisError error = await _findErrorToFix(errorFilter);
    Fix fix = await _assertHasFix(error);
    change = fix.change;

    // apply to "file"
    List<SourceFileEdit> fileEdits = change.edits;
    expect(fileEdits, hasLength(1));

    String fileContent = testCode;
    if (target != null) {
      expect(fileEdits.first.file, convertPath(target));
      fileContent = getFile(target).readAsStringSync();
    }

    resultCode = SourceEdit.applySequence(fileContent, change.edits[0].edits);
    // verify
    expect(resultCode, expected);
  }

  assertHasFixAllFix(ErrorCode errorCode, String expected,
      {String target}) async {
    AnalysisError error = await _findErrorToFixOfType(errorCode);
    Fix fix = await _assertHasFixAllFix(error);
    change = fix.change;

    // apply to "file"
    List<SourceFileEdit> fileEdits = change.edits;
    expect(fileEdits, hasLength(1));

    String fileContent = testCode;
    if (target != null) {
      expect(fileEdits.first.file, convertPath(target));
      fileContent = getFile(target).readAsStringSync();
    }

    resultCode = SourceEdit.applySequence(fileContent, change.edits[0].edits);
    // verify
    expect(resultCode, expected);
  }

  void assertLinkedGroup(LinkedEditGroup group, List<String> expectedStrings,
      [List<LinkedEditSuggestion> expectedSuggestions]) {
    List<Position> expectedPositions = _findResultPositions(expectedStrings);
    expect(group.positions, unorderedEquals(expectedPositions));
    if (expectedSuggestions != null) {
      expect(group.suggestions, unorderedEquals(expectedSuggestions));
    }
  }

  /// Compute fixes and ensure that there is no fix of the [kind] being tested by
  /// this class.
  Future<void> assertNoFix({bool Function(AnalysisError) errorFilter}) async {
    AnalysisError error = await _findErrorToFix(errorFilter);
    await _assertNoFix(error);
  }

  List<LinkedEditSuggestion> expectedSuggestions(
      LinkedEditSuggestionKind kind, List<String> values) {
    return values.map((value) {
      return new LinkedEditSuggestion(value, kind);
    }).toList();
  }

  @override
  void setUp() {
    super.setUp();
    verifyNoTestUnitErrors = false;
  }

  /// Computes fixes and verifies that there is a fix for the given [error] of
  /// the appropriate kind.
  Future<Fix> _assertHasFix(AnalysisError error) async {
    // Compute the fixes for this AnalysisError
    final List<Fix> fixes = await _computeFixes(error);

    // Assert that none of the fixes are a fix-all fix.
    Fix foundFix = null;
    for (Fix fix in fixes) {
      if (fix.isFixAllFix()) {
        fail('A fix-all fix was found for the error: $error '
            'in the computed set of fixes:\n${fixes.join('\n')}');
      } else if (fix.kind == kind) {
        foundFix ??= fix;
      }
    }
    if (foundFix == null) {
      fail('Expected to find fix $kind in\n${fixes.join('\n')}');
    }
    return foundFix;
  }

  /// Computes fixes and verifies that there is a fix for the given [error] of
  /// the appropriate kind.
  Future<Fix> _assertHasFixAllFix(AnalysisError error) async {
    if (!kind.canBeAppliedTogether()) {
      fail('Expected to find and return fix-all FixKind for $kind, '
          'but kind.canBeAppliedTogether is ${kind.canBeAppliedTogether}');
    }

    // Compute the fixes for the error.
    List<Fix> fixes = await _computeFixes(error);

    // Assert that there exists such a fix in the list.
    Fix foundFix = null;
    for (Fix fix in fixes) {
      if (fix.kind == kind && fix.isFixAllFix()) {
        foundFix = fix;
        break;
      }
    }
    if (foundFix == null) {
      fail('No fix-all fix was found for the error: $error '
          'in the computed set of fixes:\n${fixes.join('\n')}');
    }
    return foundFix;
  }

  Future<void> _assertNoFix(AnalysisError error) async {
    List<Fix> fixes = await _computeFixes(error);
    for (Fix fix in fixes) {
      if (fix.kind == kind) {
        fail('Unexpected fix $kind in\n${fixes.join('\n')}');
      }
    }
  }

  Future<List<AnalysisError>> _computeErrors() async {
    return _errors ??= (await driver.getResult(convertPath(testFile))).errors;
  }

  /// Computes fixes for the given [error] in [testUnit].
  Future<List<Fix>> _computeFixes(AnalysisError error) async {
    DartFixContext fixContext = new _DartFixContextImpl(
        resourceProvider,
        driver,
        new AstProviderForDriver(driver),
        testUnit,
        error,
        await _computeErrors());
    return await new DartFixContributor().computeFixes(fixContext);
  }

  /// Find the error that is to be fixed by computing the errors in the file,
  /// using the [errorFilter] to filter out errors that should be ignored, and
  /// expecting that there is a single remaining error. The error filter should
  /// return `true` if the error should not be ignored.
  Future<AnalysisError> _findErrorToFix(
      bool Function(AnalysisError) errorFilter) async {
    List<AnalysisError> errors = await _computeErrors();
    if (errorFilter != null) {
      if (errors.length == 1) {
        fail('Unnecessary error filter');
      }
      errors = errors.where(errorFilter).toList();
    }
    if (errors.length == 0) {
      fail('Expected one error, found: none');
    } else if (errors.length > 1) {
      StringBuffer buffer = new StringBuffer();
      buffer.writeln('Expected one error, found:');
      for (AnalysisError error in errors) {
        buffer.writeln('  $error [${error.errorCode}]');
      }
      fail(buffer.toString());
    }
    return errors[0];
  }

  Future<AnalysisError> _findErrorToFixOfType(ErrorCode errorCode) async {
    List<AnalysisError> errors = await _computeErrors();
    for (AnalysisError error in errors) {
      if (error.errorCode == errorCode) {
        return error;
      }
    }
    return null;
  }

  List<Position> _findResultPositions(List<String> searchStrings) {
    List<Position> positions = <Position>[];
    for (String search in searchStrings) {
      int offset = resultCode.indexOf(search);
      positions.add(new Position(testFile, offset));
    }
    return positions;
  }
}

/// A Dart fix context optimized for testing.
class _DartFixContextImpl implements DartFixContext {
  @override
  final ResourceProvider resourceProvider;

  @override
  final AnalysisDriver analysisDriver;

  @override
  final AstProvider astProvider;

  @override
  final CompilationUnit unit;

  @override
  final AnalysisError error;

  @override
  final List<AnalysisError> errors;

  _DartFixContextImpl(this.resourceProvider, this.analysisDriver,
      this.astProvider, this.unit, this.error, this.errors);

  @override
  GetTopLevelDeclarations get getTopLevelDeclarations =>
      analysisDriver.getTopLevelNameDeclarations;
}
