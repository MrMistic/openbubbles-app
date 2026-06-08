import 'package:get/get.dart';

/// Tracks upload progress across multiple attachments in a multi-image send.
class MultiAttachmentProgress {
  final int totalAttachments;
  final RxInt completedAttachments = 0.obs;
  final RxDouble currentAttachmentProgress = 0.0.obs;

  MultiAttachmentProgress({required this.totalAttachments});

  /// Combined progress across all attachments, always in [0.0, 1.0].
  double get overallProgress =>
      (completedAttachments.value + currentAttachmentProgress.value) / totalAttachments;
}
