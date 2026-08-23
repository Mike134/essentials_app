/// A parsed `formula` field expression -- Essentials v2 Phase 2 build
/// order step 6 (see claude/essentials-v2-phase2-design.md's `formula`
/// entry). Deliberately a **small spreadsheet-style subset**, not full
/// JS: `flutter_js`/QuickJS stays reserved for Phase 5's scripting
/// engine, per the design doc's confirmed decision.
///
/// ## Why hand-rolled rather than a pub.dev package
///
/// The design doc left this open ("worth a 30-minute pub.dev check at
/// implementation time"). Check done, 2026-08-23 -- the real candidates
/// were `math_expressions` (v3.2.0, actively maintained) and
/// `expressions` (v0.2.5+3, pre-1.0, ~11 months stale). Hand-rolled
/// anyway, for reasons specific to this design rather than
/// package-quality doubts:
///
/// 1. **The `{field_name}` brace syntax is this design's own** (the
///    design doc specifies `{cost} * {quantity}`). No package tokenizes
///    `{...}` as a variable reference. The two workarounds are both bad:
///    string-substituting values into the source before parsing is
///    genuinely unsafe (a text field whose value contains `)`, `+`, or a
///    quote silently corrupts the expression, and null values have no
///    sane substitution), while pre-scanning to rewrite `{cost}` into a
///    legal identifier means writing a real tokenizer anyway -- a naive
///    regex would rewrite inside string literals too. Most of the
///    tokenizer work is therefore unavoidable either way.
/// 2. **`math_expressions` has no string type at all** (reals, vectors,
///    interval arithmetic), so `||` concatenation and `IF(c, 'a', 'b')`
///    are structurally out.
/// 3. **Null-tolerant semantics matter here and no package gives them.**
///    These expressions run over real rows with missing values; a
///    thrown exception or a `NaN` leaking into the grid is not
///    acceptable, so every operator needs deliberate null handling (see
///    "Null and type semantics" below).
/// 4. This project has real scar tissue about dependencies -- see
///    `pubspec.yaml`'s `file_picker` comment (forced onto a beta because
///    stable broke under AGP 9). Taking a pre-1.0 dependency for one
///    field format, when the subset is this small, is a bad trade.
///
/// ## Grammar
///
/// ```
/// expression     := comparison
/// comparison     := concat (('=' | '==' | '!=' | '<>' | '<' | '<=' | '>' | '>=') concat)?
/// concat         := additive ('||' additive)*
/// additive       := multiplicative (('+' | '-') multiplicative)*
/// multiplicative := unary (('*' | '/') unary)*
/// unary          := ('-' | '+')? primary
/// primary        := NUMBER | STRING | '{' FIELD '}' | FUNCTION '(' args? ')'
///                 | '(' expression ')' | 'true' | 'false' | 'null'
/// ```
///
/// **Deliberate divergence from SQLite's own precedence:** SQLite binds
/// `||` *tighter* than `*`/`/`, so `'Total: ' || {a} + {b}` would mean
/// `('Total: ' || {a}) + {b}` there. That reads wrong for a user-facing
/// formula language, so `||` binds looser than arithmetic here (but
/// tighter than comparison, so `{a} || {b} = 'xy'` still compares the
/// concatenated result). Noted because anyone coming from the old
/// `subscription_computed` SQL view might reasonably assume otherwise.
///
/// ## Null and type semantics
///
/// - Arithmetic (`+ - * /`) with any null operand yields null (SQL-like).
///   Division by zero also yields null rather than `Infinity`/`NaN` --
///   those would otherwise render as literal garbage in a grid cell.
/// - Comparison with any null operand yields null, which [IF] then
///   treats as falsy.
/// - **`||` treats null as an empty string** -- deliberately *not*
///   SQL-like (`'a' || NULL` is `NULL` in SQL). Concatenation here exists
///   to build a display string, and one missing field blanking the whole
///   result is never what's wanted.
/// - `IF`'s condition truthiness: `bool` as-is, `null` false, `num`
///   non-zero, `String` non-empty.
/// - Function arguments are evaluated **eagerly**, including both `IF`
///   branches. Safe because the failure modes that would normally demand
///   lazy evaluation (division by zero) yield null here rather than
///   throwing -- so `IF({q} = 0, 0, {t} / {q})` behaves correctly.
library;

