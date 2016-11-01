// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
library kernel.ast_to_binary;

import '../ast.dart';
import '../import_table.dart';
import 'tag.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:collection';

/// Writes to a binary file.
///
/// A [BinaryPrinter] can be used to write one file and must then be
/// discarded.
class BinaryPrinter extends Visitor {
  ImportTable _importTable;

  // TODO: We can do the indexing on-the-fly, but for now just keep it simple.
  VariableIndexer _variableIndexer;
  LabelIndexer _labelIndexer;
  SwitchCaseIndexer _switchCaseIndexer;
  final TypeParameterIndexer _typeParameterIndexer = new TypeParameterIndexer();
  final GlobalIndexer _globalIndexer;
  final StringIndexer _stringIndexer = new StringIndexer();
  final StringIndexer _sourceUriIndexer = new StringIndexer();

  final BufferedSink _sink;

  /// Create a printer that writes to the given [sink].
  ///
  /// The BinaryPrinter will use its own buffer, so the [sink] does not need
  /// one.
  ///
  /// If multiple binaries are to be written based on the same IR, a shared
  /// [globalIndexer] may be passed in to avoid rebuilding the same indices
  /// in every printer.
  BinaryPrinter(Sink<List<int>> sink, {GlobalIndexer globalIndexer})
      : _sink = new BufferedSink(sink),
        _globalIndexer = globalIndexer ?? new GlobalIndexer();

  void _flush() {
    _sink.flushAndDestroy();
  }

  void writeByte(int byte) {
    _sink.addByte(byte);
  }

  void writeBytes(List<int> bytes) {
    _sink.addBytes(bytes);
  }

  void writeUInt30(int value) {
    assert(value >= 0 && value >> 30 == 0);
    if (value < 0x80) {
      writeByte(value);
    } else if (value < 0x4000) {
      writeByte((value >> 8) | 0x80);
      writeByte(value & 0xFF);
    } else {
      writeByte((value >> 24) | 0xC0);
      writeByte((value >> 16) & 0xFF);
      writeByte((value >> 8) & 0xFF);
      writeByte(value & 0xFF);
    }
  }

  void writeMagicWord(int value) {
    writeByte((value >> 24) & 0xFF);
    writeByte((value >> 16) & 0xFF);
    writeByte((value >> 8) & 0xFF);
    writeByte(value & 0xFF);
  }

  void writeStringTableEntry(String string) {
    List<int> utf8Bytes = const Utf8Encoder().convert(string);
    writeUInt30(utf8Bytes.length);
    writeBytes(utf8Bytes);
  }

  void writeStringTable(StringIndexer indexer) {
    writeUInt30(indexer.numberOfStrings);
    for (var entry in indexer.entries) {
      writeStringTableEntry(entry.value);
    }
  }

  void writeStringReference(String string) {
    writeUInt30(_stringIndexer[string]);
  }

  void writeUriReference(String string) {
    writeUInt30(_sourceUriIndexer[string]);
  }

  void writeList(List items, writeItem(x)) {
    writeUInt30(items.length);
    items.forEach(writeItem);
  }

  void writeNodeList(List<Node> nodes) {
    writeList(nodes, writeNode);
  }

  void writeNode(Node node) {
    node.accept(this);
  }

  void writeOptionalNode(Node node) {
    if (node == null) {
      writeByte(Tag.Nothing);
    } else {
      writeByte(Tag.Something);
      writeNode(node);
    }
  }

  void writeOptionalInferredValue(InferredValue node) {
    if (node == null) {
      writeByte(Tag.Nothing);
    } else {
      writeByte(Tag.Something);
      writeClassReference(node.baseClass, allowNull: true);
      writeByte(node.baseClassKind.index);
      writeByte(node.valueBits);
    }
  }

  void writeProgramFile(Program program) {
    writeMagicWord(Tag.ProgramFile);
    _importTable = new ProgramImportTable(program);
    _stringIndexer.build(program);
    writeStringTable(_stringIndexer);
    writeUriToLineStarts(program);
    writeList(program.libraries, writeNode);
    writeMemberReference(program.mainMethod, allowNull: true);
    _flush();
  }

  void writeUriToLineStarts(Program program) {
    program.uriToLineStarts.keys.forEach((uri) {
      _sourceUriIndexer.put(uri);
    });
    writeStringTable(_sourceUriIndexer);
    for (int i = 0; i < _sourceUriIndexer.entries.length; i++) {
      String uri = _sourceUriIndexer.entries[i].value;
      List<int> lineStarts = program.uriToLineStarts[uri] ?? [];
      writeUInt30(lineStarts.length);
      int previousLineStart = 0;
      lineStarts.forEach((lineStart) {
        writeUInt30(lineStart - previousLineStart);
        previousLineStart = lineStart;
      });
    }
  }

