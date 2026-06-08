import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Standalone test app that exercises the HEIC sequence decode feature
/// without requiring auth or any backend services.
///
/// Run with: fvm flutter run -d emulator-5554 --flavor joel -t lib/heic_test_main.dart
///
/// Prerequisites: push test files to emulator first:
///   adb push .kiro/specs/moving-stickers/101FF4AD-D72F-49D0-8BBE-9B720A78490C.heics /data/local/tmp/test_101FF4AD.heics
///   adb push .kiro/specs/moving-stickers/C926EB22-FAFD-4A02-B720-D687AE3D7E5B.heics /data/local/tmp/test_C926EB22.heics
void main() {
  runApp(const HeicSequenceTestApp());
}

class HeicSequenceTestApp extends StatelessWidget {
  const HeicSequenceTestApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HEIC Sequence Test',
      theme: ThemeData.dark(useMaterial3: true),
      home: const HeicSequenceTestPage(),
    );
  }
}

class HeicSequenceTestPage extends StatefulWidget {
  const HeicSequenceTestPage({super.key});

  @override
  State<HeicSequenceTestPage> createState() => _HeicSequenceTestPageState();
}

class _HeicSequenceTestPageState extends State<HeicSequenceTestPage> {
  static const _channel = MethodChannel('com.bluebubbles.messaging');

  final _testFiles = [
    '/data/local/tmp/test_101FF4AD.heics',
    '/data/local/tmp/test_C926EB22.heics',
  ];

  final _results = <_DecodeResult>[];
  bool _loading = false;
  String? _error;

  Future<void> _decodeAll() async {
    setState(() {
      _loading = true;
      _results.clear();
      _error = null;
    });

    for (final path in _testFiles) {
      final fileName = path.split('/').last;
      final stopwatch = Stopwatch()..start();

      try {
        if (!await File(path).exists()) {
          _results.add(_DecodeResult(
            fileName: fileName,
            error: 'File not found. Push with adb first.',
          ));
          continue;
        }

        final Uint8List? bytes = await _channel.invokeMethod(
          'decode-heic-sequence',
          {'file': path},
        );
        stopwatch.stop();

        if (bytes != null) {
          _results.add(_DecodeResult(
            fileName: fileName,
            bytes: bytes,
            durationMs: stopwatch.elapsedMilliseconds,
          ));
        } else {
          _results.add(_DecodeResult(
            fileName: fileName,
            error: 'Returned null',
            durationMs: stopwatch.elapsedMilliseconds,
          ));
        }
      } catch (e) {
        stopwatch.stop();
        _results.add(_DecodeResult(
          fileName: fileName,
          error: e.toString(),
          durationMs: stopwatch.elapsedMilliseconds,
        ));
      }
    }

    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('HEIC Sequence Decode Test')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              onPressed: _loading ? null : _decodeAll,
              icon: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow),
              label: Text(_loading ? 'Decoding...' : 'Decode Test Files'),
            ),
            const SizedBox(height: 8),
            Text(
              'Files on emulator at /data/local/tmp/',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 24),
            ..._results.map((r) => _ResultCard(result: r)),
          ],
        ),
      ),
    );
  }
}

class _DecodeResult {
  final String fileName;
  final Uint8List? bytes;
  final String? error;
  final int? durationMs;

  _DecodeResult({
    required this.fileName,
    this.bytes,
    this.error,
    this.durationMs,
  });
}

class _ResultCard extends StatelessWidget {
  final _DecodeResult result;
  const _ResultCard({required this.result});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result.fileName,
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            if (result.durationMs != null)
              Text(
                '${result.durationMs}ms • ${result.bytes != null ? "${(result.bytes!.length / 1024).toStringAsFixed(0)} KB" : "failed"}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (result.error != null) ...[
              const SizedBox(height: 8),
              Text(
                result.error!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ],
            if (result.bytes != null) ...[
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  // Checkerboard pattern to show transparency
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade700),
                ),
                child: Image.memory(
                  result.bytes!,
                  gaplessPlayback: true,
                  errorBuilder: (_, e, __) => Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Render error: $e',
                        style: const TextStyle(color: Colors.red)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
