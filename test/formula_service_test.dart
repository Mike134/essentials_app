// Proves FormulaService -- the glue between the pure expression evaluator
// and real rows/FieldConfig metadata (Essentials v2 Phase 2 build order
// step 6). Pure Dart, no DatabaseHelper/Flutter involved -- run with
// `flutter test test/formula_service_test.dart`.
import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/formula/formula_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A formula field shaped exactly as `SchemaRegistry._buildField` would
/// build it -- readOnly, and FieldType.real unless the result is text.
FieldConfig formulaField(
  String column,
  String expression, {
  String? resultType,
  int? decimals,
}) => FieldConfig(
  column: column,
  label: column,
  type: resultType == FormulaService.resultTypeText ? FieldType.text : FieldType.real,
  readOnly: true,
  format: FormulaService.formatName,
  options: {'expression': expression, 'resultType': ?resultType, 'decimals': ?decimals},
);

/// A non-formula field. [type] defaults to the FieldType.text that
/// `SchemaRegistry` gives every format it doesn't recognize -- which is
/// exactly the case that matters for currency/percentage/rating.
FieldConfig plainField(String column, String format, {FieldType type = FieldType.text}) =>
    FieldConfig(column: column, label: column, type: type, format: format);

void main() {
  group('computeAll', () {
    test('computes a formula from other fields in the row', () {
      final fields = [
        plainField('cost', 'real', type: FieldType.real),
        plainField('quantity', 'integer', type: FieldType.integer),
        formulaField('total', '{cost} * {quantity}'),
      ];
      final result = FormulaService.computeAll(fields, {'cost': '4.5', 'quantity': '3'});
      expect(result['total'], 13.5);
    });

    test('rounds a numeric result to options.decimals, killing float noise', () {
      final fields = [
        plainField('cost', 'real', type: FieldType.real),
        formulaField('third', '{cost} / 3'),
      ];
      // 10/3 is 3.3333333333333335 in raw floating point.
      expect(FormulaService.computeAll(fields, {'cost': '10'})['third'], 3.33);
    });

    test('honors an explicit decimals option', () {
      final fields = [
        plainField('cost', 'real', type: FieldType.real),
        formulaField('third', '{cost} / 3', decimals: 4),
      ];
      expect(FormulaService.computeAll(fields, {'cost': '10'})['third'], 3.3333);
    });

    test('a missing input yields null rather than a wrong number', () {
      final fields = [
        plainField('cost', 'real', type: FieldType.real),
        formulaField('doubled', '{cost} * 2'),
      ];
      expect(FormulaService.computeAll(fields, {'cost': null})['doubled'], isNull);
    });

    test('a malformed expression yields null instead of throwing', () {
      final fields = [formulaField('broken', 'cost * 2')]; // missing braces
      expect(FormulaService.computeAll(fields, const {})['broken'], isNull);
    });

    test('a field with no expression at all yields null', () {
      const field = FieldConfig(
        column: 'empty',
        label: 'Empty',
        readOnly: true,
        format: FormulaService.formatName,
      );
      expect(FormulaService.computeAll([field], const {})['empty'], isNull);
    });
  });

  group('field type resolution', () {
    // The subtle one: currency/percentage/rating are all unrecognized by
    // SchemaRegistry._formatToFieldType and so carry FieldType.text.
    // Without FormulaService's own format check they would compare and
    // multiply as text.
    test('currency resolves as a number despite carrying FieldType.text', () {
      final fields = [plainField('price', 'currency'), formulaField('twice', '{price} * 2')];
      expect(FormulaService.computeAll(fields, {'price': '19.99'})['twice'], 39.98);
    });

    test('percentage and rating resolve as numbers too', () {
      final fields = [
        plainField('rate', 'percentage'),
        plainField('stars', 'rating'),
        formulaField('mix', '{rate} * 100 + {stars}'),
      ];
      expect(FormulaService.computeAll(fields, {'rate': '0.15', 'stars': '4'})['mix'], 19.0);
    });

    test('a plain text field stays text, so numeric-looking codes compare literally', () {
      final fields = [
        plainField('code', 'text'),
        formulaField('isSeven', "IF({code} = '007', 'yes', 'no')", resultType: 'text'),
      ];
      // Coerced to a number this would be 7 == '007' -> false.
      expect(FormulaService.computeAll(fields, {'code': '007'})['isSeven'], 'yes');
    });

    test('a boolean field resolves to a real bool for IF', () {
      final fields = [
        plainField('active', 'boolean', type: FieldType.boolean),
        formulaField('label', "IF({active}, 'on', 'off')", resultType: 'text'),
      ];
      expect(FormulaService.computeAll(fields, {'active': 1})['label'], 'on');
      expect(FormulaService.computeAll(fields, {'active': 0})['label'], 'off');
    });

    test('a reference to something that is not a FieldConfig entry passes through', () {
      // `{id}` is the realistic case -- id is never a TableConfig.fields
      // entry, but is present in every row.
      final fields = [formulaField('echo', '{id} + 1')];
      expect(FormulaService.computeAll(fields, {'id': 41})['echo'], 42);
    });
  });

  group('chained formulas', () {
    test('a formula referencing another formula resolves recursively', () {
      final fields = [
        plainField('cost', 'real', type: FieldType.real),
        formulaField('subtotal', '{cost} * 2'),
        formulaField('total', '{subtotal} + 1'),
      ];
      final result = FormulaService.computeAll(fields, {'cost': '5'});
      expect(result['subtotal'], 10);
      expect(result['total'], 11);
    });

    test('order in the field list does not matter', () {
      // `total` declared before the `subtotal` it depends on.
      final fields = [
        formulaField('total', '{subtotal} + 1'),
        formulaField('subtotal', '{cost} * 2'),
        plainField('cost', 'real', type: FieldType.real),
      ];
      expect(FormulaService.computeAll(fields, {'cost': '5'})['total'], 11);
    });

    test('a text-result formula referenced by another stays text', () {
      final fields = [
        plainField('code', 'text'),
        formulaField('tag', "'#' || {code}", resultType: 'text'),
        formulaField('shout', "{tag} || '!'", resultType: 'text'),
      ];
      expect(FormulaService.computeAll(fields, {'code': 'abc'})['shout'], '#abc!');
    });

    test('a direct self-reference resolves to null rather than recursing forever', () {
      final fields = [formulaField('loop', '{loop} + 1')];
      expect(FormulaService.computeAll(fields, const {})['loop'], isNull);
    });

    test('an indirect cycle terminates too', () {
      final fields = [
        formulaField('a', '{b} + 1'),
        formulaField('b', '{a} + 1'),
      ];
      final result = FormulaService.computeAll(fields, const {});
      expect(result.containsKey('a'), isTrue);
      expect(result.containsKey('b'), isTrue);
    });
  });

  group('applyTo', () {
    test('returns the row untouched when the table has no formula fields', () {
      final fields = [plainField('name', 'text')];
      final row = {'id': 1, 'name': 'x'};
      expect(identical(FormulaService.applyTo(fields, row), row), isTrue);
    });

    test('merges computed values over the stored (always-NULL) column', () {
      final fields = [
        plainField('cost', 'real', type: FieldType.real),
        formulaField('doubled', '{cost} * 2'),
      ];
      // `doubled` is physically NULL on disk -- it is never written.
      final result = FormulaService.applyTo(fields, {'id': 7, 'cost': '5', 'doubled': null});
      expect(result['doubled'], 10);
      expect(result['id'], 7);
      expect(result['cost'], '5');
    });
  });

  group('computeAllForDisplay', () {
    test('formats a numeric result to the same decimals the grid shows', () {
      final fields = [
        plainField('cost', 'real', type: FieldType.real),
        formulaField('doubled', '{cost} * 2'),
      ];
      // Raw value is 10 (or 10.0); the grid renders "10.00", so the form
      // preview must too rather than showing "10" or "10.0".
      expect(FormulaService.computeAllForDisplay(fields, {'cost': '5'})['doubled'], '10.00');
    });

    test('honors an explicit decimals option', () {
      final fields = [
        plainField('cost', 'real', type: FieldType.real),
        formulaField('doubled', '{cost} * 2', decimals: 0),
      ];
      expect(FormulaService.computeAllForDisplay(fields, {'cost': '5'})['doubled'], '10');
    });

    test('a text result is not decimal-formatted', () {
      final fields = [
        plainField('code', 'text'),
        formulaField('tag', "'#' || {code}", resultType: 'text'),
      ];
      expect(FormulaService.computeAllForDisplay(fields, {'code': 'abc'})['tag'], '#abc');
    });

    test('null renders as empty text, not "null"', () {
      final fields = [formulaField('doubled', '{missing} * 2')];
      expect(FormulaService.computeAllForDisplay(fields, const {})['doubled'], '');
    });
  });

  group('helpers', () {
    test('isFormulaField / hasFormulaFields', () {
      expect(FormulaService.isFormulaField(formulaField('a', '1')), isTrue);
      expect(FormulaService.isFormulaField(plainField('a', 'text')), isFalse);
      expect(FormulaService.hasFormulaFields([plainField('a', 'text')]), isFalse);
      expect(
        FormulaService.hasFormulaFields([plainField('a', 'text'), formulaField('b', '1')]),
        isTrue,
      );
    });

    test('producesNumber defaults true, false only for an explicit text result', () {
      expect(FormulaService.producesNumber(formulaField('a', '1')), isTrue);
      expect(FormulaService.producesNumber(formulaField('a', '1', resultType: 'number')), isTrue);
      expect(FormulaService.producesNumber(formulaField('a', '1', resultType: 'text')), isFalse);
    });
  });
}
