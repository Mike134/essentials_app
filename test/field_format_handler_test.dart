// Proves FieldFormatRegistry dispatch and the Phase 2 format handlers'
// value-parsing/serialization -- Essentials v2 Phase 2 build order steps
// 1 (link_file, the FieldFormatHandler/FieldFormatRegistry prerequisite),
// 2 (currency/percentage), 5 (rating), and 7 (barcode). Pure Dart/widget
// tests, no DatabaseHelper/SyncService involved -- run with
// `flutter test test/field_format_handler_test.dart`.
import 'package:essentials_app/models/table_config.dart';
import 'package:essentials_app/util/field_formats/barcode_format_handler.dart';
import 'package:essentials_app/util/field_formats/currency_format_handler.dart';
import 'package:essentials_app/util/field_formats/field_format_handler.dart';
import 'package:essentials_app/util/field_formats/link_file_format_handler.dart';
import 'package:essentials_app/util/field_formats/percentage_format_handler.dart';
import 'package:essentials_app/util/field_formats/rating_format_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trina_grid/trina_grid.dart';

void main() {
  group('FieldFormatRegistry', () {
    test('handlerFor returns the registered handler by format string', () {
      final registry = FieldFormatRegistry(const [LinkFileFormatHandler()]);
      final handler = registry.handlerFor('link_file');
      expect(handler, isNotNull);
      expect(handler!.format, 'link_file');
    });

    test('handlerFor returns null for every Phase 1 format -- no regression risk', () {
      final registry = FieldFormatRegistry(const [
        LinkFileFormatHandler(),
        CurrencyFormatHandler(),
        PercentageFormatHandler(),
        RatingFormatHandler(),
        BarcodeFormatHandler(),
      ]);
      for (final format in ['text', 'integer', 'real', 'boolean', 'date', 'dateTime', 'select']) {
        expect(registry.handlerFor(format), isNull, reason: '$format should have no handler');
      }
    });

    test('handlerFor returns null for a null format', () {
      final registry = FieldFormatRegistry(const [LinkFileFormatHandler()]);
      expect(registry.handlerFor(null), isNull);
    });

    test('handlerFor returns null for a format this registry has no handler for', () {
      final registry = FieldFormatRegistry(const [LinkFileFormatHandler()]);
      expect(registry.handlerFor('never_a_real_format'), isNull);
    });

    test('a fresh instance with no handlers resolves everything to null', () {
      final registry = FieldFormatRegistry(const []);
      expect(registry.handlerFor('link_file'), isNull);
    });
  });

  group('LinkFileFormatHandler', () {
    const handler = LinkFileFormatHandler();
    const field = FieldConfig(column: 'attachment_path', label: 'Attachment', format: 'link_file');

    test('buildGridColumn keys the column to field.column/label', () {
      final column = handler.buildGridColumn(field);
      expect(column.field, 'attachment_path');
      expect(column.title, 'Attachment');
    });

    test('cellValueFor stringifies a raw stored value', () {
      expect(handler.cellValueFor(field, 'C:\\Databases\\file.pdf'), 'C:\\Databases\\file.pdf');
    });

    test('cellValueFor returns empty string for a null stored value', () {
      expect(handler.cellValueFor(field, null), '');
    });

    test('valueForSave trims whitespace', () {
      expect(handler.valueForSave(field, '  C:\\Databases\\file.pdf  '), 'C:\\Databases\\file.pdf');
    });

    test('valueForSave collapses blank input to null (no path == no value)', () {
      expect(handler.valueForSave(field, '   '), isNull);
      expect(handler.valueForSave(field, null), isNull);
    });
  });

  group('CurrencyFormatHandler', () {
    const handler = CurrencyFormatHandler();
    const field = FieldConfig(column: 'cost', label: 'Cost', format: 'currency');
    const fieldWithOptions = FieldConfig(
      column: 'price',
      label: 'Price',
      format: 'currency',
      options: {'symbol': '£', 'decimals': 0},
    );

    test('buildGridColumn defaults to \$ and 2 decimals when options is empty', () {
      final column = handler.buildGridColumn(field);
      final type = column.type as TrinaColumnTypeCurrency;
      expect(column.field, 'cost');
      expect(type.symbol, r'$');
      expect(type.numberFormat.decimalDigits, 2);
    });

    test('buildGridColumn honors options.symbol/options.decimals', () {
      final column = handler.buildGridColumn(fieldWithOptions);
      final type = column.type as TrinaColumnTypeCurrency;
      expect(type.symbol, '£');
      expect(type.numberFormat.decimalDigits, 0);
    });

    test('cellValueFor passes the raw TEXT-column value through unchanged', () {
      expect(handler.cellValueFor(field, '19.99'), '19.99');
      expect(handler.cellValueFor(field, null), isNull);
    });

    test('valueForSave stringifies the num TrinaGrid hands back on edit', () {
      expect(handler.valueForSave(field, 19.99), '19.99');
      expect(handler.valueForSave(field, null), isNull);
    });

    testWidgets('buildFormField shows the symbol as a prefix and binds directly to the shared controller', (
      tester,
    ) async {
      final controller = TextEditingController(text: '19.99');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => handler.buildFormField(context, field, controller)),
          ),
        ),
      );

      expect(find.text('19.99'), findsOneWidget);
      expect(find.text(r'$'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), '25.50');
      // Currency's form field binds straight to the shared controller (no
      // wrapper widget, unlike percentage) -- typing directly changes what
      // GenericFormScreen._currentValues() will read.
      expect(controller.text, '25.50');
    });
  });

  group('PercentageFormatHandler', () {
    const handler = PercentageFormatHandler();
    const field = FieldConfig(column: 'rate', label: 'Rate', format: 'percentage');
    const fieldWithDecimals = FieldConfig(
      column: 'rate',
      label: 'Rate',
      format: 'percentage',
      options: {'decimals': 1},
    );

    test('decimalsFor defaults to 0, honors options.decimals', () {
      expect(handler.decimalsFor(field), 0);
      expect(handler.decimalsFor(fieldWithDecimals), 1);
    });

    test('buildGridColumn uses TrinaColumnType.percentage with decimalInput false', () {
      final column = handler.buildGridColumn(fieldWithDecimals);
      final type = column.type as TrinaColumnTypePercentage;
      expect(type.decimalDigits, 1);
      // decimalInput defaults to false in trina_grid -- confirms this
      // handler relies on that default (stores the decimal fraction, not
      // the displayed percentage) rather than overriding it.
      expect(type.decimalInput, isFalse);
    });

    test('cellValueFor/valueForSave pass values through unchanged, same as currency', () {
      expect(handler.cellValueFor(field, '0.15'), '0.15');
      expect(handler.valueForSave(field, 0.15), '0.15');
      expect(handler.valueForSave(field, null), isNull);
    });

    testWidgets('buildFormField displays the stored fraction ×100 and writes ÷100 back on edit', (
      tester,
    ) async {
      final storageController = TextEditingController(text: '0.15');
      addTearDown(storageController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => handler.buildFormField(context, field, storageController),
            ),
          ),
        ),
      );

      // Stored "0.15" displays as "15" (whole-number default, decimals: 0).
      expect(find.text('15'), findsOneWidget);
      expect(find.text('%'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), '42');
      await tester.pump();

      // The user typed a percentage; the shared storage controller --
      // what GenericFormScreen._currentValues() actually reads on save --
      // must hold the divided-by-100 fraction, not "42".
      expect(storageController.text, '0.42');
    });

    testWidgets('a blank stored value displays as blank, not "0" or "NaN"', (tester) async {
      final storageController = TextEditingController(text: '');
      addTearDown(storageController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => handler.buildFormField(context, field, storageController),
            ),
          ),
        ),
      );

      final textField = tester.widget<TextFormField>(find.byType(TextFormField));
      expect(textField.controller!.text, '');
    });
  });

  group('RatingFormatHandler', () {
    const handler = RatingFormatHandler();
    const field = FieldConfig(column: 'stars', label: 'Stars', format: 'rating');
    const fieldWithMax = FieldConfig(
      column: 'stars',
      label: 'Stars',
      format: 'rating',
      options: {'max': 3},
    );

    test('buildGridColumn is readOnly -- the star renderer is the editor, same as boolean/color', () {
      final column = handler.buildGridColumn(field);
      expect(column.field, 'stars');
      expect(column.readOnly, isTrue);
    });

    test('buildGridColumn scales width with options.max', () {
      final defaultColumn = handler.buildGridColumn(field);
      final threeStarColumn = handler.buildGridColumn(fieldWithMax);
      expect(threeStarColumn.width, lessThan(defaultColumn.width));
    });

    test('cellValueFor parses the raw TEXT value to an int', () {
      expect(handler.cellValueFor(field, '4'), 4);
      expect(handler.cellValueFor(field, null), isNull);
      expect(handler.cellValueFor(field, 'not a number'), isNull);
    });

    test('valueForSave stringifies the int the grid renderer passes directly', () {
      expect(handler.valueForSave(field, 4), '4');
      expect(handler.valueForSave(field, null), isNull);
    });

    testWidgets('buildFormField renders options.max stars, all empty for a blank controller', (
      tester,
    ) async {
      final controller = TextEditingController(text: '');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => handler.buildFormField(context, fieldWithMax, controller),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.star_border), findsNWidgets(3));
      expect(find.byIcon(Icons.star), findsNothing);
    });

    testWidgets('tapping a star fills every star up to it and writes the int to the controller', (
      tester,
    ) async {
      final controller = TextEditingController(text: '');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => handler.buildFormField(context, fieldWithMax, controller),
            ),
          ),
        ),
      );

      await tester.tap(find.byIcon(Icons.star_border).at(1)); // second star -> rating 2
      await tester.pump();

      expect(controller.text, '2');
      expect(find.byIcon(Icons.star), findsNWidgets(2));
      expect(find.byIcon(Icons.star_border), findsNWidgets(1));
    });

    testWidgets('tapping the currently-set star again clears the rating', (tester) async {
      final controller = TextEditingController(text: '2');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => handler.buildFormField(context, fieldWithMax, controller),
            ),
          ),
        ),
      );

      expect(find.byIcon(Icons.star), findsNWidgets(2));

      await tester.tap(find.byIcon(Icons.star).at(1)); // the currently-set second star
      await tester.pump();

      expect(controller.text, '');
      expect(find.byIcon(Icons.star), findsNothing);
    });

    testWidgets('required validation fires when no rating is set', (tester) async {
      final controller = TextEditingController(text: '');
      addTearDown(controller.dispose);
      const requiredField = FieldConfig(column: 'stars', label: 'Stars', format: 'rating', required: true);
      final formKey = GlobalKey<FormState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              key: formKey,
              child: Builder(
                builder: (context) => handler.buildFormField(context, requiredField, controller),
              ),
            ),
          ),
        ),
      );

      expect(formKey.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('Stars is required'), findsOneWidget);
    });
  });

  group('BarcodeFormatHandler', () {
    const handler = BarcodeFormatHandler();
    const field = FieldConfig(column: 'sku', label: 'SKU', format: 'barcode');

    test('buildGridColumn keys the column to field.column/label -- plain text, same as any text field', () {
      final column = handler.buildGridColumn(field);
      expect(column.field, 'sku');
      expect(column.title, 'SKU');
      expect(column.type, isA<TrinaColumnTypeText>());
    });

    test('cellValueFor stringifies a raw stored value', () {
      expect(handler.cellValueFor(field, '012345678905'), '012345678905');
      expect(handler.cellValueFor(field, null), '');
    });

    test('valueForSave trims whitespace and collapses blank input to null', () {
      expect(handler.valueForSave(field, '  012345678905  '), '012345678905');
      expect(handler.valueForSave(field, '   '), isNull);
      expect(handler.valueForSave(field, null), isNull);
    });

    testWidgets('buildFormField binds directly to the shared controller, same as a plain text field', (
      tester,
    ) async {
      final controller = TextEditingController(text: '012345678905');
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => handler.buildFormField(context, field, controller)),
          ),
        ),
      );

      expect(find.text('012345678905'), findsOneWidget);

      await tester.enterText(find.byType(TextFormField), '999');
      expect(controller.text, '999');
    });

    testWidgets(
      'shows no scan button on a non-Android platform -- the actual "degrades cleanly" behavior '
      'the design doc asked for, exercised for real: `flutter test` runs as a non-Android host, so '
      'this is Windows/desktop behavior, not a platform-check assumption',
      (tester) async {
        final controller = TextEditingController(text: '');
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(builder: (context) => handler.buildFormField(context, field, controller)),
            ),
          ),
        );

        expect(find.byIcon(Icons.qr_code_scanner), findsNothing);
        expect(find.byType(IconButton), findsNothing);
        // The field itself is still completely ordinary -- no visible
        // "this feature is unavailable" affordance either.
        expect(find.byType(TextFormField), findsOneWidget);
      },
    );

    testWidgets('required validation fires when blank', (tester) async {
      final controller = TextEditingController(text: '');
      addTearDown(controller.dispose);
      const requiredField = FieldConfig(column: 'sku', label: 'SKU', format: 'barcode', required: true);
      final formKey = GlobalKey<FormState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Form(
              key: formKey,
              child: Builder(
                builder: (context) => handler.buildFormField(context, requiredField, controller),
              ),
            ),
          ),
        ),
      );

      expect(formKey.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('SKU is required'), findsOneWidget);
    });
  });
}