/// Resolves a `{field_name}` reference to its already-typed value. The
/// *caller* owns type resolution (a `currency` field's raw TEXT becoming
/// a real `num`, say) -- this file stays a pure expression evaluator with
/// no knowledge of `FieldConfig`. See `FormulaService`, which supplies
/// this using the table's own field metadata.
typedef FormulaFieldResolver = Object? Function(String fieldName);

/// Thrown by [FormulaExpression.parse] for a malformed expression. Always
/// carries a human-readable [message] -- surfaced live in the Add Field/
/// Manage Fields UI as the user types, so a bad formula is caught at
/// authoring time rather than silently yielding blank cells later.
class FormulaParseException implements Exception {
  FormulaParseException(this.message);

  final String message;

  @override
  String toString() => message;
}

class FormulaExpression {
  FormulaExpression._(this._root, this.source, this.fieldNames);

  /// Parses [source], throwing [FormulaParseException] if it's malformed.
  factory FormulaExpression.parse(String source) {
    final tokens = _Scanner(source).scan();
    final parser = _Parser(tokens, source);
    final root = parser.parseExpression();
    parser.expectEnd();
    final fields = <String>{};
    root.collectFields(fields);
    return FormulaExpression._(root, source, Set.unmodifiable(fields));
  }

  /// [parse], but returns `null` instead of throwing -- for the read path,
  /// where a bad expression should yield a blank value rather than take
  /// down a grid full of otherwise-fine rows.
  static FormulaExpression? tryParse(String source) {
    try {
      return FormulaExpression.parse(source);
    } on FormulaParseException {
      return null;
    }
  }

  final String source;

  /// Every `{field_name}` this expression references, in no particular
  /// order -- used by `FormulaService` for cycle detection across
  /// formula fields that reference other formula fields.
  final Set<String> fieldNames;

  final _Node _root;

  Object? evaluate(FormulaFieldResolver resolve) => _root.eval(resolve);

  /// Every supported function name, sorted -- surfaced as helper text in
  /// the formula editor so the available vocabulary is discoverable
  /// without documentation.
  static List<String> get functionNames => _functions.keys.toList()..sort();
}

// ---------------------------------------------------------------------------
// Scanner
// ---------------------------------------------------------------------------

enum _T { number, string, field, identifier, op, lparen, rparen, comma, eof }

class _Token {
  _Token(this.type, this.text, this.start, [this.value]);

  final _T type;
  final String text;
  final int start;
  final Object? value;
}

class _Scanner {
  _Scanner(this.source);

  final String source;
  int _pos = 0;

  static const _twoCharOps = ['||', '!=', '<>', '<=', '>=', '=='];
  static const _oneCharOps = ['=', '<', '>', '+', '-', '*', '/'];

  List<_Token> scan() {
    final tokens = <_Token>[];
    while (true) {
      _skipWhitespace();
      if (_pos >= source.length) break;
      tokens.add(_next());
    }
    tokens.add(_Token(_T.eof, '', source.length));
    return tokens;
  }

  void _skipWhitespace() {
    while (_pos < source.length && source[_pos].trim().isEmpty) {
      _pos++;
    }
  }

  _Token _next() {
    final start = _pos;
    final c = source[_pos];

    if (_isDigit(c) || (c == '.' && _pos + 1 < source.length && _isDigit(source[_pos + 1]))) {
      return _number(start);
    }
    if (c == "'" || c == '"') return _string(start, c);
    if (c == '{') return _field(start);
    if (_isIdentStart(c)) return _identifier(start);
    if (c == '(') {
      _pos++;
      return _Token(_T.lparen, '(', start);
    }
    if (c == ')') {
      _pos++;
      return _Token(_T.rparen, ')', start);
    }
    if (c == ',') {
      _pos++;
      return _Token(_T.comma, ',', start);
    }

    for (final op in _twoCharOps) {
      if (source.startsWith(op, _pos)) {
        _pos += op.length;
        return _Token(_T.op, op, start);
      }
    }
    if (_oneCharOps.contains(c)) {
      _pos++;
      return _Token(_T.op, c, start);
    }

    throw FormulaParseException('Unexpected character "$c" at position $start.');
  }

  _Token _number(int start) {
    var seenDot = false;
    while (_pos < source.length) {
      final c = source[_pos];
      if (_isDigit(c)) {
        _pos++;
      } else if (c == '.' && !seenDot) {
        seenDot = true;
        _pos++;
      } else {
        break;
      }
    }
    final text = source.substring(start, _pos);
    final value = num.tryParse(text);
    if (value == null) {
      throw FormulaParseException('"$text" is not a valid number (position $start).');
    }
    return _Token(_T.number, text, start, value);
  }