  void writeLibraryImportTable(LibraryImportTable imports) {
    writeList(imports.importPaths, writeStringReference);
  }

  void writeLibraryReference(Library node) {
    int index = _importTable.getImportIndex(node);
    if (index == -1) {
      throw 'Missing import for library: ${node.importUri}';
    }
    writeUInt30(index);
  }

  void writeClassIndex(Class node) {
    writeUInt30(_globalIndexer[node]);
  }

  void writeClassReference(Class node, {bool allowNull: false}) {
    if (node == null) {
      if (allowNull) {
        writeByte(Tag.NullReference);
      } else {
        throw 'Expected a class reference to be valid but was `null`.';
      }
    } else {
      node.acceptReference(this);
    }
  }

  void writeMemberReference(Member node, {bool allowNull: false}) {
    if (node == null) {
      if (allowNull) {
        writeByte(Tag.NullReference);
      } else {
        throw 'Expected a member reference to be valid but was `null`.';
      }
    } else {
      node.acceptReference(this);
    }
  }

  writeOffset(TreeNode node) {
    // TODO(jensj): Delta-encoding.
    // File offset ranges from -1 and up,
    // but is here saved as unsigned (thus the +1)
    writeUInt30(node.fileOffset + 1);
  }

  void visitClassReference(Class node) {
    var library = node.enclosingLibrary;
    writeByte(node.isMixinApplication
        ? Tag.MixinClassReference
        : Tag.NormalClassReference);
    writeLibraryReference(library);
    writeClassIndex(node);
  }

  void visitFieldReference(Field node) {
    if (node.enclosingClass != null) {
      writeByte(Tag.ClassFieldReference);
      Class classNode = node.enclosingClass;
      writeClassReference(classNode);
      writeUInt30(_globalIndexer[node]);
    } else {
      writeByte(Tag.LibraryFieldReference);
      writeLibraryReference(node.enclosingLibrary);
      writeUInt30(_globalIndexer[node]);
    }
  }

  void visitConstructorReference(Constructor node) {
    writeByte(Tag.ClassConstructorReference);
    writeClassReference(node.enclosingClass);
    writeUInt30(_globalIndexer[node]);
  }

  void visitProcedureReference(Procedure node) {
    if (node.enclosingClass != null) {
      writeByte(Tag.ClassProcedureReference);
      Class classNode = node.enclosingClass;
      writeClassReference(classNode);
      writeUInt30(_globalIndexer[node]);
    } else {
      writeByte(Tag.LibraryProcedureReference);
      writeLibraryReference(node.enclosingLibrary);
      writeUInt30(_globalIndexer[node]);
    }
  }

  void writeName(Name node) {
    writeStringReference(node.name);
    // TODO: Consider a more compressed format for private names within the
    // enclosing library.
    if (node.isPrivate) {
      writeLibraryReference(node.library);
    }
  }

  bool insideExternalLibrary = false;

  visitLibrary(Library node) {
    insideExternalLibrary = node.isExternal;
    writeByte(insideExternalLibrary ? 1 : 0);
    writeStringReference(node.name ?? '');
    writeStringReference('${node.importUri}');
    // TODO(jensj): We save (almost) the same URI twice.
    writeUriReference(node.fileUri ?? '');
    writeNodeList(node.classes);
    writeNodeList(node.fields);
    writeNodeList(node.procedures);
  }

  void writeAnnotation(Expression annotation) {
    _variableIndexer ??= new VariableIndexer();
    _variableIndexer.build(annotation);
    writeNode(annotation);
  }

  void writeAnnotationList(List<Expression> annotations) {
    writeList(annotations, writeAnnotation);
  }

  visitClass(Class node) {
    int flags = node.isAbstract ? 1 : 0;
    if (node.level == ClassLevel.Type) {
      flags |= 0x2;
    }
    if (node.isMixinApplication) {
      writeByte(Tag.MixinClass);
      writeByte(flags);
      writeStringReference(node.name ?? '');
      writeUriReference(node.fileUri ?? '');
      writeAnnotationList(node.annotations);
      _typeParameterIndexer.push(node.typeParameters);
      writeNodeList(node.typeParameters);
      writeNode(node.supertype);
      writeNode(node.mixedInType);
      writeNodeList(node.implementedTypes);
      writeNodeList(node.constructors);
      _typeParameterIndexer.pop(node.typeParameters);
    } else {
      writeByte(Tag.NormalClass);
      writeByte(flags);
      writeStringReference(node.name ?? '');
      writeUriReference(node.fileUri ?? '');
      writeAnnotationList(node.annotations);
      _typeParameterIndexer.push(node.typeParameters);
      writeNodeList(node.typeParameters);
      writeOptionalNode(node.supertype);
      writeNodeList(node.implementedTypes);
      writeNodeList(node.fields);
      writeNodeList(node.constructors);
      writeNodeList(node.procedures);
      _typeParameterIndexer.pop(node.typeParameters);
    }
  }

