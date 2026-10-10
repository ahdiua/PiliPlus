import 'package:PiliPlus/models/video/play/url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('episode DRM and preview flags exclude acceleration', () {
    final plain = PlayUrlModel.fromJson({});
    expect((plain.isDrm, plain.isPreview), (false, false));
    for (final value in [true, 1, '1']) {
      final marked = PlayUrlModel.fromJson({
        'is_drm': value,
        'is_preview': value,
      });
      expect((marked.isDrm, marked.isPreview), (true, true));
    }
  });
}
