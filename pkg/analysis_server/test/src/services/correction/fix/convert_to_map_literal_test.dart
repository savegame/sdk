// Copyright (c) 2020, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analysis_server/src/services/correction/fix.dart';
import 'package:analysis_server/src/services/linter/lint_names.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import 'fix_processor.dart';

main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(ConvertToMapLiteralTest);
  });
}

@reflectiveTest
class ConvertToMapLiteralTest extends FixProcessorLintTest {
  @override
  FixKind get kind => DartFixKind.CONVERT_TO_MAP_LITERAL;

  @override
  String get lintCode => LintNames.prefer_collection_literals;

  test_default_declaredType() async {
    await resolveTestUnit('''
Map m = /*LINT*/Map();
''');
    await assertHasFix('''
Map m = {};
''');
  }

  test_default_linkedHashMap() async {
    await resolveTestUnit('''
import 'dart:collection';
var m = /*LINT*/LinkedHashMap();
''');
    await assertHasFix('''
import 'dart:collection';
var m = {};
''');
  }

  test_default_minimal() async {
    await resolveTestUnit('''
var m = /*LINT*/Map();
''');
    await assertHasFix('''
var m = {};
''');
  }

  test_default_newKeyword() async {
    await resolveTestUnit('''
var m = /*LINT*/new Map();
''');
    await assertHasFix('''
var m = {};
''');
  }

  test_default_typeArg() async {
    await resolveTestUnit('''
var m = /*LINT*/Map<String, int>();
''');
    await assertHasFix('''
var m = <String, int>{};
''');
  }
}