  static final Name _emptyName = new Name('');

  visitConstructor(Constructor node) {
    _variableIndexer = new VariableIndexer()..build(node);
    writeByte(Tag.Constructor);
    writeByte(node.flags);
    writeName(node.name ?? _emptyName);
    writeAnnotationList(node.annotations);
    assert(node.function.typeParameters.isEmpty);
    writeNode(node.function);
    writeNodeList(node.initializers);
  }

  visitProcedure(Procedure node) {
    _variableIndexer = new VariableIndexer()..build(node);
    writeByte(Tag.Procedure);
    writeByte(node.kind.index);
    writeByte(node.flags);
    writeName(node.name ?? '');
    writeUriReference(node.fileUri ?? '');
    writeAnnotationList(node.annotations);
    writeOptionalNode(node.function);
  }

  visitField(Field node) {
    _variableIndexer = new VariableIndexer()..build(node);
    writeByte(Tag.Field);
    writeOffset(node);
    writeByte(node.flags);
    writeName(node.name ?? '');
    writeUriReference(node.fileUri ?? '');
    writeAnnotationList(node.annotations);
    writeNode(node.type);
    writeOptionalInferredValue(node.inferredValue);
    writeOptionalNode(node.initializer);
  }

  visitInvalidInitializer(InvalidInitializer node) {
    writeByte(Tag.InvalidInitializer);
  }

  visitFieldInitializer(FieldInitializer node) {
    writeByte(Tag.FieldInitializer);
    writeMemberReference(node.field);
    writeNode(node.value);
  }

  visitSuperInitializer(SuperInitializer node) {
    writeByte(Tag.SuperInitializer);
    writeMemberReference(node.target);
    writeNode(node.arguments);
  }

  visitRedirectingInitializer(RedirectingInitializer node) {
    writeByte(Tag.RedirectingInitializer);
    writeMemberReference(node.target);
    writeNode(node.arguments);
  }

  visitLocalInitializer(LocalInitializer node) {
    writeByte(Tag.LocalInitializer);
    writeVariableDeclaration(node.variable);
  }

  visitFunctionNode(FunctionNode node) {
    assert(_variableIndexer != null);
    var oldLabels = _labelIndexer;
    _labelIndexer = new LabelIndexer()..build(node);
    var oldCases = _switchCaseIndexer;
    _switchCaseIndexer = new SwitchCaseIndexer()..build(node);
    // Note: FunctionNode has no tag.
    _typeParameterIndexer.push(node.typeParameters);
    writeByte(node.asyncMarker.index);
    writeNodeList(node.typeParameters);
    writeUInt30(node.requiredParameterCount);
    writeVariableDeclarationList(node.positionalParameters);
    writeVariableDeclarationList(node.namedParameters);
    writeNode(node.returnType);
    writeOptionalInferredValue(node.inferredReturnValue);
    writeOptionalNode(node.body);
    _labelIndexer = oldLabels;
    _switchCaseIndexer = oldCases;
    _typeParameterIndexer.pop(node.typeParameters);
  }

  visitInvalidExpression(InvalidExpression node) {
    writeByte(Tag.InvalidExpression);
  }

  visitVariableGet(VariableGet node) {
    assert(_variableIndexer != null);
    int index = _variableIndexer[node.variable];
    assert(index != null);
    if (index & Tag.SpecializedPayloadMask == index &&
        node.promotedType == null) {
      writeByte(Tag.SpecializedVariableGet + index);
    } else {
      writeByte(Tag.VariableGet);
      writeUInt30(_variableIndexer[node.variable]);
      writeOptionalNode(node.promotedType);
    }
  }

  visitVariableSet(VariableSet node) {
    assert(_variableIndexer != null);
    int index = _variableIndexer[node.variable];
    if (index & Tag.SpecializedPayloadMask == index) {
      writeByte(Tag.SpecializedVariableSet + index);
      writeNode(node.value);
    } else {
      writeByte(Tag.VariableSet);
      writeUInt30(_variableIndexer[node.variable]);
      writeNode(node.value);
    }
  }

  visitPropertyGet(PropertyGet node) {
    writeByte(Tag.PropertyGet);
    writeOffset(node);
    writeNode(node.receiver);
    writeName(node.name);
    writeMemberReference(node.interfaceTarget, allowNull: true);
  }

