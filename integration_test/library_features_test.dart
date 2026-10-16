import 'package:integration_test/integration_test.dart';

import '../test/library_features_ui_test.dart' as feature_tests;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  feature_tests.main();
}
