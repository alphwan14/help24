import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:help24/models/post_model.dart';

/// Custom service categories: a provider's own profession (e.g. "TV Repair
/// Technician") is stored directly in posts.category and must round-trip
/// through model parsing, serialization, and the offline cache WITHOUT being
/// collapsed to 'Other'.
void main() {
  group('Category.fromName resolution', () {
    test('known registry names keep their identity and icon (case-insensitive)', () {
      final plumbing = Category.fromName('plumbing');
      expect(plumbing.name, 'Plumbing');
      expect(plumbing.icon, isNot(Icons.work_outline));
    });

    test('unknown names are PRESERVED as custom categories, not collapsed to Other', () {
      final custom = Category.fromName('TV Repair Technician');
      expect(custom.name, 'TV Repair Technician');
      expect(custom.icon, Icons.work_outline);
    });

    test('blank values fall back to Other', () {
      expect(Category.fromName('').name, 'Other');
      expect(Category.fromName('   ').name, 'Other');
    });

    test('surrounding whitespace is trimmed before matching', () {
      expect(Category.fromName('  Plumbing  ').name, 'Plumbing');
    });
  });

  group('Category.normalizeCustomName', () {
    test('trims and collapses repeated whitespace', () {
      expect(Category.normalizeCustomName('  CCTV   Installer  '), 'CCTV Installer');
    });

    test('rejects names shorter than 3 or longer than 40 chars', () {
      expect(Category.normalizeCustomName('ab'), isNull);
      expect(Category.normalizeCustomName('a' * 41), isNull);
      expect(Category.normalizeCustomName('a' * 40), isNotNull);
    });

    test('rejects names without any letter', () {
      expect(Category.normalizeCustomName('123 456'), isNull);
      expect(Category.normalizeCustomName('!!!'), isNull);
    });

    test('accepts realistic professions', () {
      for (final name in [
        'TV Repair Technician',
        'Carpenter',
        'Furniture Assembler',
        'CCTV Installer',
        'Solar Technician',
        'Welder',
        'Locksmith',
      ]) {
        expect(Category.normalizeCustomName(name), name);
      }
    });
  });

  group('PostModel custom-category round-trip', () {
    test('fromJson preserves a custom category and toJson writes it back', () {
      final post = PostModel.fromJson({
        'id': 'p1',
        'title': 'Fix your TV today',
        'description': 'Fast screen repair',
        'category': 'TV Repair Technician',
        'location': 'Nairobi',
        'price': 500,
        'urgency': 'flexible',
        'type': 'offer',
      });
      expect(post.category.name, 'TV Repair Technician');
      expect(post.toJson()['category'], 'TV Repair Technician');
    });

    test('offline cache round-trip keeps the custom label', () {
      final post = PostModel.fromJson({
        'id': 'p2',
        'title': 'Solar installs',
        'description': '',
        'category': 'Solar Technician',
        'location': 'Mombasa',
        'price': 0,
        'urgency': 'flexible',
        'type': 'offer',
      });
      final revived = PostModel.fromJson(post.toCacheMap());
      expect(revived.category.name, 'Solar Technician');
    });

    test('missing category still falls back to Other', () {
      final post = PostModel.fromJson({
        'id': 'p3',
        'title': 't',
        'description': '',
        'location': '',
        'price': 0,
        'urgency': 'flexible',
        'type': 'request',
      });
      expect(post.category.name, 'Other');
    });
  });
}