  visitPropertySet(PropertySet node) {
    writeByte(Tag.PropertySet);
    writeOffset(node);
    writeNode(node.receiver);
    writeName(node.name);
    writeNode(node.value);
    writeMemberReference(node.interfaceTarget, allowNull: true);
  }

  visitSuperPropertyGet(SuperPropertyGet node) {
    writeByte(Tag.SuperPropertyGet);
    writeName(node.name);
    writeMemberReference(node.interfaceTarget, allowNull: true);
  }

  visitSuperPropertySet(SuperPropertySet node) {
    writeByte(Tag.SuperPropertySet);
    writeName(node.name);
    writeNode(node.value);
    writeMemberReference(node.interfaceTarget, allowNull: true);
  }

  visitDirectPropertyGet(DirectPropertyGet node) {
    writeByte(Tag.DirectPropertyGet);
    writeNode(node.receiver);
    writeMemberReference(node.target);
  }

  visitDirectPropertySet(DirectPropertySet node) {
    writeByte(Tag.DirectPropertySet);
    writeNode(node.receiver);
    writeMemberReference(node.target);
    writeNode(node.value);
  }

  visitStaticGet(StaticGet node) {
    writeByte(Tag.StaticGet);
    writeOffset(node);
    writeMemberReference(node.target);
  }

  visitStaticSet(StaticSet node) {
    writeByte(Tag.StaticSet);
    writeMemberReference(node.target);
    writeNode(node.value);
  }

  visitMethodInvocation(MethodInvocation node) {
    writeByte(Tag.MethodInvocation);
    writeOffset(node);
    writeNode(node.receiver);
    writeName(node.name);
    writeNode(node.arguments);
    writeMemberReference(node.interfaceTarget, allowNull: true);
  }

  visitSuperMethodInvocation(SuperMethodInvocation node) {
    writeByte(Tag.SuperMethodInvocation);
    writeOffset(node);
    writeName(node.name);
    writeNode(node.arguments);
    writeMemberReference(node.interfaceTarget, allowNull: true);
  }

  visitDirectMethodInvocation(DirectMethodInvocation node) {
    writeByte(Tag.DirectMethodInvocation);
    writeNode(node.receiver);
    writeMemberReference(node.target);
    writeNode(node.arguments);
  }

  visitStaticInvocation(StaticInvocation node) {
    writeByte(node.isConst ? Tag.ConstStaticInvocation : Tag.StaticInvocation);
    writeOffset(node);
    writeMemberReference(node.target);
    writeNode(node.arguments);
  }

  visitConstructorInvocation(ConstructorInvocation node) {
    writeByte(node.isConst
        ? Tag.ConstConstructorInvocation
        : Tag.ConstructorInvocation);
    writeOffset(node);
    writeMemberReference(node.target);
    writeNode(node.arguments);
  }

  visitArguments(Arguments node) {
    writeNodeList(node.types);
    writeNodeList(node.positional);
    writeNodeList(node.named);
  }

  visitNamedExpression(NamedExpression node) {
    writeStringReference(node.name);
    writeNode(node.value);
  }

  visitNot(Not node) {
    writeByte(Tag.Not);
    writeNode(node.operand);
  }

  int logicalOperatorIndex(String operator) {
    switch (operator) {
      case '&&':
        return 0;
      case '||':
        return 1;
    }
    throw 'Not a logical operator: $operator';
  }

  visitLogicalExpression(LogicalExpression node) {
    writeByte(Tag.LogicalExpression);
    writeNode(node.left);
    writeByte(logicalOperatorIndex(node.operator));
    writeNode(node.right);
  }

  visitConditionalExpression(ConditionalExpression node) {
    writeByte(Tag.ConditionalExpression);
    writeNode(node.condition);
    writeNode(node.then);
    writeNode(node.otherwise);
    writeOptionalNode(node.staticType);
  }

  visitStringConcatenation(StringConcatenation node) {
    writeByte(Tag.StringConcatenation);
    writeNodeList(node.expressions);
  }

  visitIsExpression(IsExpression node) {
    writeByte(Tag.IsExpression);
    writeNode(node.operand);
    writeNode(node.type);
  }

  visitAsExpression(AsExpression node) {
    writeByte(Tag.AsExpression);
    writeNode(node.operand);
    writeNode(node.type);
  }

  visitStringLiteral(StringLiteral node) {
    writeByte(Tag.StringLiteral);
    writeStringReference(node.value);
  }

