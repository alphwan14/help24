import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/chat_person.dart';
import '../../theme/app_icons.dart';
import '../../theme/tokens.dart';

/// A chat partner's face, from the best source this phone has:
///
///   1. their photo as a FILE on this phone (ChatMediaStore) — no network,
///      so a cold start on a plane draws it;
///   2. their photo from the network, while it has not been downloaded yet;
///   3. their initials on their own tint (`PersonTint`, chosen from their id);
///   4. a person glyph on that tint, when not even the name is known.
///
/// Never "?". Every step falls through to the next on failure, so a missing
/// or corrupt file costs a photo, never the circle.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.userId,
    required this.name,
    required this.size,
    this.avatarPath,
    this.avatarUrl,
  });

  final String userId;
  final String name;
  final double size;
  final String? avatarPath;
  final String? avatarUrl;

  @override
  Widget build(BuildContext context) {
    final fallback = _initials(context);
    final path = avatarPath;
    final url = avatarUrl?.trim() ?? '';
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
    final cacheSize = (size * dpr).round();

    Widget network() => url.isEmpty
        ? fallback
        : CachedNetworkImage(
            imageUrl: url,
            width: size,
            height: size,
            fit: BoxFit.cover,
            memCacheWidth: cacheSize,
            fadeInDuration: Duration.zero,
            fadeOutDuration: Duration.zero,
            placeholderFadeInDuration: Duration.zero,
            placeholder: (_, __) => fallback,
            errorWidget: (_, __, ___) => fallback,
          );

    final Widget image = (path != null && path.isNotEmpty)
        ? Image.file(
            File(path),
            width: size,
            height: size,
            fit: BoxFit.cover,
            cacheWidth: cacheSize,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) => network(),
          )
        : network();

    return ExcludeSemantics(
      child: ClipOval(child: SizedBox.square(dimension: size, child: image)),
    );
  }

  Widget _initials(BuildContext context) {
    final tint = PersonTint.of(context, ChatPeople.tintIndex(userId.isEmpty ? name : userId));
    final initials = ChatPeople.initials(name);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: tint.fill, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: initials.isEmpty
          ? Icon(AppIcons.person, size: size * 0.46, color: tint.text)
          : Text(
              initials,
              textScaler: TextScaler.noScaling, // a fixed-size glyph, not text
              style: TextStyle(
                fontSize: size * (initials.length > 1 ? 0.34 : 0.4),
                fontWeight: FontWeight.w600,
                color: tint.text,
              ),
            ),
    );
  }
}
