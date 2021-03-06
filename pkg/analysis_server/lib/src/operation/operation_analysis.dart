// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/src/analysis_server.dart';
import 'package:analysis_server/src/computer/computer_closingLabels.dart';
import 'package:analysis_server/src/computer/computer_folding.dart';
import 'package:analysis_server/src/computer/computer_highlights.dart';
import 'package:analysis_server/src/computer/computer_highlights2.dart';
import 'package:analysis_server/src/computer/computer_outline.dart';
import 'package:analysis_server/src/computer/computer_overrides.dart';
import 'package:analysis_server/src/domains/analysis/implemented_dart.dart';
import 'package:analysis_server/src/protocol_server.dart' as protocol;
import 'package:analysis_server/src/services/search/search_engine.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/exception/exception.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/source.dart';

Future<void> scheduleImplementedNotification(
    AnalysisServer server, Iterable<String> files) async {
  // TODO(brianwilkerson) Determine whether this await is necessary.
  await null;
  SearchEngine searchEngine = server.searchEngine;
  if (searchEngine == null) {
    return;
  }
  for (String file in files) {
    CompilationUnit unit = server.getCachedResolvedUnit(file)?.unit;
    CompilationUnitElement unitElement = unit?.declaredElement;
    if (unitElement != null) {
      try {
        ImplementedComputer computer =
            ImplementedComputer(searchEngine, unitElement);
        await computer.compute();
        var params = protocol.AnalysisImplementedParams(
            file, computer.classes, computer.members);
        server.sendNotification(params.toNotification());
      } catch (exception, stackTrace) {
        AnalysisEngine.instance.instrumentationService.logException(
            CaughtException.withMessage(
                'Failed to send analysis.implemented notification.',
                exception,
                stackTrace));
      }
    }
  }
}

void sendAnalysisNotificationAnalyzedFiles(AnalysisServer server) {
  _sendNotification(server, () {
    Set<String> analyzedFiles = server.driverMap.values
        .map((driver) => driver.knownFiles)
        .expand((files) => files)
        .toSet();

    // Exclude *.yaml files because IDEA Dart plugin attempts to index
    // all the files in folders which contain analyzed files.
    analyzedFiles.removeWhere((file) => file.endsWith('.yaml'));

    Set<String> prevAnalyzedFiles = server.prevAnalyzedFiles;
    if (prevAnalyzedFiles != null &&
        prevAnalyzedFiles.length == analyzedFiles.length &&
        prevAnalyzedFiles.difference(analyzedFiles).isEmpty) {
      // No change to the set of analyzed files.  No need to send another
      // notification.
      return;
    }
    server.prevAnalyzedFiles = analyzedFiles;
    protocol.AnalysisAnalyzedFilesParams params =
        protocol.AnalysisAnalyzedFilesParams(analyzedFiles.toList());
    server.sendNotification(params.toNotification());
  });
}

void sendAnalysisNotificationClosingLabels(AnalysisServer server, String file,
    LineInfo lineInfo, CompilationUnit dartUnit) {
  _sendNotification(server, () {
    var labels = DartUnitClosingLabelsComputer(lineInfo, dartUnit).compute();
    var params = protocol.AnalysisClosingLabelsParams(file, labels);
    server.sendNotification(params.toNotification());
  });
}

void sendAnalysisNotificationFlushResults(
    AnalysisServer server, List<String> files) {
  _sendNotification(server, () {
    if (files != null && files.isNotEmpty) {
      var params = protocol.AnalysisFlushResultsParams(files);
      server.sendNotification(params.toNotification());
    }
  });
}

void sendAnalysisNotificationFolding(AnalysisServer server, String file,
    LineInfo lineInfo, CompilationUnit dartUnit) {
  _sendNotification(server, () {
    var regions = DartUnitFoldingComputer(lineInfo, dartUnit).compute();
    var params = protocol.AnalysisFoldingParams(file, regions);
    server.sendNotification(params.toNotification());
  });
}

void sendAnalysisNotificationHighlights(
    AnalysisServer server, String file, CompilationUnit dartUnit) {
  _sendNotification(server, () {
    List<protocol.HighlightRegion> regions;
    if (server.options.useAnalysisHighlight2) {
      regions = DartUnitHighlightsComputer2(dartUnit).compute();
    } else {
      regions = DartUnitHighlightsComputer(dartUnit).compute();
    }
    var params = protocol.AnalysisHighlightsParams(file, regions);
    server.sendNotification(params.toNotification());
  });
}

void sendAnalysisNotificationOutline(
    AnalysisServer server, ResolvedUnitResult resolvedUnit) {
  _sendNotification(server, () {
    protocol.FileKind fileKind;
    if (resolvedUnit.unit.directives.any((d) => d is PartOfDirective)) {
      fileKind = protocol.FileKind.PART;
    } else {
      fileKind = protocol.FileKind.LIBRARY;
    }

    // compute library name
    String libraryName = _computeLibraryName(resolvedUnit.unit);

    // compute Outline
    protocol.Outline outline = DartUnitOutlineComputer(
      resolvedUnit,
      withBasicFlutter: true,
    ).compute();

    // send notification
    var params = protocol.AnalysisOutlineParams(
        resolvedUnit.path, fileKind, outline,
        libraryName: libraryName);
    server.sendNotification(params.toNotification());
  });
}

void sendAnalysisNotificationOverrides(
    AnalysisServer server, String file, CompilationUnit dartUnit) {
  _sendNotification(server, () {
    var overrides = DartUnitOverridesComputer(dartUnit).compute();
    var params = protocol.AnalysisOverridesParams(file, overrides);
    server.sendNotification(params.toNotification());
  });
}

String _computeLibraryName(CompilationUnit unit) {
  for (Directive directive in unit.directives) {
    if (directive is LibraryDirective && directive.name != null) {
      return directive.name.name;
    }
  }
  for (Directive directive in unit.directives) {
    if (directive is PartOfDirective && directive.libraryName != null) {
      return directive.libraryName.name;
    }
  }
  return null;
}

/**
 * Runs the given notification producing function [f], catching exceptions.
 */
void _sendNotification(AnalysisServer server, Function() f) {
  ServerPerformanceStatistics.notices.makeCurrentWhile(() {
    try {
      f();
    } catch (exception, stackTrace) {
      AnalysisEngine.instance.instrumentationService.logException(
          CaughtException.withMessage(
              'Failed to send notification', exception, stackTrace));
    }
  });
}
