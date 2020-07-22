import 'package:analyzer/dart/element/element.dart';
import 'package:build/build.dart';
import 'package:source_gen/source_gen.dart';

import 'decode_helper.dart' show CreateFactoryResult;
import 'helper_core.dart';
import 'json_literal_generator.dart';
import 'unsupported_type_error.dart';
import 'utils.dart';

abstract class MergeHelper implements HelperCore {
  static const _mergeWithInstanceJsonParamName = 'instance';

  CreateFactoryResult createMergeWithJson(
    Map<String, FieldElement> accessibleFields,
    Map<String, String> unavailableReasons,
  ) {
    assert(config.createMergeWithJson);
    final buffer = StringBuffer();

    final mapType = config.anyMap ? 'Map' : 'Map<String, dynamic>';
    buffer.write('void '
        '${prefix}MergeWithJson${genericClassArgumentsImpl(true)}'
        '($targetClassReference $_mergeWithInstanceJsonParamName, '
        '$mapType json) {\n');

    String mergeFun(String paramOrFieldName, {ParameterElement ctorParam}) =>
        _mergeForField(accessibleFields[paramOrFieldName],
            ctorParam: ctorParam);

    final data = _writeConstructorInvocation(
        element,
        accessibleFields.keys,
        accessibleFields.values
            .where((fe) => !fe.isFinal)
            .map((fe) => fe.name)
            .toList(),
        unavailableReasons,
        mergeFun);

    buffer..write('''
  $_mergeWithInstanceJsonParamName''');

    for (final field in data.fieldsToSet) {
      buffer
        ..writeln()
        ..write('    ..$field = ')
        ..write(mergeFun(field));
    }

    buffer..writeln(';\n}')..writeln();

    return CreateFactoryResult(buffer.toString(), data.usedCtorParamsAndFields);
  }

  String _mergeForField(
    FieldElement field, {
    ParameterElement ctorParam,
    bool checkedProperty,
  }) {
    checkedProperty ??= false;
    final jsonKeyName = safeNameAccess(field);
    final targetType = ctorParam?.type ?? field.type;
    final contextHelper = getHelperContext(field);

    String value;
    try {
      final Object object =
          contextHelper.merge(targetType, 'json[$jsonKeyName]') ??
              contextHelper.deserialize(targetType, 'json[$jsonKeyName]');

      value = object.toString();
    } on UnsupportedTypeError catch (e) // ignore: avoid_catching_errors
    {
      throw createInvalidGenerationError('mergeWithJson', field, e);
    }

    final defaultValue = '$_mergeWithInstanceJsonParamName.${field.name}';

    value = '$value ?? $defaultValue';

    return value;
  }
}

/// [availableConstructorParameters] is checked to see if it is available. If
/// [availableConstructorParameters] does not contain the parameter name,
/// an [UnsupportedError] is thrown.
///
/// To improve the error details, [unavailableReasons] is checked for the
/// unavailable constructor parameter. If the value is not `null`, it is
/// included in the [UnsupportedError] message.
///
/// [writableFields] are also populated, but only if they have not already
/// been defined by a constructor parameter with the same name.
_ConstructorData _writeConstructorInvocation(
  ClassElement classElement,
  Iterable<String> availableConstructorParameters,
  Iterable<String> writableFields,
  Map<String, String> unavailableReasons,
  String Function(String paramOrFieldName, {ParameterElement ctorParam})
      deserializeForField,
) {
  final className = classElement.name;

  final ctor = classElement.unnamedConstructor;
  if (ctor == null) {
    // TODO: support using another ctor - google/json_serializable.dart#50
    throw InvalidGenerationSourceError(
        'The class `$className` has no default constructor.',
        element: classElement);
  }

  final usedCtorParamsAndFields = <String>{};
  final constructorArguments = <ParameterElement>[];
  final namedConstructorArguments = <ParameterElement>[];

  for (final arg in ctor.parameters) {
    if (!availableConstructorParameters.contains(arg.name)) {
      if (arg.isNotOptional) {
        var msg = 'Cannot populate the required constructor '
            'argument: ${arg.name}.';

        final additionalInfo = unavailableReasons[arg.name];

        if (additionalInfo != null) {
          msg = '$msg $additionalInfo';
        }

        throw InvalidGenerationSourceError(msg, element: ctor);
      }

      continue;
    }

    // TODO: validate that the types match!
    if (arg.isNamed) {
      namedConstructorArguments.add(arg);
    } else {
      constructorArguments.add(arg);
    }
    usedCtorParamsAndFields.add(arg.name);
  }

  // fields that aren't already set by the constructor and that aren't final
  final remainingFieldsForInvocationBody =
      writableFields.toSet().difference(usedCtorParamsAndFields);

  final buffer = StringBuffer()
    ..write('$className${genericClassArguments(classElement, false)}(');
  if (constructorArguments.isNotEmpty) {
    buffer
      ..writeln()
      ..writeAll(constructorArguments.map((paramElement) {
        final content =
            deserializeForField(paramElement.name, ctorParam: paramElement);
        return '      $content,\n';
      }));
  }
  if (namedConstructorArguments.isNotEmpty) {
    buffer
      ..writeln()
      ..writeAll(namedConstructorArguments.map((paramElement) {
        final value =
            deserializeForField(paramElement.name, ctorParam: paramElement);
        return '      ${paramElement.name}: $value,\n';
      }));
  }

  buffer.write(')');

  usedCtorParamsAndFields.addAll(remainingFieldsForInvocationBody);

  return _ConstructorData(buffer.toString(), remainingFieldsForInvocationBody,
      usedCtorParamsAndFields);
}

class _ConstructorData {
  final String content;
  final Set<String> fieldsToSet;
  final Set<String> usedCtorParamsAndFields;

  _ConstructorData(
    this.content,
    this.fieldsToSet,
    this.usedCtorParamsAndFields,
  );
}
