// Proves the hand-rolled formula expression evaluator -- Essentials v2
// Phase 2 build order step 6 (see claude/essentials-v2-phase2-design.md's
// `formula` entry, and formula_expression.dart's own doc comment for why
// this is hand-rolled rather than a pub.dev package). Pure Dart, no
// DatabaseHelper/Flutter involved -- run with
// `flutter test test/formula_expression_test.dart`.
import 'package:essentials_app/util/formula/formula_expression.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Evaluates [source] against [fields], defaulting any unlisted
  /// reference to null (what a genuinely absent column resolves to).
  Object? evaluate(String source, [Map<String, Object?> fields = const {}]) =>
      FormulaExpression.parse(source).evaluate((name) => fields[name]);

  group('literals', () {
    test('numbers, including decimals and a leading dot', () {
      expect(evaluate('42'), 42);
      expect(evaluate('1.5'), 1.5);
      expect(evaluate('.5'), 0.5);
    });

    test('strings in either quote style', () {
      expect(evaluate("'hello'"), 'hello');
      expect(evaluate('"hello"'), 'hello');
    });

    test('doubled quotes escape, SQL-style', () {
      expect(evaluate("'it''s'"), "it's");
      expect(evaluate('"say ""hi"""'), 'say "hi"');
    });

    test('true/false/null keywords, case-insensitively', () {
      expect(evaluate('true'), isTrue);
      expect(evaluate('FALSE'), isFalse);
      expect(evaluate('Null'), isNull);
    });
  });

  group('field references', () {
    test('resolves through the supplied resolver', () {
      expect(evaluate('{cost}', {'cost': 19.99}), 19.99);
    });

    test('surrounding whitespace inside the braces is ignored', () {
      expect(evaluate('{ cost }', {'cost': 5}), 5);
    });

    test('an unresolved reference is null, not an error', () {
      expect(evaluate('{nope}'), isNull);
    });

    test('fieldNames reports every reference, for dependency analysis', () {
      final expression = FormulaExpression.parse('ROUND({a} * {b} + {a}, {c})');
      expect(expression.fieldNames, {'a', 'b', 'c'});
    });
  });

  group('arithmetic', () {
    test('the four operators', () {
      expect(evaluate('2 + 3'), 5);
      expect(evaluate('7 - 2'), 5);
      expect(evaluate('3 * 4'), 12);
      expect(evaluate('10 / 4'), 2.5);
    });

    test('multiplication binds tighter than addition', () {
      expect(evaluate('2 + 3 * 4'), 14);
    });

    test('parentheses override precedence', () {
      expect(evaluate('(2 + 3) * 4'), 20);
    });

    test('unary minus', () {
      expect(evaluate('-5'), -5);
      expect(evaluate('3 - -2'), 5);
      expect(evaluate('-{a}', {'a': 4}), -4);
    });

    test('numeric strings coerce, so a value typed into a text field still works', () {
      expect(evaluate('{a} * 2', {'a': '21'}), 42);
    });
  });

  group('null and divide-by-zero semantics', () {
    test('any null operand makes the whole arithmetic result null', () {
      expect(evaluate('{a} + 1'), isNull);
      expect(evaluate('1 + {a}'), isNull);
      expect(evaluate('{a} * {b} + 3', {'b': 2}), isNull);
    });

    test('division by zero is null, never Infinity or NaN', () {
      // Infinity/NaN would render as literal garbage in a grid cell.
      expect(evaluate('1 / 0'), isNull);
      expect(evaluate('{a} / {b}', {'a': 5, 'b': 0}), isNull);
    });

    test('a non-numeric operand is null rather than an error', () {
      expect(evaluate("'abc' * 2"), isNull);
    });
  });

  group('concatenation', () {
    test('joins values as text', () {
      expect(evaluate("'a' || 'b'"), 'ab');
      expect(evaluate("{first} || ' ' || {last}", {'first': 'Ada', 'last': 'L'}), 'Ada L');
    });

    test('null becomes empty -- deliberately NOT SQL-like', () {
      // In SQL `'a' || NULL` is NULL; blanking a whole display string
      // because one field is missing is never what is wanted here.
      expect(evaluate("'Total: ' || {missing}"), 'Total: ');
    });

    test('a whole-valued number loses its .0', () {
      expect(evaluate("{n} || ' items'", {'n': 4.0}), '4 items');
      expect(evaluate("{n} || ' items'", {'n': 4.5}), '4.5 items');
    });

    test('binds looser than arithmetic -- the documented divergence from SQLite', () {
      // SQLite would parse this as ('Total: ' || 1) + 2.
      expect(evaluate("'Total: ' || 1 + 2"), 'Total: 3');
    });

    test('binds tighter than comparison', () {
      expect(evaluate("'a' || 'b' = 'ab'"), isTrue);
    });
  });

  group('comparison', () {
    test('numeric comparison when both sides are numbers', () {
      expect(evaluate('2 < 10'), isTrue);
      // Lexically "2" > "10", so this proves it is not comparing as text.
      expect(evaluate('2 > 10'), isFalse);
    });

    test('lexical comparison when either side is not a number', () {
      expect(evaluate("'abc' = 'abc'"), isTrue);
      expect(evaluate("'abc' < 'abd'"), isTrue);
    });

    test('every operator spelling', () {
      expect(evaluate('1 = 1'), isTrue);
      expect(evaluate('1 == 1'), isTrue);
      expect(evaluate('1 != 2'), isTrue);
      expect(evaluate('1 <> 2'), isTrue);
      expect(evaluate('1 <= 1'), isTrue);
      expect(evaluate('1 >= 1'), isTrue);
    });

    test('a null operand yields null, which IF treats as false', () {
      expect(evaluate('{a} = 1'), isNull);
      expect(evaluate("IF({a} = 1, 'yes', 'no')"), 'no');
    });
  });

  group('functions', () {
    test('ROUND with and without a decimal-place argument', () {
      expect(evaluate('ROUND(3.7)'), 4);
      expect(evaluate('ROUND(3.14159, 2)'), 3.14);
      expect(evaluate('ROUND(2.5)'), 3);
    });

    test('ROUND to zero places returns a whole number, not 4.0', () {
      expect(evaluate('ROUND(3.7)'), isA<int>());
    });

    test('IF picks a branch on truthiness', () {
      expect(evaluate("IF(true, 'y', 'n')"), 'y');
      expect(evaluate("IF(false, 'y', 'n')"), 'n');
      expect(evaluate("IF(0, 'y', 'n')"), 'n');
      expect(evaluate("IF(3, 'y', 'n')"), 'y');
      expect(evaluate("IF('', 'y', 'n')"), 'n');
      expect(evaluate("IF('x', 'y', 'n')"), 'y');
      expect(evaluate("IF({missing}, 'y', 'n')"), 'n');
    });

    test('IF evaluates both branches eagerly, which divide-by-zero makes safe', () {
      // The usual reason to demand lazy evaluation is guarding division;
      // that guard is unnecessary here because 1/0 is null, not a throw.
      expect(evaluate('IF({q} = 0, 0, {t} / {q})', {'q': 0, 't': 10}), 0);
      expect(evaluate('IF({q} = 0, 0, {t} / {q})', {'q': 2, 't': 10}), 5);
    });

    test('ABS, COALESCE, MIN, MAX', () {
      expect(evaluate('ABS(-4)'), 4);
      expect(evaluate("COALESCE({a}, {b}, 'fallback')"), 'fallback');
      expect(evaluate("COALESCE({a}, 'second', 'third')"), 'second');
      expect(evaluate('MIN(3, 1, 2)'), 1);
      expect(evaluate('MAX(3, 1, 2)'), 3);
    });

    test('MIN/MAX are numeric-only and yield null on a non-number', () {
      expect(evaluate("MIN(1, 'abc')"), isNull);
    });

    test('function names are case-insensitive', () {
      expect(evaluate('round(3.7)'), 4);
      expect(evaluate("if(true, 1, 2)"), 1);
    });
  });

  group('parse errors', () {
    test('an unknown bare name suggests brace syntax -- the likely mistake', () {
      // Typing `cost * 2` instead of `{cost} * 2`.
      expect(
        () => FormulaExpression.parse('cost * 2'),
        throwsA(
          isA<FormulaParseException>().having((e) => e.message, 'message', contains('{cost}')),
        ),
      );
    });

    test('an empty formula', () {
      expect(() => FormulaExpression.parse('   '), throwsA(isA<FormulaParseException>()));
    });

    test('an unterminated text value', () {
      expect(() => FormulaExpression.parse("'abc"), throwsA(isA<FormulaParseException>()));
    });

    test('an unclosed field reference', () {
      expect(() => FormulaExpression.parse('{cost'), throwsA(isA<FormulaParseException>()));
    });

    test('an empty field reference', () {
      expect(() => FormulaExpression.parse('{}'), throwsA(isA<FormulaParseException>()));
    });

    test('a missing closing parenthesis', () {
      expect(() => FormulaExpression.parse('(1 + 2'), throwsA(isA<FormulaParseException>()));
    });

    test('wrong argument count', () {
      expect(
        () => FormulaExpression.parse('IF(1, 2)'),
        throwsA(isA<FormulaParseException>().having((e) => e.message, 'message', contains('IF'))),
      );
      expect(() => FormulaExpression.parse('ROUND(1, 2, 3)'), throwsA(isA<FormulaParseException>()));
    });

    test('a trailing operator', () {
      expect(() => FormulaExpression.parse('1 +'), throwsA(isA<FormulaParseException>()));
    });

    test('trailing junk after a complete expression', () {
      expect(() => FormulaExpression.parse('1 + 2 3'), throwsA(isA<FormulaParseException>()));
    });

    test('an unexpected character', () {
      expect(() => FormulaExpression.parse('1 # 2'), throwsA(isA<FormulaParseException>()));
    });

    test('tryParse returns null instead of throwing', () {
      expect(FormulaExpression.tryParse('cost * 2'), isNull);
      expect(FormulaExpression.tryParse('{cost} * 2'), isNotNull);
    });
  });
}