  visitIntLiteral(IntLiteral node) {
    int value = node.value;
    int biasedValue = value + Tag.SpecializedIntLiteralBias;
    if (biasedValue >= 0 &&
        biasedValue & Tag.SpecializedPayloadMask == biasedValue) {
      writeByte(Tag.SpecializedIntLiteral + biasedValue);
    } else if (value.abs() >> 30 == 0) {
      if (value < 0) {
        writeByte(Tag.NegativeIntLiteral);
        writeUInt30(-value);
      } else {
        writeByte(Tag.PositiveIntLiteral);
        writeUInt30(value);
      }
    } else {
      // TODO: Pick a better format for big int literals.
      writeByte(Tag.BigIntLiteral);
      writeStringReference('${node.value}');
    }
  }

  visitDoubleLiteral(DoubleLiteral node) {
    // TODO: Pick a better format for double literals.
    writeByte(Tag.DoubleLiteral);
    writeStringReference('${node.value}');
  }

  visitBoolLiteral(BoolLiteral node) {
    writeByte(node.value ? Tag.TrueLiteral : Tag.FalseLiteral);
  }

  visitNullLiteral(NullLiteral node) {
    writeByte(Tag.NullLiteral);
  }

  visitSymbolLiteral(SymbolLiteral node) {
    writeByte(Tag.SymbolLiteral);
    writeStringReference(node.value);
  }

  visitTypeLiteral(TypeLiteral node) {
    writeByte(Tag.TypeLiteral);
    writeNode(node.type);
  }

  visitThisExpression(ThisExpression node) {
    writeByte(Tag.ThisExpression);
  }

  visitRethrow(Rethrow node) {
    writeByte(Tag.Rethrow);
  }

  visitThrow(Throw node) {
    writeByte(Tag.Throw);
    writeOffset(node);
    writeNode(node.expression);
  }

  visitListLiteral(ListLiteral node) {
    writeByte(node.isConst ? Tag.ConstListLiteral : Tag.ListLiteral);
    writeNode(node.typeArgument);
    writeNodeList(node.expressions);
  }

  visitMapLiteral(MapLiteral node) {
    writeByte(node.isConst ? Tag.ConstMapLiteral : Tag.MapLiteral);
    writeNode(node.keyType);
    writeNode(node.valueType);
    writeNodeList(node.entries);
  }

  visitMapEntry(MapEntry node) {
    // Note: there is no tag on MapEntry
    writeNode(node.key);
    writeNode(node.value);
  }

  visitAwaitExpression(AwaitExpression node) {
    writeByte(Tag.AwaitExpression);
    writeNode(node.operand);
  }

  visitFunctionExpression(FunctionExpression node) {
    writeByte(Tag.FunctionExpression);
    writeNode(node.function);
  }

  visitLet(Let node) {
    writeByte(Tag.Let);
    writeVariableDeclaration(node.variable);
    writeNode(node.body);
  }

  writeStatementOrEmpty(Statement node) {
    if (node == null) {
      writeByte(Tag.EmptyStatement);
    } else {
      writeNode(node);
    }
  }

  visitInvalidStatement(InvalidStatement node) {
    writeByte(Tag.InvalidStatement);
  }

  visitExpressionStatement(ExpressionStatement node) {
    writeByte(Tag.ExpressionStatement);
    writeNode(node.expression);
  }

  visitBlock(Block node) {
    writeByte(Tag.Block);
    writeNodeList(node.statements);
  }

  visitEmptyStatement(EmptyStatement node) {
    writeByte(Tag.EmptyStatement);
  }

  visitAssertStatement(AssertStatement node) {
    writeByte(Tag.AssertStatement);
    writeNode(node.condition);
    writeOptionalNode(node.message);
  }

  visitLabeledStatement(LabeledStatement node) {
    writeByte(Tag.LabeledStatement);
    writeNode(node.body);
  }

  visitBreakStatement(BreakStatement node) {
    writeByte(Tag.BreakStatement);
    writeUInt30(_labelIndexer[node.target]);
  }

  visitWhileStatement(WhileStatement node) {
    writeByte(Tag.WhileStatement);
    writeNode(node.condition);
    writeNode(node.body);
  }

  visitDoStatement(DoStatement node) {
    writeByte(Tag.DoStatement);
    writeNode(node.body);
    writeNode(node.condition);
  }

  visitForStatement(ForStatement node) {
    writeByte(Tag.ForStatement);
    writeVariableDeclarationList(node.variables);
    writeOptionalNode(node.condition);
    writeNodeList(node.updates);
    writeNode(node.body);
  }

  visitForInStatement(ForInStatement node) {
    writeByte(node.isAsync ? Tag.AsyncForInStatement : Tag.ForInStatement);
    writeVariableDeclaration(node.variable);
    writeNode(node.iterable);
    writeNode(node.body);
  }

