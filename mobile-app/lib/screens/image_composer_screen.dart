// ─────────────────────────────────────────────────────────────────────────────
// Image composer — review before sending.
//
// Sending previously began the moment a photo was picked. That takes the
// decision away from the user: no chance to check they grabbed the right shot,
// no caption, no way to back out, and on a slow connection the upload is
// already running before they realise. Every modern messenger reviews first,
// and for a marketplace where photos are evidence — damage, receipts, meter
// readings — reviewing matters more, not less.
//
// The upload starts only when Send is pressed. Until then nothing has left the
// device and nothing is written to the thread.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:iconsax/iconsax.dart';
import 'package:image_picker/image_picker.dart';

import '../theme/app_theme.dart';

/// What the composer hands back: the images to send, in order, plus one
/// caption. Empty list (or null result) means the user backed out.
class ComposedImages {
  final List<XFile> files;
  final String caption;

  const ComposedImages({required this.files, required this.caption});
}

class ImageComposerScreen extends StatefulWidget {
  final List<XFile> initialFiles;
  final String partnerName;

  const ImageComposerScreen({
    super.key,
    required this.initialFiles,
    this.partnerName = '',
  });

  @override
  State<ImageComposerScreen> createState() => _ImageComposerScreenState();
}

class _ImageComposerScreenState extends State<ImageComposerScreen> {
  late final List<XFile> _files = List.of(widget.initialFiles);
  final TextEditingController _caption = TextEditingController();
  final PageController _pager = PageController();
  int _index = 0;

  @override
  void dispose() {
    _caption.dispose();
    _pager.dispose();
    super.dispose();
  }

  Future<void> _addMore() async {
    HapticFeedback.selectionClick();
    try {
      final picked = await ImagePicker().pickMultiImage(
        maxWidth: 1024,
        imageQuality: 85,
      );
      if (picked.isEmpty || !mounted) return;
      setState(() => _files.addAll(picked));
    } catch (_) {
      if (mounted) _snack('Could not open your gallery.');
    }
  }

  void _removeCurrent() {
    HapticFeedback.selectionClick();
    if (_files.length == 1) {
      // Removing the last image means "never mind" — leaving an empty composer
      // on screen would be a dead end.
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _files.removeAt(_index);
      if (_index >= _files.length) _index = _files.length - 1;
    });
    // Keep the pager in step with the list we just mutated.
    if (_pager.hasClients) _pager.jumpToPage(_index);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  void _send() {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pop(
      ComposedImages(files: List.of(_files), caption: _caption.text.trim()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final multiple = _files.length > 1;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          multiple ? '${_index + 1} of ${_files.length}' : 'Send photo',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          IconButton(
            tooltip: 'Remove this photo',
            onPressed: _removeCurrent,
            icon: const Icon(Iconsax.trash),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pager,
              itemCount: _files.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) => InteractiveViewer(
                // Zoom in review too: checking a photo is legible before
                // sending it is the entire point of this screen.
                minScale: 1,
                maxScale: 4,
                child: Center(
                  child: Image.file(File(_files[i].path), fit: BoxFit.contain),
                ),
              ),
            ),
          ),
          if (multiple)
            SizedBox(
              height: 74,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                itemCount: _files.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final selected = i == _index;
                  return GestureDetector(
                    onTap: () {
                      setState(() => _index = i);
                      _pager.animateToPage(
                        i,
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOut,
                      );
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: selected ? AppTheme.primaryAccent : Colors.white24,
                            width: selected ? 2.5 : 1,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Image.file(File(_files[i].path), fit: BoxFit.cover),
                      ),
                    ),
                  );
                },
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: 'Add another photo',
                    onPressed: _addMore,
                    icon: const Icon(Iconsax.add_circle, color: Colors.white, size: 28),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _caption,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      textCapitalization: TextCapitalization.sentences,
                      minLines: 1,
                      maxLines: 4,
                      decoration: InputDecoration(
                        hintText: widget.partnerName.isEmpty
                            ? 'Add a caption…'
                            : 'Add a caption for ${widget.partnerName}…',
                        hintStyle: const TextStyle(color: Colors.white54, fontSize: 14.5),
                        filled: true,
                        fillColor: Colors.white10,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 52 dp, and the only filled control on screen — sending is
                  // the decision this screen exists to confirm.
                  SizedBox(
                    width: 52,
                    height: 52,
                    child: FilledButton(
                      onPressed: _send,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primaryAccent,
                        padding: EdgeInsets.zero,
                        shape: const CircleBorder(),
                      ),
                      child: const Icon(Icons.arrow_upward_rounded,
                          color: Colors.white, size: 24),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