  /// SQL-style doubled-quote escaping (`'it''s'`), for either quote
  /// character -- no backslash escapes, deliberately: these expressions
  /// are typed into a small text box, not written in a source file.
  _Token _string(int start, String quote) {
    _pos++; // opening quote
    final buffer = StringBuffer();
    while (true) {
      if (_pos >= source.length) {
        throw FormulaParseException('Unterminated text value starting at position $start.');
      }
      final c = source[_pos];
      if (c == quote) {
        if (_pos + 1 < source.length && source[_pos + 1] == quote) {
          buffer.write(quote);
          _pos += 2;
          continue;
        }
        _pos++;
        break;
      }
      buffer.write(c);
      _pos++;
    }
    return _Token(_T.string, source.substring(start, _pos), start, buffer.toString());
  }

  _Token _field(int start) {
    _pos++; // opening brace
    final nameStart = _pos;
    while (_pos < source.length && source[_pos] != '}') {
      _pos++;
    }
    if (_pos >= source.length) {
      throw FormulaParseException('Missing closing "}" for the field starting at position $start.');
    }
    final name = source.substring(nameStart, _pos).trim();
    _pos++; // closing brace
    if (name.isEmpty) {
      throw FormulaParseException('Empty field reference "{}" at position $start.');
    }
    return _Token(_T.field, name, start, name);
  }

  _Token _identifier(int start) {
    while (_pos < source.length && _isIdentPart(source[_pos])) {
      _pos++;
    }
    return _Token(_T.identifier, source.substring(start, _pos), start);
  }

  static bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  static bool _isIdentStart(String c) {
    final u = c.codeUnitAt(0);
    return (u >= 0x41 && u <= 0x5A) || (u >= 0x61 && u <= 0x7A) || c == '_';
  }

  static bool _isIdentPart(String c) => _isIdentStart(c) || _isDigit(c);
}

// ---------------------------------------------------------------------------
// AST
// ---------------------------------------------------------------------------

abstract class _Node {
  Object? eval(FormulaFieldResolver resolve);
  void collectFields(Set<String> out);
}

class _Literal implements _Node {
  _Literal(this.value);

  final Object? value;

  @override
  Object? eval(FormulaFieldResolver resolve) => value;

  @override
  void collectFields(Set<String> out) {}
}

class _FieldRef implements _Node {
  _FieldRef(this.name);

  final String name;

  @override
  Object? eval(FormulaFieldResolver resolve) => resolve(name);

  @override
  void collectFields(Set<String> out) => out.add(name);
}

class _Unary implements _Node {
  _Unary(this.op, this.operand);

  final String op;
  final _Node operand;

  @override
  Object? eval(FormulaFieldResolver resolve) {
    final value = asFormulaNum(operand.eval(resolve));
    if (value == null) return null;
    return op == '-' ? -value : value;
  }

  @override
  void collectFields(Set<String> out) => operand.collectFields(out);
}

class _Binary implements _Node {
  _Binary(this.op, this.left, this.right);

  final String op;
  final _Node left;
  final _Node right;

  @override
  Object? eval(FormulaFieldResolver resolve) {
    final l = left.eval(resolve);
    final r = right.eval(resolve);
    switch (op) {
      case '||':
        return '${formulaToText(l)}${formulaToText(r)}';
      case '+':
      case '-':
      case '*':
      case '/':
        return _arithmetic(op, l, r);
      default:
        return _comparison(op, l, r);
    }
  }

  static Object? _arithmetic(String op, Object? l, Object? r) {
    final a = asFormulaNum(l);
    final b = asFormulaNum(r);
    if (a == null || b == null) return null;
    switch (op) {
      case '+':
        return a + b;
      case '-':
        return a - b;
      case '*':
        return a * b;
      default:
        // Division by zero yields null, not Infinity/NaN -- either of
        // those would render as literal garbage in a grid cell.
        return b == 0 ? null : a / b;
    }
  }