  visitSwitchStatement(SwitchStatement node) {
    writeByte(Tag.SwitchStatement);
    writeNode(node.expression);
    writeNodeList(node.cases);
  }

  visitSwitchCase(SwitchCase node) {
    // Note: there is no tag on SwitchCase.
    writeNodeList(node.expressions);
    writeByte(node.isDefault ? 1 : 0);
    writeNode(node.body);
  }

  visitContinueSwitchStatement(ContinueSwitchStatement node) {
    writeByte(Tag.ContinueSwitchStatement);
    writeUInt30(_switchCaseIndexer[node.target]);
  }

  visitIfStatement(IfStatement node) {
    writeByte(Tag.IfStatement);
    writeNode(node.condition);
    writeNode(node.then);
    writeStatementOrEmpty(node.otherwise);
  }

  visitReturnStatement(ReturnStatement node) {
    writeByte(Tag.ReturnStatement);
    writeOptionalNode(node.expression);
  }

  visitTryCatch(TryCatch node) {
    writeByte(Tag.TryCatch);
    writeNode(node.body);
    writeNodeList(node.catches);
  }

  visitCatch(Catch node) {
    // Note: there is no tag on Catch.
    writeNode(node.guard);
    writeOptionalVariableDeclaration(node.exception);
    writeOptionalVariableDeclaration(node.stackTrace);
    writeNode(node.body);
  }

  visitTryFinally(TryFinally node) {
    writeByte(Tag.TryFinally);
    writeNode(node.body);
    writeNode(node.finalizer);
  }

  visitYieldStatement(YieldStatement node) {
    writeByte(Tag.YieldStatement);
    writeByte(node.flags);
    writeNode(node.expression);
  }

  visitVariableDeclaration(VariableDeclaration node) {
    writeByte(Tag.VariableDeclaration);
    writeVariableDeclaration(node);
  }

  void writeVariableDeclaration(VariableDeclaration node) {
    writeByte(node.flags);
    writeStringReference(node.name ?? '');
    writeNode(node.type);
    writeOptionalInferredValue(node.inferredValue);
    writeOptionalNode(node.initializer);
  }

  void writeVariableDeclarationList(List<VariableDeclaration> nodes) {
    writeList(nodes, writeVariableDeclaration);
  }

  void writeOptionalVariableDeclaration(VariableDeclaration node) {
    if (node == null) {
      writeByte(Tag.Nothing);
    } else {
      writeByte(Tag.Something);
      writeVariableDeclaration(node);
    }
  }

  visitFunctionDeclaration(FunctionDeclaration node) {
    writeByte(Tag.FunctionDeclaration);
    writeVariableDeclaration(node.variable);
    writeNode(node.function);
  }

  visitBottomType(BottomType node) {
    writeByte(Tag.BottomType);
  }

  visitInvalidType(InvalidType node) {
    writeByte(Tag.InvalidType);
  }

  visitDynamicType(DynamicType node) {
    writeByte(Tag.DynamicType);
  }

  visitVoidType(VoidType node) {
    writeByte(Tag.VoidType);
  }

  visitInterfaceType(InterfaceType node) {
    if (node.typeArguments.isEmpty) {
      writeByte(Tag.SimpleInterfaceType);
      writeClassReference(node.classNode);
    } else {
      writeByte(Tag.InterfaceType);
      writeClassReference(node.classNode);
      writeNodeList(node.typeArguments);
    }
  }

  visitSupertype(Supertype node) {
    if (node.typeArguments.isEmpty) {
      writeByte(Tag.SimpleInterfaceType);
      writeClassReference(node.classNode);
    } else {
      writeByte(Tag.InterfaceType);
      writeClassReference(node.classNode);
      writeNodeList(node.typeArguments);
    }
  }

  visitFunctionType(FunctionType node) {
    if (node.requiredParameterCount == node.positionalParameters.length &&
        node.typeParameters.isEmpty &&
        node.namedParameters.isEmpty) {
      writeByte(Tag.SimpleFunctionType);
      writeNodeList(node.positionalParameters);
      writeNode(node.returnType);
    } else {
      writeByte(Tag.FunctionType);
      _typeParameterIndexer.push(node.typeParameters);
      writeNodeList(node.typeParameters);
      writeUInt30(node.requiredParameterCount);
      writeNodeList(node.positionalParameters);
      writeList(node.namedParameters.keys.toList(), (String name) {
        writeStringReference(name);
        writeNode(node.namedParameters[name]);
      });
      writeNode(node.returnType);
      _typeParameterIndexer.pop(node.typeParameters);
    }
  }

