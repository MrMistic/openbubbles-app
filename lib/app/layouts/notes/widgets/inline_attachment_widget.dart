import 'dart:typed_data';

import 'package:bluebubbles/services/notes/notes_controller.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:shimmer/shimmer.dart';

/// Renders a single inline attachment (image or drawing).
/// Downloads image data lazily via NotesController.fetchAttachment()
/// and displays it with loading shimmer, error placeholder, and tap-to-fullscreen.
class InlineAttachmentWidget extends StatefulWidget {
  final String identifier;
  final String? typeUti;
  final Function()? onTap;

  const InlineAttachmentWidget({
    super.key,
    required this.identifier,
    this.typeUti,
    this.onTap,
  });

  @override
  State<InlineAttachmentWidget> createState() => _InlineAttachmentWidgetState();
}

class _InlineAttachmentWidgetState extends State<InlineAttachmentWidget> {
  Uint8List? _imageData;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadAttachment();
  }

  Future<void> _loadAttachment() async {
    try {
      final controller = Get.find<NotesController>();
      final data = await controller.fetchAttachment(widget.identifier);
      if (mounted) {
        setState(() {
          _imageData = data;
          _isLoading = false;
          _hasError = data == null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Shimmer.fromColors(
          baseColor: Colors.grey[300]!,
          highlightColor: Colors.grey[100]!,
          child: Container(
            width: double.infinity,
            height: 200,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      );
    }

    if (_hasError || _imageData == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Container(
          width: double.infinity,
          height: 100,
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(8),
          ),
          child: const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.broken_image_outlined, size: 32, color: Colors.grey),
                SizedBox(height: 4),
                Text(
                  'Image could not be loaded',
                  style: TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: GestureDetector(
        onTap: widget.onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            _imageData!,
            width: double.infinity,
            fit: BoxFit.fitWidth,
            errorBuilder: (context, error, stackTrace) {
              return Container(
                width: double.infinity,
                height: 100,
                color: Colors.grey[200],
                child: const Center(
                  child: Icon(Icons.broken_image_outlined, size: 32, color: Colors.grey),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