  static Object? _comparison(String op, Object? l, Object? r) {
    if (l == null || r == null) return null;
    final a = asFormulaNum(l);
    final b = asFormulaNum(r);
    // Numeric comparison when both sides are numbers, lexical otherwise
    // -- so `{status} = 'open'` and `{cost} > 10` both behave sensibly.
    final c = (a != null && b != null)
        ? a.compareTo(b)
        : formulaToText(l).compareTo(formulaToText(r));
    switch (op) {
      case '=':
      case '==':
        return c == 0;
      case '!=':
      case '<>':
        return c != 0;
      case '<':
        return c < 0;
      case '<=':
        return c <= 0;
      case '>':
        return c > 0;
      default:
        return c >= 0;
    }
  }

  @override
  void collectFields(Set<String> out) {
    left.collectFields(out);
    right.collectFields(out);
  }
}

class _Call implements _Node {
  _Call(this.name, this.args);

  final String name;
  final List<_Node> args;

  @override
  Object? eval(FormulaFieldResolver resolve) {
    final values = [for (final arg in args) arg.eval(resolve)];
    return _functions[name]!.apply(values);
  }

  @override
  void collectFields(Set<String> out) {
    for (final arg in args) {
      arg.collectFields(out);
    }
  }
}

// ---------------------------------------------------------------------------
// Functions
// ---------------------------------------------------------------------------

class _FunctionDef {
  const _FunctionDef(this.minArgs, this.maxArgs, this.apply);

  final int minArgs;

  /// `-1` for unlimited.
  final int maxArgs;

  final Object? Function(List<Object?> args) apply;
}

/// Deliberately small -- the design doc's own scope is "arithmetic,
/// comparison, basic functions (`ROUND`, `IF`, string concatenation)".
/// `ABS`/`COALESCE`/`MIN`/`MAX` are added because each is a one-liner and
/// `COALESCE` in particular is close to necessary given null propagation
/// (see the library doc comment). Adding another is a single entry here
/// plus a test -- keyed uppercase, looked up case-insensitively.
final Map<String, _FunctionDef> _functions = {
  'ROUND': _FunctionDef(1, 2, (args) {
    final value = asFormulaNum(args[0]);
    if (value == null) return null;
    final places = args.length > 1 ? (asFormulaNum(args[1])?.toInt() ?? 0) : 0;
    return roundFormulaNum(value, places);
  }),
  'IF': _FunctionDef(3, 3, (args) => formulaTruthy(args[0]) ? args[1] : args[2]),
  'ABS': _FunctionDef(1, 1, (args) => asFormulaNum(args[0])?.abs()),
  'COALESCE': _FunctionDef(1, -1, (args) {
    for (final arg in args) {
      if (arg != null) return arg;
    }
    return null;
  }),
  // Numeric-only, and null if any argument isn't a number -- a lexical
  // MIN/MAX would be surprising more often than useful here.
  'MIN': _FunctionDef(1, -1, (args) => _extreme(args, takeSmaller: true)),
  'MAX': _FunctionDef(1, -1, (args) => _extreme(args, takeSmaller: false)),
};

Object? _extreme(List<Object?> args, {required bool takeSmaller}) {
  num? best;
  for (final arg in args) {
    final value = asFormulaNum(arg);
    if (value == null) return null;
    if (best == null || (takeSmaller ? value < best : value > best)) best = value;
  }
  return best;
}

// ---------------------------------------------------------------------------
// Shared value helpers (also used by FormulaService)
// ---------------------------------------------------------------------------

/// [value] as a number, or `null` if it isn't one. Strings are parsed
/// leniently so a numeric literal typed into a text field still works in
/// arithmetic; `bool` deliberately doesn't convert (use `IF` instead of
/// relying on an implicit 1/0).
num? asFormulaNum(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value.trim());
  return null;
}

bool formulaTruthy(Object? value) {
  if (value == null) return false;
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) return value.trim().isNotEmpty;
  return true;
}