  visitTypeParameterType(TypeParameterType node) {
    writeByte(Tag.TypeParameterType);
    writeUInt30(_typeParameterIndexer[node.parameter]);
  }

  visitTypeParameter(TypeParameter node) {
    writeStringReference(node.name ?? '');
    writeNode(node.bound);
  }

  defaultNode(Node node) {
    throw 'Unsupported node: $node';
  }
}

class VariableIndexer extends RecursiveVisitor {
  final Map<VariableDeclaration, int> index = <VariableDeclaration, int>{};
  int stackHeight = 0;

  void build(TreeNode node) => node.accept(this);

  visitConstructor(Constructor node) {
    node.function.accept(this);
    // Keep parameters in scope when traversing initializers.
    stackHeight = node.function.positionalParameters.length +
        node.function.namedParameters.length;
    for (var init in node.initializers) {
      init.accept(this);
    }
    stackHeight = 0;
  }

  visitFunctionNode(FunctionNode node) {
    int frame = stackHeight;
    node.visitChildren(this);
    stackHeight = frame;
  }

  visitBlock(Block node) {
    int frame = stackHeight;
    node.visitChildren(this);
    stackHeight = frame;
  }

  visitLet(Let node) {
    int frame = stackHeight;
    node.visitChildren(this);
    stackHeight = frame;
  }

  visitForInStatement(ForInStatement node) {
    int frame = stackHeight;
    node.visitChildren(this);
    stackHeight = frame;
  }

  visitForStatement(ForStatement node) {
    int frame = stackHeight;
    node.visitChildren(this);
    stackHeight = frame;
  }

  visitCatch(Catch node) {
    int frame = stackHeight;
    node.visitChildren(this);
    stackHeight = frame;
  }

  visitVariableDeclaration(VariableDeclaration node) {
    node.visitChildren(this);
    assert(!index.containsKey(node));
    index[node] = stackHeight;
    ++stackHeight;
  }

  int operator [](VariableDeclaration node) => index[node];
}

class LabelIndexer extends RecursiveVisitor {
  final Map<LabeledStatement, int> index = <LabeledStatement, int>{};
  int stackHeight = 0;

  void build(FunctionNode node) => node.visitChildren(this);

  visitFunctionNode(FunctionNode node) {
    // Inhibit traversal into nested functions.
    // The client must create a separate label indexer for the
    // nested function.
  }

  visitLabeledStatement(LabeledStatement node) {
    index[node] = stackHeight;
    ++stackHeight;
    node.visitChildren(this);
    --stackHeight;
  }

  int operator [](LabeledStatement node) => index[node];
}

class SwitchCaseIndexer extends RecursiveVisitor {
  final Map<SwitchCase, int> index = <SwitchCase, int>{};
  int stackHeight = 0;

  void build(FunctionNode node) => node.visitChildren(this);

  visitFunctionNode(FunctionNode node) {
    // Inhibit traversal into nested functions.
    // The client must create a separate case indexer for the
    // nested function.
  }

  visitSwitchStatement(SwitchStatement node) {
    int oldHeight = stackHeight;
    for (var caseNode in node.cases) {
      index[caseNode] = stackHeight;
      ++stackHeight;
    }
    node.visitChildren(this);
    stackHeight = oldHeight;
  }

  int operator [](SwitchCase node) => index[node];
}

/// The type parameter indexer works differently from the other indexers because
/// type parameters can be bound inside DartTypes, which can be shared by the
/// in-memory representation (but not the binary form) and the index depends on
/// the use site.
class TypeParameterIndexer {
  final Map<TypeParameter, int> index = <TypeParameter, int>{};
  int stackHeight = 0;

  void push(List<TypeParameter> typeParameters) {
    for (var parameter in typeParameters) {
      index[parameter] = stackHeight;
      ++stackHeight;
    }
  }

  void pop(List<TypeParameter> typeParameters) {
    stackHeight -= typeParameters.length;
  }

  int operator [](TypeParameter parameter) => index[parameter];
}

class StringTableEntry implements Comparable<StringTableEntry> {
  final String value;
  int frequency = 0;

  StringTableEntry(this.value);

  int compareTo(StringTableEntry other) => other.frequency - frequency;
}

class StringIndexer extends RecursiveVisitor<Null> {
  final List<StringTableEntry> entries = <StringTableEntry>[];
  final LinkedHashMap<String, int> index = new LinkedHashMap<String, int>();

  StringIndexer() {
    put('');
  }

  int get numberOfStrings => index.length;

  void build(Node node) {
    node.accept(this);
    entries.sort();
    for (int i = 0; i < entries.length; ++i) {
      index[entries[i].value] = i;
    }
  }

