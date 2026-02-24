import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/post_model.dart';
import '../theme/app_theme.dart';

/// Spacing constants for card layout (8–12px system).
const double kCardPadding = 12;
const double kCardGap = 8;
const double kCardRadius = 12;

/// Circular avatar with optional image URL; uses placeholder if empty.
class MarketplaceAvatar extends StatelessWidget {
  final String? imageUrl;
  final String displayName;
  final double size;

  const MarketplaceAvatar({
    super.key,
    this.imageUrl,
    required this.displayName,
    this.size = 40,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final placeholderColor = isDark ? AppTheme.darkBorder : AppTheme.lightBorder;

    if (imageUrl != null && imageUrl!.isNotEmpty) {
      return ClipOval(
        child: SizedBox(
          width: size,
          height: size,
          child: CachedNetworkImage(
            imageUrl: imageUrl!,
            fit: BoxFit.cover,
            placeholder: (_, __) => _placeholder(placeholderColor),
            errorWidget: (_, __, ___) => _placeholder(placeholderColor),
          ),
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: placeholderColor,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          displayName.isNotEmpty ? displayName.substring(0, 1).toUpperCase() : '?',
          style: TextStyle(
            color: isDark ? AppTheme.darkTextTertiary : AppTheme.lightTextTertiary,
            fontSize: size * 0.4,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _placeholder(Color bg) {
    return Container(
      color: bg,
      child: Center(
        child: Text(
          displayName.isNotEmpty ? displayName.substring(0, 1).toUpperCase() : '?',
          style: TextStyle(
            color: AppTheme.darkTextTertiary,
            fontSize: size * 0.4,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Urgency indicator: dot + label. No glow, no blinking.
class UrgencyChip extends StatelessWidget {
  final Urgency urgency;

  const UrgencyChip({super.key, required this.urgency});

  @override
  Widget build(BuildContext context) {
    final (color, label) = _style;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  (Color, String) get _style {
    switch (urgency) {
      case Urgency.urgent:
        return (const Color(0xFFE53935), 'Urgent');
      case Urgency.soon:
        return (const Color(0xFFFF9800), 'Soon');
      case Urgency.flexible:
        return (const Color(0xFF4CAF50), 'Flexible');
    }
  }
}

/// Difficulty chip: Easy (green), Medium (orange), Hard (red), Any (grey).
class DifficultyChip extends StatelessWidget {
  final Difficulty difficulty;

  const DifficultyChip({super.key, required this.difficulty});

  @override
  Widget build(BuildContext context) {
    final color = _color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String get _label {
    switch (difficulty) {
      case Difficulty.easy:
        return 'Easy';
      case Difficulty.medium:
        return 'Medium';
      case Difficulty.hard:
        return 'Hard';
      case Difficulty.any:
        return 'Any';
    }
  }

  Color get _color {
    switch (difficulty) {
      case Difficulty.easy:
        return const Color(0xFF4CAF50);
      case Difficulty.medium:
        return const Color(0xFFFF9800);
      case Difficulty.hard:
        return const Color(0xFFE53935);
      case Difficulty.any:
        return const Color(0xFF6B7280);
    }
  }
}

/// Location chip: "📍 City" (Kenyan cities).
class LocationChip extends StatelessWidget {
  final String location;

  const LocationChip({super.key, required this.location});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final bg = isDark
        ? AppTheme.darkTextTertiary.withValues(alpha: 0.15)
        : AppTheme.lightTextTertiary.withValues(alpha: 0.15);

    // Normalize: use first part if "Area, City", else use as-is for city name
    final display = location.contains(',')
        ? location.split(',').last.trim()
        : location.trim();
    final text = display.isEmpty ? 'Kenya' : display;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.location_on_outlined, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: fg,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