/// Display text for [value] -- `null` becomes empty (see the library doc
/// comment's note on `||`), and a whole-valued `double` loses its `.0` so
/// `{count} || ' items'` reads "4 items", not "4.0 items".
String formulaToText(Object? value) {
  if (value == null) return '';
  if (value is double && value.isFinite && value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}

/// Rounds to [places] decimals, returning an `int` for `places <= 0` so
/// whole results don't display a spurious `.0`.
num roundFormulaNum(num value, int places) {
  if (!value.isFinite) return value;
  if (places <= 0) return value.round();
  final factor = _pow10(places);
  return (value * factor).round() / factor;
}

num _pow10(int places) {
  var result = 1;
  for (var i = 0; i < places; i++) {
    result *= 10;
  }
  return result;
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

class _Parser {
  _Parser(this._tokens, this._source);

  final List<_Token> _tokens;
  final String _source;
  int _index = 0;

  _Token get _current => _tokens[_index];

  _Node parseExpression() => _parseComparison();

  void expectEnd() {
    if (_current.type != _T.eof) {
      throw FormulaParseException(
        'Unexpected "${_current.text}" at position ${_current.start}.',
      );
    }
  }

  _Node _parseComparison() {
    final left = _parseConcat();
    if (_current.type == _T.op && const {'=', '==', '!=', '<>', '<', '<=', '>', '>='}.contains(_current.text)) {
      final op = _current.text;
      _index++;
      return _Binary(op, left, _parseConcat());
    }
    return left;
  }

  _Node _parseConcat() {
    var left = _parseAdditive();
    while (_current.type == _T.op && _current.text == '||') {
      _index++;
      left = _Binary('||', left, _parseAdditive());
    }
    return left;
  }

  _Node _parseAdditive() {
    var left = _parseMultiplicative();
    while (_current.type == _T.op && (_current.text == '+' || _current.text == '-')) {
      final op = _current.text;
      _index++;
      left = _Binary(op, left, _parseMultiplicative());
    }
    return left;
  }

  _Node _parseMultiplicative() {
    var left = _parseUnary();
    while (_current.type == _T.op && (_current.text == '*' || _current.text == '/')) {
      final op = _current.text;
      _index++;
      left = _Binary(op, left, _parseUnary());
    }
    return left;
  }

  _Node _parseUnary() {
    if (_current.type == _T.op && (_current.text == '-' || _current.text == '+')) {
      final op = _current.text;
      _index++;
      return _Unary(op, _parseUnary());
    }
    return _parsePrimary();
  }

  _Node _parsePrimary() {
    final token = _current;
    switch (token.type) {
      case _T.number:
      case _T.string:
        _index++;
        return _Literal(token.value);
      case _T.field:
        _index++;
        return _FieldRef(token.value as String);
      case _T.lparen:
        _index++;
        final inner = parseExpression();
        if (_current.type != _T.rparen) {
          throw FormulaParseException('Missing ")" at position ${_current.start}.');
        }
        _index++;
        return inner;
      case _T.identifier:
        return _parseIdentifier(token);
      default:
        if (token.type == _T.eof) {
          throw FormulaParseException(
            _source.trim().isEmpty ? 'The formula is empty.' : 'The formula ends unexpectedly.',
          );
        }
        throw FormulaParseException('Unexpected "${token.text}" at position ${token.start}.');
    }
  }

  _Node _parseIdentifier(_Token token) {
    final upper = token.text.toUpperCase();
    if (upper == 'TRUE' || upper == 'FALSE') {
      _index++;
      return _Literal(upper == 'TRUE');
    }
    if (upper == 'NULL') {
      _index++;
      return _Literal(null);
    }

    final definition = _functions[upper];
    if (definition == null) {
      // Overwhelmingly the likely mistake -- typing `cost * 2` instead of
      // `{cost} * 2`. Say so rather than a bare "unexpected token".
      throw FormulaParseException(
        'Unknown name "${token.text}" at position ${token.start}. '
        'Field references need braces, like {${token.text}}. '
        'Available functions: ${(_functions.keys.toList()..sort()).join(', ')}.',
      );
    }

    _index++;
    if (_current.type != _T.lparen) {
      throw FormulaParseException('"$upper" needs parentheses, like $upper(...).');
    }
    _index++;

    final args = <_Node>[];
    if (_current.type != _T.rparen) {
      args.add(parseExpression());
      while (_current.type == _T.comma) {
        _index++;
        args.add(parseExpression());
      }
    }
    if (_current.type != _T.rparen) {
      throw FormulaParseException('Missing ")" closing $upper at position ${_current.start}.');
    }
    _index++;

    if (args.length < definition.minArgs ||
        (definition.maxArgs >= 0 && args.length > definition.maxArgs)) {
      throw FormulaParseException(
        '$upper takes ${_arityText(definition)}, but got ${args.length}.',
      );
    }
    return _Call(upper, args);
  }

  static String _arityText(_FunctionDef definition) {
    if (definition.maxArgs < 0) return 'at least ${definition.minArgs} argument(s)';
    if (definition.minArgs == definition.maxArgs) {
      return 'exactly ${definition.minArgs} argument(s)';
    }
    return '${definition.minArgs} to ${definition.maxArgs} arguments';
  }
}