  void put(String string) {
    int i = index.putIfAbsent(string, () {
      entries.add(new StringTableEntry(string));
      return index.length;
    });
    ++entries[i].frequency;
  }

  void putOptional(String string) {
    if (string != null) {
      put(string);
    }
  }

  int operator [](String string) => index[string];

  void addLibraryImports(LibraryImportTable imports) {
    imports.importPaths.forEach(put);
  }

  visitName(Name node) {
    put(node.name);
  }

  visitLibrary(Library node) {
    putOptional(node.name);
    put('${node.importUri}');
    node.visitChildren(this);
  }

  visitClass(Class node) {
    putOptional(node.name);
    node.visitChildren(this);
  }

  visitNamedExpression(NamedExpression node) {
    put(node.name);
    node.visitChildren(this);
  }

  visitStringLiteral(StringLiteral node) {
    put(node.value);
  }

  visitIntLiteral(IntLiteral node) {
    if (node.value.abs() >> 30 != 0) {
      put('${node.value}');
    }
  }

  visitDoubleLiteral(DoubleLiteral node) {
    put('${node.value}');
  }

  visitSymbolLiteral(SymbolLiteral node) {
    put(node.value);
  }

  visitVariableDeclaration(VariableDeclaration node) {
    putOptional(node.name);
    node.visitChildren(this);
  }

  visitFunctionType(FunctionType node) {
    node.namedParameters.keys.forEach(put);
    node.visitChildren(this);
  }

  visitTypeParameter(TypeParameter node) {
    putOptional(node.name);
    node.visitChildren(this);
  }
}

/// Computes and stores the index of a library, class, or member within its
/// parent list.
class GlobalIndexer extends TreeVisitor {
  final Map<TreeNode, int> indices = <TreeNode, int>{};

  void buildIndexForContainer(TreeNode libraryOrClass) {
    libraryOrClass.accept(this);
  }

  void buildIndexForList(List<TreeNode> list) {
    for (int i = 0; i < list.length; ++i) {
      TreeNode child = list[i];
      if (child != null) {
        indices[child] = i;
      }
    }
  }

  visitProgram(Program node) {
    buildIndexForList(node.libraries);
  }

  visitLibrary(Library node) {
    buildIndexForList(node.classes);
    buildIndexForList(node.fields);
    buildIndexForList(node.procedures);
  }

  visitClass(Class node) {
    buildIndexForList(node.fields);
    buildIndexForList(node.constructors);
    buildIndexForList(node.procedures);
  }

  int operator [](TreeNode memberOrLibraryOrClass) {
    var node = memberOrLibraryOrClass;
    assert(node is Member || node is Library || node is Class);
    int index = indices[node];
    if (index == null) {
      buildIndexForContainer(node.parent);
      return indices[node];
    } else {
      return index;
    }
  }
}

/// Puts a buffer in front of a [Sink<List<int>>].
class BufferedSink {
  static const int SIZE = 100000;
  static const int SMALL = 10000;
  final Sink<List<int>> _sink;
  Uint8List _buffer = new Uint8List(SIZE);
  int length = 0;

  BufferedSink(this._sink);

  void addByte(int byte) {
    _buffer[length++] = byte;
    if (length == SIZE) {
      _sink.add(_buffer);
      _buffer = new Uint8List(SIZE);
      length = 0;
    }
  }

  void addBytes(List<int> bytes) {
    // Avoid copying a large buffer into the another large buffer. Also, if
    // the bytes buffer is too large to fit in our own buffer, just emit both.
    if (length + bytes.length < SIZE &&
        (bytes.length < SMALL || length < SMALL)) {
      if (length == 0) {
        _sink.add(bytes);
      } else {
        _buffer.setRange(length, length + bytes.length, bytes);
        length += bytes.length;
      }
    } else if (bytes.length < SMALL) {
      // Flush as much as we can in the current buffer.
      _buffer.setRange(length, SIZE, bytes);
      _sink.add(_buffer);
      // Copy over the remainder into a new buffer. It is guaranteed to fit
      // because the input byte array is small.
      int alreadyEmitted = SIZE - length;
      int remainder = bytes.length - alreadyEmitted;
      _buffer = new Uint8List(SIZE);
      _buffer.setRange(0, remainder, bytes, alreadyEmitted);
      length = remainder;
    } else {
      _sink.add(_buffer.sublist(0, length));
      _sink.add(bytes);
      _buffer = new Uint8List(SIZE);
      length = 0;
    }
  }

  void flush() {
    _sink.add(_buffer.sublist(0, length));
    _buffer = new Uint8List(SIZE);
    length = 0;
  }

  void flushAndDestroy() {
    _sink.add(_buffer.sublist(0, length));
  }
}
